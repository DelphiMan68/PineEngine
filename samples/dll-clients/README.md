# Calling PineEngine from other languages

`demo/PineLib.dpr` builds the interpreter as a DLL (Windows) or shared
object (Linux/macOS via Free Pascal), exporting three plain C functions:

```
char* PineRunJson(const char* script, const char* candlesJson, const char* settingsJson);  // cdecl
void  PineFreeString(char* str);                                                            // cdecl
char* PineVersion(void);                                                                    // cdecl
```

Full contract (UTF-8 encoding, ownership rules, parameter meaning) is
documented in `src/Pine.DllApi.pas`. In short:

- Every string in and out is a **UTF-8, null-terminated C string** - the
  one format every language here already knows how to produce/consume.
- The calling convention is **`cdecl`** everywhere - the default for
  C/C++, and what every FFI layer below targets explicitly.
- `PineRunJson` and `PineVersion` **allocate** the string they return.
  Call `PineFreeString` on that exact pointer exactly once when you're
  done with it - never your own language's `free`/`delete`/GC. Strings
  you *pass in* are only read; manage them however you normally would.
- `PineRunJson` never raises/throws and never returns null - a bad
  script, bad JSON, or a runtime error all come back as a normal
  `{"error": {...}}` JSON string.

## 1. Build the library

```
cd demo
build_dll.bat          :: Delphi, command line -> PineLib.dll
./build_dll.sh          # Free Pascal, command line -> PineLib.dll (Windows) or libPineLib.so (Linux/macOS)
```

or open `demo/PineLib.lpi` in the Lazarus IDE and build (Run ▸ Build) —
`PineLib.lpr` includes `PineLib.dpr` verbatim, so it's the exact same
source either way.

Copy the resulting `PineLib.dll` / `libPineLib.so` into this
`dll-clients` folder (or anywhere each example's loader will find it -
each example's comment header says exactly where it looks).

## 2. Run an example

| Language | File | How to run |
| --- | --- | --- |
| Delphi or Free Pascal | `pascal_client_example.dpr` | `dcc32 -E. pascal_client_example.dpr` or `fpc -Mdelphi -FE. pascal_client_example.dpr`, then run the executable |
| C++ | `cpp_client_example.cpp` | `g++ -o cpp_client_example cpp_client_example.cpp` (add `-ldl` on Linux), then run it |
| C# | `CSharpClientExample.cs` | `dotnet run CSharpClientExample.cs` (or `csc` + run the `.exe`) |
| Python | `python_client_example.py` | `python3 python_client_example.py` (no dependencies beyond the standard library) |

Every example does the same three things: print `PineVersion()`, run a
small script (`plot(close)` + `plot(ta.sma(close, 10))`) over 30 synthetic
bars, and print the resulting JSON - so you can diff their output against
each other to confirm the library behaves identically no matter which
language is driving it.

## 3. Using it in your own project

The pattern is always: declare the three functions with `cdecl` and
UTF-8/C-string parameter and return types, call `PineRunJson`, read the
JSON, call `PineFreeString` on the pointer you got back. None of the
examples need an import library (`.lib`/`.def`) - Pascal links an
`external` DLL function directly by name, C++ loads it dynamically with
`LoadLibrary`/`dlopen`, and C#/Python's FFI layers resolve it by name too.
This also means the exact same `PineLib.dll` works unmodified whether it
was built with Delphi or Free Pascal - nothing about the calling side
needs to know which.
