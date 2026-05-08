"""``mia_relay.auth`` 的单元测试。

覆盖场景：
- 合法 token → 返回账号 ID
- 缺失 Authorization 头 → None
- 未知 token → None
- Bearer 方案大小写不敏感
- 非 Bearer 方案 → None
- 畸形头（只有 "Bearer"、空 token）→ None
"""
from __future__ import annotations

import pytest

from mia_relay.auth import _load_tokens, validate_token


ALLOWED = frozenset({"alpha", "bravo"})


def test_valid_token_returns_account_id() -> None:
    assert validate_token("Bearer alpha", ALLOWED) == "alpha"


def test_missing_header_returns_none() -> None:
    assert validate_token(None, ALLOWED) is None
    assert validate_token("", ALLOWED) is None


def test_unknown_token_returns_none() -> None:
    assert validate_token("Bearer charlie", ALLOWED) is None


def test_scheme_is_case_insensitive() -> None:
    assert validate_token("bearer alpha", ALLOWED) == "alpha"
    assert validate_token("BEARER bravo", ALLOWED) == "bravo"


def test_non_bearer_scheme_rejected() -> None:
    assert validate_token("Basic alpha", ALLOWED) is None


@pytest.mark.parametrize(
    "header",
    ["Bearer", "Bearer ", "   ", "alpha"],
)
def test_malformed_header_rejected(header: str) -> None:
    assert validate_token(header, ALLOWED) is None


def test_env_parser_strips_whitespace_and_empties() -> None:
    assert _load_tokens(" a , b ,, c ,") == frozenset({"a", "b", "c"})
    assert _load_tokens(None) == frozenset()
    assert _load_tokens("") == frozenset()


def test_env_parser_deduplicates() -> None:
    assert _load_tokens("x,x,y") == frozenset({"x", "y"})
