"""PyInstaller onefile entrypoint shim for mia-relay.exe.

Why this file exists
--------------------
PyInstaller's onefile bootloader runs the entry script in *script mode* —
that is, the target file is exec'd with ``__package__ == ''`` and
``__name__ == '__main__'``. When the target is ``cloud/src/mia_relay/main.py``,
its first body-level statement is::

    from .registry import ConnectionRegistry

which immediately raises::

    ImportError: attempted relative import with no known parent package

The fix is to NOT use ``main.py`` as the entry. Instead, the entry is this
tiny shim that *imports* the ``mia_relay`` package (so Python builds the
package structure correctly, resolves all relative imports, and registers
``mia_relay`` + ``mia_relay.main`` in ``sys.modules``) and then calls its
``main()`` function.

This keeps the main codebase (``cloud/src/mia_relay/``) 100% unchanged —
``python -m mia_relay.main`` still works for dev, and the Windows onefile
build works too.
"""
from __future__ import annotations


def _run() -> None:
    # Imported lazily inside a function so that PyInstaller's module graph
    # analyzer sees a normal top-level ``import mia_relay.main`` (via the
    # hiddenimports in the spec) without triggering module execution before
    # the bootloader has finished extracting the onefile archive.
    from mia_relay.main import main
    main()


if __name__ == "__main__":
    _run()
