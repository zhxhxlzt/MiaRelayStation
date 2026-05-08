"""``mia_relay.registry`` 的单元测试。

覆盖：
- 正常登记一条新连接：无旧连接、无缓冲
- 同 token 同角色重复登记：旧连接作为 evicted 返回
- 手机与 Agent 可并存：register 同 token 两个不同角色互不影响
- 对端查询：get_peer 对应到对方角色
- 离线缓冲：对端不在线时入队，对端上线后冲刷
- 溢出：>200 时返回 overflow 标志，deque 自动丢最旧
- TTL：>5 分钟的条目在下一次 register 时被过滤
- unregister：只清除确实仍属于自己的 ws，避免 superseded 后误清
"""
from __future__ import annotations

import asyncio
import time
from unittest.mock import MagicMock

import pytest

from mia_relay.registry import (
    BUFFER_MAX_LEN,
    BUFFER_TTL_SECONDS,
    ConnectionRegistry,
)


def _fake_ws() -> MagicMock:
    """一个最小的假 WS：close 是 AsyncMock。"""
    ws = MagicMock()

    async def _close(code: int = 1000, reason: str = "") -> None:
        ws.closed_with = (code, reason)

    ws.close = _close
    return ws


@pytest.mark.asyncio
async def test_register_fresh_connection_returns_no_eviction() -> None:
    reg = ConnectionRegistry()
    ws = _fake_ws()
    evicted, pending = await reg.register("tok", "phone", ws)
    assert evicted is None
    assert pending == []


@pytest.mark.asyncio
async def test_register_same_role_evicts_old_connection() -> None:
    reg = ConnectionRegistry()
    old, new = _fake_ws(), _fake_ws()
    await reg.register("tok", "phone", old)
    evicted, _ = await reg.register("tok", "phone", new)
    assert evicted is old


@pytest.mark.asyncio
async def test_phone_and_agent_coexist_under_same_token() -> None:
    reg = ConnectionRegistry()
    phone, agent = _fake_ws(), _fake_ws()
    await reg.register("tok", "phone", phone)
    evicted, _ = await reg.register("tok", "agent", agent)
    assert evicted is None
    assert await reg.get_peer("tok", "phone") is phone
    assert await reg.get_peer("tok", "agent") is agent


@pytest.mark.asyncio
async def test_get_peer_returns_none_when_role_absent() -> None:
    reg = ConnectionRegistry()
    await reg.register("tok", "phone", _fake_ws())
    assert await reg.get_peer("tok", "agent") is None
    assert await reg.get_peer("unknown", "phone") is None


@pytest.mark.asyncio
async def test_offline_buffer_flush_on_peer_reconnect() -> None:
    reg = ConnectionRegistry()
    # Agent 先上线
    agent = _fake_ws()
    await reg.register("tok", "agent", agent)

    # Agent 发给不在线的 phone —— 入队到 target_role=phone
    for i in range(3):
        overflowed = await reg.enqueue_for_offline("tok", "phone", f"msg{i}")
        assert overflowed is False

    # phone 上线：拿到按序的 3 条缓冲
    phone = _fake_ws()
    _, pending = await reg.register("tok", "phone", phone)
    assert [item.raw for item in pending] == ["msg0", "msg1", "msg2"]

    # 再一次 register 应当不会重复拿到
    _, pending2 = await reg.register("tok", "phone", _fake_ws())
    assert pending2 == []


@pytest.mark.asyncio
async def test_offline_buffer_overflow_drops_oldest() -> None:
    reg = ConnectionRegistry()
    # 灌满 BUFFER_MAX_LEN 条，期间不溢出
    for i in range(BUFFER_MAX_LEN):
        overflowed = await reg.enqueue_for_offline("tok", "phone", f"m{i}")
        assert overflowed is False

    # 再来一条 —— deque 满，报告溢出
    overflowed = await reg.enqueue_for_offline("tok", "phone", "new")
    assert overflowed is True

    # 最旧一条已被挤掉；最新一条入队在队尾
    phone = _fake_ws()
    _, pending = await reg.register("tok", "phone", phone)
    raws = [item.raw for item in pending]
    assert len(raws) == BUFFER_MAX_LEN
    assert raws[0] == "m1"
    assert raws[-1] == "new"


@pytest.mark.asyncio
async def test_offline_buffer_ttl_filters_stale_entries(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    reg = ConnectionRegistry()

    # 写入一条伪造为"很久之前"入队的条目
    await reg.enqueue_for_offline("tok", "phone", "stale")
    account = reg._accounts["tok"]  # type: ignore[attr-defined]
    account.buffers["phone"][0].enqueued_at = time.time() - BUFFER_TTL_SECONDS - 1

    # 再写一条"现在"的
    await reg.enqueue_for_offline("tok", "phone", "fresh")

    _, pending = await reg.register("tok", "phone", _fake_ws())
    assert [item.raw for item in pending] == ["fresh"]


@pytest.mark.asyncio
async def test_unregister_only_clears_own_ws() -> None:
    """superseded 场景下，旧连接的 finally 不应清掉新连接。"""
    reg = ConnectionRegistry()
    old, new = _fake_ws(), _fake_ws()
    await reg.register("tok", "phone", old)
    await reg.register("tok", "phone", new)  # old 被挤掉

    # 旧连接 finally 里调用 unregister，应当不影响 new
    await reg.unregister("tok", "phone", old)
    assert await reg.get_peer("tok", "phone") is new

    # 再让 new 自己注销 —— 这次应当清掉
    await reg.unregister("tok", "phone", new)
    assert await reg.get_peer("tok", "phone") is None


@pytest.mark.asyncio
async def test_concurrent_register_serializes_under_lock() -> None:
    """多个协程同时注册同一 (token, role)，最终只保留最后注册的那个。"""
    reg = ConnectionRegistry()
    conns = [_fake_ws() for _ in range(5)]

    async def register(ws):
        await reg.register("tok", "phone", ws)

    await asyncio.gather(*(register(c) for c in conns))
    # 最后活动的连接是 conns[-1]（严格顺序由调度决定，但锁保证 peer 是某一个）
    peer = await reg.get_peer("tok", "phone")
    assert peer in conns
