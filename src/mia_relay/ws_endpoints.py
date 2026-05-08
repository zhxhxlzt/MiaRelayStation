"""WebSocket 端点与转发循环。

端点：
- ``GET /ws/phone`` —— 手机连入
- ``GET /ws/agent`` —— PC Agent 连入

职责：
1. ``Authorization: Bearer <token>`` 鉴权；未知/缺失 → HTTP 401（不握手）。
2. 连接登记到 ``ConnectionRegistry``；若同账号同角色已在线，旧连接以
   1008/"superseded" 关闭（见 registry）。
3. 新连接登记后，按序冲刷该角色的离线缓冲。
4. 读循环：解析 JSON → 做信封级基本校验（``from``/``to`` 与角色匹配）→
   按 ``to`` 路由。对端在线直发；对端离线按账号入队（容量 200/TTL 5m）。
5. 任意异常下以 finally 解除登记。

本文件不关心 ``payload`` 的业务语义——那是 wire-protocol 与 Agent 的事。
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, status
from starlette.websockets import WebSocketState

from .auth import load_tokens_from_env, validate_token
from .registry import (
    BUFFER_MAX_LEN,
    BUFFER_TTL_SECONDS,
    ConnectionRegistry,
    Role,
)


log = logging.getLogger("mia_relay.ws")


# ---- 内部工具 -----------------------------------------------------------


def _now_ms() -> int:
    return int(time.time() * 1000)


def _peer_role(role: Role) -> Role:
    return "agent" if role == "phone" else "phone"


def _build_error_envelope(
    *,
    from_role: Role,  # 错误信封 "伪装" 成中继代表对端发出，这里写发送方的对端
    to_role: Role,
    corr_id: str | None,
    code: str,
    message: str,
) -> str:
    """构造一条中继侧 ``error`` 信封。

    中继不是协议端，但规范要求对 malformed / 未知 type / bad_from / bad_to /
    buffer_overflow 回错误信封。我们以 ``from = 接收方的对端角色`` 发出——
    保持信封字段合法，便于客户端按统一通道消费。
    """
    env = {
        "v": 1,
        "msg_id": str(uuid.uuid4()),
        "corr_id": corr_id,
        "ts": _now_ms(),
        "from": from_role,
        "to": to_role,
        "type": "error",
        "payload": {"code": code, "message": message},
    }
    return json.dumps(env, ensure_ascii=False, separators=(",", ":"))


async def _safe_send_text(ws: WebSocket, text: str) -> bool:
    """容忍连接已关闭时的异常发送。"""
    if ws.application_state == WebSocketState.DISCONNECTED:
        return False
    try:
        await ws.send_text(text)
        return True
    except Exception as exc:  # pragma: no cover —— 网络异常分支
        log.warning("send_text failed: %s", exc)
        return False


# ---- 信封校验 -----------------------------------------------------------


_ALLOWED_TYPES = frozenset(
    {
        "user_msg",
        "assistant_delta",
        "assistant_end",
        "tool_call",
        "tool_result",
        "tool_confirm_request",
        "tool_confirm_response",
        "error",
        "ping",
        "pong",
    }
)
_REQUIRED_FIELDS = ("v", "msg_id", "ts", "from", "to", "type", "payload")


def _validate_envelope(
    obj: Any,
    sender_role: Role,
) -> tuple[str | None, str | None, str | None]:
    """对一条入站信封做中继级校验。

    返回 ``(error_code, error_message, corr_id)``：
    - 若 ``error_code`` 为 None 则信封合法，可路由；
    - 否则调用方应投递相应 ``error`` 回执。
    ``corr_id`` 用于把错误信封挂回出错信封的 ``msg_id``（尽力而为）。
    """
    if not isinstance(obj, dict):
        return "malformed_envelope", "envelope must be a JSON object", None

    corr_id = obj.get("msg_id") if isinstance(obj.get("msg_id"), str) else None

    for f in _REQUIRED_FIELDS:
        if f not in obj:
            return "malformed_envelope", f"missing field: {f}", corr_id

    if obj.get("v") != 1:
        return "version_mismatch", f"unsupported protocol version: {obj.get('v')!r}", corr_id

    if obj.get("type") not in _ALLOWED_TYPES:
        return "unknown_type", f"unknown envelope type: {obj.get('type')!r}", corr_id

    if obj.get("from") != sender_role:
        return "bad_from", f"from={obj.get('from')!r} does not match sender role {sender_role!r}", corr_id

    peer = _peer_role(sender_role)
    if obj.get("to") != peer:
        return "bad_to", f"to={obj.get('to')!r} is not the peer role {peer!r}", corr_id

    return None, None, corr_id


# ---- 主路由构造 ---------------------------------------------------------


def build_ws_router(registry: ConnectionRegistry) -> APIRouter:
    """构造包含 ``/ws/phone`` 与 ``/ws/agent`` 的路由。"""

    router = APIRouter()

    async def _handle(ws: WebSocket, role: Role) -> None:
        # 1) 鉴权：只认 Authorization: Bearer <token>
        allowed = load_tokens_from_env()
        token = validate_token(ws.headers.get("authorization"), allowed)
        if token is None:
            # 规范要求：在 upgrade 阶段即拒绝 —— 不接受握手
            await ws.close(code=status.WS_1008_POLICY_VIOLATION)
            return

        await ws.accept()

        # 2) 登记 + 挤掉旧连接 + 捞取离线缓冲
        evicted, pending = await registry.register(token, role, ws)
        if evicted is not None:
            try:
                await evicted.close(
                    code=status.WS_1008_POLICY_VIOLATION, reason="superseded"
                )
            except Exception:  # pragma: no cover
                pass
            log.info(
                "connection superseded token=%s role=%s", _mask(token), role
            )

        log.info("connected token=%s role=%s", _mask(token), role)

        # 3) 冲刷该角色的离线缓冲（过滤过期由 registry 内部完成；再兜一层 TTL）
        now = time.time()
        for item in pending:
            if now - item.enqueued_at > BUFFER_TTL_SECONDS:
                continue
            await _safe_send_text(ws, item.raw)

        # 4) 进入读-转发循环
        try:
            while True:
                raw = await ws.receive_text()
                await _route_envelope(ws, registry, token, role, raw)
        except WebSocketDisconnect:
            log.info("disconnected token=%s role=%s", _mask(token), role)
        except Exception as exc:
            log.warning(
                "ws loop error token=%s role=%s err=%r",
                _mask(token),
                role,
                exc,
            )
        finally:
            await registry.unregister(token, role, ws)

    @router.websocket("/ws/phone")
    async def ws_phone(ws: WebSocket) -> None:  # noqa: D401 —— FastAPI 端点
        await _handle(ws, "phone")

    @router.websocket("/ws/agent")
    async def ws_agent(ws: WebSocket) -> None:
        await _handle(ws, "agent")

    return router


# ---- 路由一条入站信封 ---------------------------------------------------


async def _route_envelope(
    ws: WebSocket,
    registry: ConnectionRegistry,
    token: str,
    sender_role: Role,
    raw: str,
) -> None:
    """解析并按 ``to`` 路由；必要时回 error 或入队缓冲。"""
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError as exc:
        err = _build_error_envelope(
            from_role=_peer_role(sender_role),
            to_role=sender_role,
            corr_id=None,
            code="malformed_envelope",
            message=f"invalid JSON: {exc.msg}",
        )
        await _safe_send_text(ws, err)
        return

    code, message, corr_id = _validate_envelope(obj, sender_role)
    if code is not None:
        err = _build_error_envelope(
            from_role=_peer_role(sender_role),
            to_role=sender_role,
            corr_id=corr_id,
            code=code,
            message=message or code,
        )
        await _safe_send_text(ws, err)
        return

    target: Role = obj["to"]
    peer = await registry.get_peer(token, target)

    # 运维日志只记头字段，payload 不进日志
    log.info(
        "route msg_id=%s type=%s from=%s to=%s ts=%s token=%s peer_online=%s",
        obj.get("msg_id"),
        obj.get("type"),
        obj.get("from"),
        obj.get("to"),
        obj.get("ts"),
        _mask(token),
        peer is not None,
    )

    if peer is not None:
        # 原样（raw）转发，避免重序列化带来的字节差异
        await _safe_send_text(peer, raw)
        return

    # 对端离线 → 入队（满时 deque 自动丢最旧，并回 buffer_overflow）
    overflowed = await registry.enqueue_for_offline(token, target, raw)
    if overflowed:
        err = _build_error_envelope(
            from_role=_peer_role(sender_role),
            to_role=sender_role,
            corr_id=obj.get("msg_id"),
            code="buffer_overflow",
            message=(
                f"offline buffer for role={target!r} overflowed; "
                f"oldest dropped (cap={BUFFER_MAX_LEN})"
            ),
        )
        await _safe_send_text(ws, err)


def _mask(token: str) -> str:
    """日志里不泄漏完整 token。"""
    if len(token) <= 6:
        return "***"
    return f"{token[:3]}…{token[-3:]}"
