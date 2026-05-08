"""Bearer token 鉴权。

从环境变量 ``MIA_AUTH_TOKENS`` 读取允许的 token 白名单（逗号分隔）。
token 既用作鉴权凭证，也用作账号标识：同一 token 的手机与 Agent 视为同一账号。
"""
from __future__ import annotations

import os


def _load_tokens(raw: str | None) -> frozenset[str]:
    """从原始环境变量值解析出 token 集合。

    - 逗号分隔，忽略空白和空条目；
    - 返回不可变集合，线程/协程安全地读取。
    """
    if not raw:
        return frozenset()
    parts = (p.strip() for p in raw.split(","))
    return frozenset(p for p in parts if p)


def load_tokens_from_env() -> frozenset[str]:
    """加载当前进程 ``MIA_AUTH_TOKENS`` 的 token 集合。"""
    return _load_tokens(os.environ.get("MIA_AUTH_TOKENS"))


def validate_token(
    auth_header: str | None,
    allowed: frozenset[str] | None = None,
) -> str | None:
    """校验 ``Authorization`` 请求头。

    返回 token 字符串（即账号 ID）当且仅当头合法且 token 在白名单中，
    否则返回 ``None``。设计为无状态、纯函数——便于测试。

    - ``auth_header``：原始 ``Authorization`` 头值，如 ``"Bearer abc"``。
    - ``allowed``：白名单集合；若为 None 则从环境变量读取。
    """
    if allowed is None:
        allowed = load_tokens_from_env()
    if not auth_header:
        return None

    # 严格只认 "Bearer <token>"
    parts = auth_header.split(None, 1)
    if len(parts) != 2:
        return None
    scheme, token = parts[0], parts[1].strip()
    if scheme.lower() != "bearer" or not token:
        return None
    if token not in allowed:
        return None
    return token
