"""账号级连接注册表 + 离线缓冲。

数据模型：
- key 是 token（视为账号 ID）
- 每个账号下 ``phone`` / ``agent`` 各至多一条活动 WebSocket
- 每个账号维护一对离线队列 ``{phone, agent}``（``deque(maxlen=200)``），
  新信封到达时若对端不在线则入队，对端重连后按序冲刷。
- 容量 200 / TTL 5 分钟两者都由 ``ws_endpoints`` 层在入队/冲刷时参考本类的辅助。

关于"溢出"：``deque`` 满时自动丢最旧一条；调用方（ws_endpoints）在丢弃后
负责向发送方回 ``buffer_overflow`` 错误信封（由 ws_endpoints 实现，这里只做
数据结构与同步控制）。
"""
from __future__ import annotations

import asyncio
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Literal, Protocol


Role = Literal["phone", "agent"]
BUFFER_MAX_LEN = 200
BUFFER_TTL_SECONDS = 5 * 60  # 5 分钟


class WebSocketLike(Protocol):
    """最小的 WS 协议，便于单测用假 WS 替换。

    真实下对应 ``starlette.websockets.WebSocket``；单测里用 MagicMock。
    """

    async def close(self, code: int = 1000, reason: str = "") -> None: ...


@dataclass
class _BufferedEnvelope:
    """离线缓冲里的一条信封。"""

    raw: str  # 原始 JSON 文本，保证按字节原样投递
    enqueued_at: float  # time.time()，用于 TTL 判定


@dataclass
class _Account:
    """同一 token 下的账号状态。"""

    connections: dict[Role, WebSocketLike] = field(default_factory=dict)
    # 以"接收方角色"为 key 的离线队列
    buffers: dict[Role, deque[_BufferedEnvelope]] = field(
        default_factory=lambda: {
            "phone": deque(maxlen=BUFFER_MAX_LEN),
            "agent": deque(maxlen=BUFFER_MAX_LEN),
        }
    )


class ConnectionRegistry:
    """线程/协程安全的账号注册表。

    任何跨连接共享状态都在 ``self._lock`` 保护下读写；
    WebSocket 的 send/close 不在锁内调用，避免跨连接阻塞。
    """

    def __init__(self) -> None:
        self._accounts: dict[str, _Account] = {}
        self._lock = asyncio.Lock()

    async def register(
        self,
        token: str,
        role: Role,
        ws: WebSocketLike,
    ) -> tuple[WebSocketLike | None, list[_BufferedEnvelope]]:
        """登记一条新连接。

        返回 ``(被挤掉的旧连接或 None, 该 role 目前应当冲刷给新连接的缓冲列表)``。
        调用方负责：
        1) 对被挤掉的旧连接调用 ``close(1008, "superseded")``；
        2) 对返回的缓冲列表按序向新连接 ``send_text``；
        3) 在冲刷前过滤掉已超 TTL 的条目（本方法也会清理）。
        """
        async with self._lock:
            account = self._accounts.setdefault(token, _Account())
            evicted = account.connections.get(role)
            account.connections[role] = ws

            # 冲刷该角色的离线缓冲：过滤 TTL，然后全部带走。
            pending = self._drain_buffer_locked(account, role)
            return evicted, pending

    async def unregister(
        self,
        token: str,
        role: Role,
        ws: WebSocketLike,
    ) -> None:
        """在连接关闭时解除登记。

        仅当传入的 ``ws`` 仍是当前登记的那一条时才清除——避免在 superseded
        场景下，被挤掉的旧连接的 ``finally`` 把新连接也误删。
        """
        async with self._lock:
            account = self._accounts.get(token)
            if account is None:
                return
            current = account.connections.get(role)
            if current is ws:
                account.connections.pop(role, None)
            # 若账号两个角色都没了，连离线缓冲一起丢弃（会话已结束）。
            if not account.connections and self._buffers_empty(account):
                self._accounts.pop(token, None)

    async def get_peer(self, token: str, role: Role) -> WebSocketLike | None:
        """查询同账号下对端角色的当前连接；无则返回 None。"""
        async with self._lock:
            account = self._accounts.get(token)
            if account is None:
                return None
            return account.connections.get(role)

    async def enqueue_for_offline(
        self,
        token: str,
        target_role: Role,
        raw: str,
    ) -> bool:
        """对端不在线时把信封追加到对端角色的离线队列。

        返回 ``True`` 表示队列原本已满、有最旧条目被挤掉（调用方 → 回
        ``buffer_overflow``）；``False`` 表示正常入队。
        """
        async with self._lock:
            account = self._accounts.setdefault(token, _Account())
            buf = account.buffers[target_role]
            overflowed = len(buf) >= BUFFER_MAX_LEN
            buf.append(_BufferedEnvelope(raw=raw, enqueued_at=time.time()))
            return overflowed

    # ---------- 仅内部使用的辅助 ----------

    def _drain_buffer_locked(
        self,
        account: _Account,
        role: Role,
    ) -> list[_BufferedEnvelope]:
        """把 role 对应的离线队列按 TTL 过滤后整列带走。"""
        now = time.time()
        buf = account.buffers[role]
        fresh: list[_BufferedEnvelope] = [
            item for item in buf if now - item.enqueued_at <= BUFFER_TTL_SECONDS
        ]
        buf.clear()
        return fresh

    @staticmethod
    def _buffers_empty(account: _Account) -> bool:
        return all(len(q) == 0 for q in account.buffers.values())

    # ---------- 仅供测试/调试用 ----------

    def _snapshot(self) -> dict[str, Any]:
        """返回当前注册状态的浅快照——仅测试用，不保证稳定性。"""
        return {
            token: {
                "roles": list(acc.connections.keys()),
                "buffer_sizes": {r: len(q) for r, q in acc.buffers.items()},
            }
            for token, acc in self._accounts.items()
        }
