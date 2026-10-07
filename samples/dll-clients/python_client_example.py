"""python_client_example.py

Calls PineLib (built with either Delphi or Free Pascal - see
demo/PineLib.dpr) from Python via ctypes.

Run with PineLib.dll (Windows), libPineLib.so (Linux), or libPineLib.dylib
(macOS) in the same directory as this script, or on your platform's
library search path.

    python3 python_client_example.py
"""

import ctypes
import json
import os
import sys


def _library_path() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    if sys.platform.startswith("win"):
        name = "PineLib.dll"
    elif sys.platform == "darwin":
        name = "libPineLib.dylib"
    else:
        name = "libPineLib.so"
    return os.path.join(here, name)


_lib = ctypes.CDLL(_library_path())

# Declare the exact signatures. This matters: left to guess, ctypes
# assumes every function returns a plain C "int", which would silently
# truncate the 64-bit pointers PineRunJson/PineVersion return on a 64-bit
# build. The return type is c_void_p rather than c_char_p on purpose - see
# _consume() below for why.
_lib.PineRunJson.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
_lib.PineRunJson.restype = ctypes.c_void_p
_lib.PineFreeString.argtypes = [ctypes.c_void_p]
_lib.PineFreeString.restype = None
_lib.PineVersion.argtypes = []
_lib.PineVersion.restype = ctypes.c_void_p


def _consume(ptr: int) -> str:
    """Copies the UTF-8 C string at `ptr` into a Python str, then frees
    the library's own copy of it via PineFreeString. Never pass this
    pointer to anything else - it was allocated by the library's heap,
    not Python's."""
    if not ptr:
        return ""
    text = ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8")
    _lib.PineFreeString(ptr)
    return text


def pine_version() -> str:
    return _consume(_lib.PineVersion())


def pine_run(script: str, candles_json: str = "", settings_json: str = "") -> dict:
    """Runs a Pine script and returns the parsed JSON response (see
    src/Pine.JsonApi.pas for its exact shape - plots/logs/alerts/lines/
    labels/boxes/tables, or an "error" object)."""
    ptr = _lib.PineRunJson(
        script.encode("utf-8"),
        candles_json.encode("utf-8"),
        settings_json.encode("utf-8"),
    )
    return json.loads(_consume(ptr))


if __name__ == "__main__":
    print("Library version:", pine_version())
    print()

    script = (
        '//@version=5\n'
        'indicator("Python client example")\n'
        'plot(close, "Close")\n'
        'plot(ta.sma(close, 10), "SMA 10")\n'
    )
    settings = json.dumps({"syntheticBars": 30})

    result = pine_run(script, candles_json="[]", settings_json=settings)
    print("Result JSON:")
    print(json.dumps(result, indent=2))
