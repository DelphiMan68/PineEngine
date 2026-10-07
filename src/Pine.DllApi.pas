unit Pine.DllApi;

(* Implementation behind the PineEngine DLL/shared-object. This unit holds
  the actual exported functions; the library project file
  (demo/PineLib.dpr, which builds with both Delphi and Free Pascal) just
  `uses` this unit and lists the same three names in its `exports` clause.

  EVERY string crossing this boundary is a UTF-8, null-terminated C string
  (PAnsiChar on the Pascal side; `const char*` in C/C++, a byte string or
  `str` via an appropriate codec in other languages). This is the one
  representation every calling language already knows how to produce and
  consume, so no COM, no WideString, no language-specific marshaling helper
  is required anywhere.

  The calling convention is `cdecl` throughout - the default for C/C++ on
  every platform, and the one every FFI layer (Python's ctypes.CDLL, C#'s
  P/Invoke with CallingConvention.Cdecl, Node's ffi-napi, ...) can target
  without extra ceremony.

  Memory ownership rule, the only one that matters for correct use of this
  library: every PAnsiChar this library RETURNS to you (from PineRunJson
  or PineVersion) is allocated by this library and must be released by
  calling PineFreeString on it exactly once - never with your own
  language's free()/delete/Marshal.FreeHGlobal/etc., since that would free
  memory with the wrong allocator and corrupt the heap. Strings you PASS
  IN are only read, never taken ownership of - free them however you
  normally would, whenever you like, even immediately after the call
  returns. *)

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Pine.JsonApi;

(* The whole API. AScript is the Pine Script source (never JSON, required).
  ACandlesJson is a JSON array of candles (see Pine.JsonApi's RunPine doc
  comment for its shape) - pass an empty string, "[]", or nil to run on
  200 synthetic bars instead. ASettingsJson is the settings JSON object
  (input() overrides, synthetic-data knobs, the pretty-print flag) - pass
  an empty string, "{}", or nil for all defaults.

  Never raises and never returns nil: a malformed candles/settings
  document, a script that doesn't parse, or a runtime error during
  execution all come back as a normal {"error": {...}} JSON string (see
  Pine.JsonApi), exactly as they do from the PineRun console program. The
  returned pointer must be released with PineFreeString. *)
function PineRunJson(AScript, ACandlesJson, ASettingsJson: PAnsiChar): PAnsiChar; cdecl;

{ Releases a string previously returned by PineRunJson or PineVersion.
  Safe to call with nil (does nothing). Call it exactly once per returned
  pointer - calling it twice on the same pointer, or on a pointer this
  library did not return, is undefined behaviour, same as a double free in
  any language. }
procedure PineFreeString(AStr: PAnsiChar); cdecl;

{ A short "name version" string identifying this build, e.g.
  "PineEngine 1.0". Handy as a one-line smoke test that the library loaded
  and the calling convention / UTF-8 marshaling on your side are set up
  correctly before you move on to PineRunJson. Must also be released with
  PineFreeString. }
function PineVersion: PAnsiChar; cdecl;

implementation

const
  CPineDllVersion = 'PineEngine 1.0';

{ Decodes a UTF-8 C string into a native string. nil and an empty string
  both map to ''. }
function Utf8PCharToString(P: PAnsiChar): string;
var
  LBytes: TBytes;
  LLen: Integer;
begin
  if (P = nil) or (P^ = #0) then
    Exit('');
  LLen := StrLen(P);
  SetLength(LBytes, LLen);
  Move(P^, LBytes[0], LLen);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

{ Encodes a native string into a freshly heap-allocated, null-terminated
  UTF-8 C string. The caller of this function (always another function in
  this unit) hands that pointer onward to the library's caller, who must
  eventually pass it to PineFreeString. }
function StringToUtf8PChar(const S: string): PAnsiChar;
var
  LBytes: TBytes;
  LLen: Integer;
begin
  LBytes := TEncoding.UTF8.GetBytes(S);
  LLen := Length(LBytes);
  GetMem(Result, LLen + 1);
  if LLen > 0 then
    Move(LBytes[0], Result^, LLen);
  PByte(PAnsiChar(Result) + LLen)^ := 0;
end;

function PineRunJson(AScript, ACandlesJson, ASettingsJson: PAnsiChar): PAnsiChar; cdecl;
var
  LResultJson: string;
begin
  try
    LResultJson := RunPine(Utf8PCharToString(AScript), Utf8PCharToString(ACandlesJson),
      Utf8PCharToString(ASettingsJson));
  except
    on E: Exception do
      { RunPine itself never raises - this only guards the UTF-8 decoding
        above, so a malformed input buffer can never crash the caller's
        process or leak a Pascal exception across the DLL boundary. }
      LResultJson := '{"error":{"type":"internal","message":"' +
        StringReplace(StringReplace(E.Message, '\', '\\', [rfReplaceAll]),
        '"', '\"', [rfReplaceAll]) + '"}}';
  end;
  Result := StringToUtf8PChar(LResultJson);
end;

procedure PineFreeString(AStr: PAnsiChar); cdecl;
begin
  if AStr <> nil then
    FreeMem(AStr);
end;

function PineVersion: PAnsiChar; cdecl;
begin
  Result := StringToUtf8PChar(CPineDllVersion);
end;

end.
