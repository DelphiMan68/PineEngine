library PineLib;

(* PineEngine as a DLL / shared object - this one file builds with either
  compiler, exactly like demo\PineRun.dpr does.

  Build with Delphi:
    dcc32 -U..\src -E. -$Q- PineLib.dpr        (32-bit -> PineLib.dll)
    dcc64 -U..\src -E. -$Q- PineLib.dpr        (64-bit -> PineLib.dll)

  Build with Free Pascal:
    fpc -Mdelphi -Sh -O2 -Fu../src -FE. PineLib.dpr
      (-> PineLib.dll on Windows, libPineLib.so on Linux/macOS)

  See demo\build_dll.bat / build_dll.sh for ready-made versions of these.

  Produces a library that exports three cdecl functions - PineRunJson,
  PineFreeString, PineVersion - documented in src\Pine.DllApi.pas, which
  holds the actual implementation.

  See samples\dll-clients\ for how to call this library from Delphi, C++,
  C#, Python, and Free Pascal; the same pattern works from any language
  with a C FFI. *)

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  Pine.Types,
  Pine.Lexer,
  Pine.Ast,
  Pine.Parser,
  Pine.Runtime,
  Pine.Builtins,
  Pine.Interpreter,
  Pine.Json,
  Pine.JsonApi,
  Pine.DllApi;

exports
  PineRunJson,
  PineFreeString,
  PineVersion;

begin
end.
