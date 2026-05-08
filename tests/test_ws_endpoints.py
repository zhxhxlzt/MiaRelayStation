"""``mia_relay.ws_endpoints`` 的路由/校验单元测试。

用假 WS（支持 ``send_text``）直接驱动 ``_route_envelope``，覆盖：
- 正常：手机 → Agent / Agent → 手机 原样转发
- 伪造 from：拒绝并回 bad_from
- 自发自收（to == sender_role）：拒绝并回 bad_to
- 未知 type：拒绝并回 unknown_type
- 缺字段：拒绝并回 malformed_envelope
- 非法 JSON：回 malformed_envelope
- 对端离线 → 入队
- 对端离线且队列满 → 回 buffer_overflow
"""
from __future__ import annotations

import json
import time
import uuid
from typing import Any

import pytest
from starlette.websockets import WebSocketState

from mia_relay.registry import BUFFER_MAX_LEN, ConnectionRegistry
from mia_relay.ws_endpoints import _route_envelope, _validate_envelope


class FakeWS:
    """实现了 send_text 与 application_state 的最小假 WebSocket。

    ``_route_envelope`` 走的是 ``_safe_send_text``，它需要 application_state 与
    send_text；这里足够。
    """

    def __init__(self) -> None:
        self.sent: list[str] = []
        self.application_state = WebSocketState.CONNECTED

    async def send_text(self, text: str) -> None:
        self.sent.append(text)

    async def close(self, code: int = 1000, reason: str = "") -> None:
        self.application_state = WebSocketState.DISCONNECTED


def _envelope(
    *,
    sender: str,
    to: str,
    type_: str = "user_msg",
    payload: Any | None = None,
    v: int = 1,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    env = {
        "v": v,
        "msg_id": str(uuid.uuid4()),
        "corr_id": None,
        "ts": int(time.time() * 1000),
        "from": sender,
        "to": to,
        "type": type_,
        "payload": payload if payload is not None else {"text": "hi"},
    }
    if extra:
        env.update(extra)
    return env


# ---- _validate_envelope --------------------------------------------------


def test_validate_accepts_legal_envelope() -> None:
    env = _envelope(sender="phone", to="agent")
    code, msg, corr_id = _validate_envelope(env, "phone")
    assert code is None and msg is None
    assert corr_id == env["msg_id"]


def test_validate_rejects_non_dict() -> None:
    code, _, _ = _validate_envelope("not a dict", "phone")  # type: ignore[arg-type]
    assert code == "malformed_envelope"


def test_validate_rejects_missing_field() -> None:
    env = _envelope(sender="phone", to="agent")
    env.pop("ts")
    code, msg, _ = _validate_envelope(env, "phone")
    assert code == "malformed_envelope"
    assert "ts" in (msg or "")


def test_validate_rejects_wrong_version() -> None:
    env = _envelope(sender="phone", to="agent", v=2)
    code, _, _ = _validate_envelope(env, "phone")
    assert code == "version_mismatch"


def test_validate_rejects_unknown_type() -> None:
    env = _envelope(sender="phone", to="agent", type_="random_thing")
    code, _, _ = _validate_envelope(env, "phone")
    assert code == "unknown_type"


def test_validate_rejects_forged_from() -> None:
    # 手机连接却声称 from=agent
    env = _envelope(sender="agent", to="phone")
    code, _, _ = _validate_envelope(env, "phone")
    assert code == "bad_from"


def test_validate_rejects_self_loop_to() -> None:
    # 手机连接声称 to=phone
    env = _envelope(sender="phone", to="phone")
    code, _, _ = _validate_envelope(env, "phone")
    assert code == "bad_to"


# ---- _route_envelope -----------------------------------------------------


def _parse_sent(ws: FakeWS) -> list[dict[str, Any]]:
    return [json.loads(s) for s in ws.sent]


@pytest.mark.asyncio
async def test_route_phone_to_agent_forwards_verbatim() -> None:
    reg = ConnectionRegistry()
    phone_ws, agent_ws = FakeWS(), FakeWS()
    await reg.register("tok", "phone", phone_ws)
    await reg.register("tok", "agent", agent_ws)

    env = _envelope(sender="phone", to="agent")
    raw = json.dumps(env)
    await _route_envelope(phone_ws, reg, "tok", "phone", raw)

    # Agent 收到原始字节
    assert agent_ws.sent == [raw]
    # phone 不收到回执
    assert phone_ws.sent == []


@pytest.mark.asyncio
async def test_route_agent_to_phone_forwards_verbatim() -> None:
    reg = ConnectionRegistry()
    phone_ws, agent_ws = FakeWS(), FakeWS()
    await reg.register("tok", "phone", phone_ws)
    await reg.register("tok", "agent", agent_ws)

    env = _envelope(sender="agent", to="phone", type_="assistant_delta",
                    payload={"text": "hello"})
    raw = json.dumps(env)
    await _route_envelope(agent_ws, reg, "tok", "agent", raw)

    assert phone_ws.sent == [raw]


@pytest.mark.asyncio
async def test_route_forged_from_replies_bad_from() -> None:
    reg = ConnectionRegistry()
    phone_ws, agent_ws = FakeWS(), FakeWS()
    await reg.register("tok", "phone", phone_ws)
    await reg.register("tok", "agent", agent_ws)

    # sender_role = phone 但信封 from=agent
    env = _envelope(sender="agent", to="phone")
    raw = json.dumps(env)
    await _route_envelope(phone_ws, reg, "tok", "phone", raw)

    assert agent_ws.sent == []  # 不转发
    assert len(phone_ws.sent) == 1
    err = json.loads(phone_ws.sent[0])
    assert err["type"] == "error"
    assert err["payload"]["code"] == "bad_from"
    # 错误信封挂回出错信封的 msg_id
    assert err["corr_id"] == env["msg_id"]
    # 错误信封的 to 是发送方（回给它自己）
    assert err["to"] == "phone"


@pytest.mark.asyncio
async def test_route_self_loop_to_replies_bad_to() -> None:
    reg = ConnectionRegistry()
    phone_ws = FakeWS()
    await reg.register("tok", "phone", phone_ws)

    env = _envelope(sender="phone", to="phone")
    await _route_envelope(phone_ws, reg, "tok", "phone", json.dumps(env))

    assert len(phone_ws.sent) == 1
    err = json.loads(phone_ws.sent[0])
    assert err["type"] == "error"
    assert err["payload"]["code"] == "bad_to"


@pytest.mark.asyncio
async def test_route_invalid_json_replies_malformed() -> None:
    reg = ConnectionRegistry()
    phone_ws = FakeWS()
    await reg.register("tok", "phone", phone_ws)

    await _route_envelope(phone_ws, reg, "tok", "phone", "{not json")
    assert len(phone_ws.sent) == 1
    err = json.loads(phone_ws.sent[0])
    assert err["type"] == "error"
    assert err["payload"]["code"] == "malformed_envelope"


@pytest.mark.asyncio
async def test_route_buffers_when_peer_offline() -> None:
    reg = ConnectionRegistry()
    phone_ws = FakeWS()
    await reg.register("tok", "phone", phone_ws)
    # Agent 未上线

    env = _envelope(sender="phone", to="agent")
    raw = json.dumps(env)
    await _route_envelope(phone_ws, reg, "tok", "phone", raw)

    # 手机没收到错误
    assert phone_ws.sent == []
    # 缓冲里应当有一条
    snap = reg._snapshot()
    assert snap["tok"]["buffer_sizes"]["agent"] == 1


@pytest.mark.asyncio
async def test_route_buffer_overflow_replies_error() -> None:
    reg = ConnectionRegistry()
    phone_ws = FakeWS()
    await reg.register("tok", "phone", phone_ws)

    # 预先灌满 agent 角色的离线队列
    for i in range(BUFFER_MAX_LEN):
        await reg.enqueue_for_offline("tok", "agent", f"pre{i}")

    env = _envelope(sender="phone", to="agent")
    raw = json.dumps(env)
    await _route_envelope(phone_ws, reg, "tok", "phone", raw)

    assert len(phone_ws.sent) == 1
    err = json.loads(phone_ws.sent[0])
    assert err["type"] == "error"
    assert err["payload"]["code"] == "buffer_overflow"
    assert err["corr_id"] == env["msg_id"]
