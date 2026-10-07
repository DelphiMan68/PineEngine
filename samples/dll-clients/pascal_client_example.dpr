program pascal_client_example;

(* Calls PineLib.dll (or libPineLib.so) from Pascal. This one file builds
  with either compiler, exactly like the library itself does:

    dcc32 -E. pascal_client_example.dpr
    fpc -Mdelphi -FE. pascal_client_example.dpr

  Run it with PineLib.dll (Windows) or libPineLib.so (Linux/macOS, run
  from the same directory, or put it somewhere your loader searches) next
  to the produced executable. *)

{$APPTYPE CONSOLE}
{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

uses
  SysUtils;

{ The library's three exports, declared as plain external Pascal
  functions - no wrapper DLL/unit of its own is needed on this side since
  Pascal can link an external cdecl function directly. }

{$IFDEF MSWINDOWS}
const
  CLibName = 'PineLib.dll';
{$ELSE}
const
  CLibName = 'libPineLib.so';
{$ENDIF}

function PineRunJson(AScript, ACandlesJson, ASettingsJson: PAnsiChar): PAnsiChar;
  cdecl; external CLibName;
procedure PineFreeString(AStr: PAnsiChar); cdecl; external CLibName;
function PineVersion: PAnsiChar; cdecl; external CLibName;

{ Copies the UTF-8 C string the library returned into a normal Pascal
  string, then releases the library's own copy of it - every PAnsiChar
  PineRunJson/PineVersion return must be freed exactly this way, never
  with your own FreeMem/Dispose. }
function Consume(P: PAnsiChar): string;
begin
  if P = nil then
    Exit('');
  Result := UTF8ToString(P);
  PineFreeString(P);
end;

var
  LScript, LSettings, LResult: string;
  LScriptUtf8, LSettingsUtf8: UTF8String;
begin
  Writeln('Library version: ', Consume(PineVersion));
  Writeln;

  LScript :=
    '//@version=5' + sLineBreak +
    'indicator("Pascal client example")' + sLineBreak +
    'plot(close, "Close")' + sLineBreak +
    'plot(ta.sma(close, 10), "SMA 10")' + sLineBreak;
  LSettings := '{"syntheticBars": 30, "pretty": true}';

  { UTF8String locals guarantee the encoded bytes stay alive for the whole
    call - casting straight to PAnsiChar inline would also work here, but
    an explicit local is the safe habit for any longer-lived string. }
  LScriptUtf8 := UTF8String(LScript);
  LSettingsUtf8 := UTF8String(LSettings);

  LResult := Consume(PineRunJson(PAnsiChar(LScriptUtf8), '[]', PAnsiChar(LSettingsUtf8)));
  Writeln('Result JSON:');
  Writeln(LResult);
end.
