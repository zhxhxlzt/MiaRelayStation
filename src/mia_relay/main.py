"""Mia 中继的 FastAPI 入口。

在这里：
- 读入 .env（如有）；
- 组装 FastAPI 应用；
- 挂载 /health（无鉴权）、/ws/phone、/ws/agent；
- 通过 uvicorn 暴露给 Caddy。

本模块本身不实现鉴权/注册/转发逻辑，只做装配。
"""
from __future__ import annotations

import os

from dotenv import load_dotenv
from fastapi import FastAPI

from .registry import ConnectionRegistry
from .ws_endpoints import build_ws_router


def create_app() -> FastAPI:
    """构造一个配置齐全的 FastAPI 应用。"""
    load_dotenv()

    app = FastAPI(
        title="Mia Cloud Relay",
        version="0.1.0",
        description="在手机与 PC Agent 之间转发 wire-protocol v=1 信封的最小中继。",
        docs_url=None,  # MVP 不需要 Swagger UI
        redoc_url=None,
    )

    registry = ConnectionRegistry()
    app.state.registry = registry

    @app.get("/health")
    async def health() -> dict[str, bool]:
        """探活端点，无鉴权。

        Caddy / 运维脚本 / 手机端"测试连接"按钮都会调这个。
        """
        return {"ok": True}

    app.include_router(build_ws_router(registry))
    return app


app = create_app()


def main() -> None:
    """命令行入口：``python -m mia_relay.main``。"""
    import uvicorn  # 延迟导入，方便单元测试绕过

    host = os.environ.get("MIA_RELAY_HOST", "0.0.0.0")
    port = int(os.environ.get("MIA_RELAY_PORT", "8000"))
    # WebSocket 级心跳：30 秒 ping、90 秒无 pong/流量则断开。
    # 与 wire-protocol 规范的 Requirement: 心跳与空闲断连 对齐。
    uvicorn.run(
        "mia_relay.main:app",
        host=host,
        port=port,
        log_level="info",
        ws_ping_interval=30.0,
        ws_ping_timeout=90.0,
    )


if __name__ == "__main__":
    main()
