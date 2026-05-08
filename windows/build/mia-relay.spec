# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for Mia Cloud Relay (Windows single-file exe).

本 spec 仅被 ``cloud/windows/build/build-relay.ps1`` 调用，不要直接手动跑。
构建入口是 ``cloud/src/mia_relay/main.py`` 的 ``main()`` 函数——运行 exe 等同于
``python -m mia_relay.main``。

两个关键点：

1) ``hiddenimports`` —— PyInstaller 的静态分析看不穿 uvicorn/websockets 这类
   通过字符串动态 import 的子模块；不显式列出，打包出的 exe 会在运行时抛
   ``ModuleNotFoundError``。下方清单覆盖了 uvicorn 0.27+ 在 Windows 下启动
   WebSocket HTTP 服务所需的所有实现细节（h11 + websockets legacy 后端 +
   asyncio loop + lifespan + logging）。

2) ``excludes=['uvloop']`` —— uvicorn[standard] 在 Linux 会可选引入 uvloop，但
   Windows 版 uvloop 不存在。让 PyInstaller 静默跳过即可，否则 onefile 里会塞
   一份无用且启动时尝试加载失败的占位。
"""
from __future__ import annotations

import os
from pathlib import Path

# 本文件位于 cloud/windows/build/；真实入口是同目录下的 entry.py，它以包内
# 方式调用 mia_relay.main.main()。不要把 cloud/src/mia_relay/main.py 直接
# 作为 PyInstaller 入口——那会触发相对导入失败（详见 entry.py docstring）。
_SPEC_DIR = Path(os.path.abspath(SPEC))  # type: ignore[name-defined]  # noqa: F821
_CLOUD_DIR = _SPEC_DIR.parent.parent.parent  # cloud/
_ENTRY = str(_SPEC_DIR.parent / "entry.py")          # cloud/windows/build/entry.py

block_cipher = None


a = Analysis(
    [_ENTRY],
    pathex=[str(_CLOUD_DIR / "src")],
    binaries=[],
    datas=[],
    hiddenimports=[
        # uvicorn 动态加载的实现后端
        "uvicorn.loops.asyncio",
        "uvicorn.protocols.http.h11_impl",
        "uvicorn.protocols.websockets.websockets_impl",
        "uvicorn.lifespan.on",
        "uvicorn.logging",
        # websockets 的 server 实现（uvicorn.protocols.websockets.websockets_impl
        # 内部 import 的 legacy 路径，某些版本 PyInstaller 扫不到）
        "websockets.legacy.server",
        # mia_relay 包本身 + main 模块。uvicorn.run("mia_relay.main:app", ...)
        # 在运行时按字符串动态 importlib，必须保证这俩在归档里。
        "mia_relay",
        "mia_relay.main",
        # mia_relay 子模块（Analysis 正常可扫到，冗余列出以防路径解析差异）
        "mia_relay.auth",
        "mia_relay.registry",
        "mia_relay.ws_endpoints",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "uvloop",  # Linux 专属，Windows 无此包
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="mia-relay",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,            # 不启用 UPX：加重 Defender 误杀概率
    upx_exclude=[],
    runtime_tmpdir=None,  # onefile 默认解压到 %TEMP%\_MEIxxxxxx
    console=True,         # 需要在 WinSW 管道里看 uvicorn 的 stdout/stderr
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    # onefile 模式由"将 a.binaries/a.zipfiles/a.datas 作为位置参数并入此 EXE"
    # 这一组合表达——无需额外 onefile 关键字（PyInstaller 不认 onefile=）。
)
