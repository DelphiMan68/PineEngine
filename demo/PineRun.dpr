program PineRun;

(* Console entry point of the Pine Script library.

  This program prints exactly one line of JSON to standard output and
  nothing else - no banners, no tables, no error text outside of JSON.
  It is meant to be used as a subprocess/pipe from any language.

  Four independent arguments:

    PineRun <script.pine> [candles.json] [settings.json] [output.json]

  - <script.pine>    path to a plain text file with the Pine Script source.
                      This is never JSON, just the code as-is.
  - [candles.json]   optional. Either a path to a JSON file, or the JSON
                      text itself passed directly on the command line.
                      A plain JSON ARRAY of candles, e.g.
                      [{"time":1700000000,"open":1,"high":1.2,"low":0.9,
                        "close":1.1,"volume":1000}, ...]
                      Omit it (or pass "[]") to run on synthetic data.
  - [settings.json]  optional. Either a path to a JSON file, or the JSON
                      text itself. A JSON OBJECT with input() overrides,
                      the synthetic-data settings (used only when no
                      candles were given) and the pretty-print flag. See
                      Pine.JsonApi.pas for the exact shape.
  - [output.json]    optional. A path to save the result JSON to. The
                      result is still printed to standard output either
                      way - this only additionally saves a copy to disk.
                      If the file can't be written, a message is printed
                      to standard ERROR (never to standard output, which
                      always stays pure JSON) and the program still exits
                      normally with the result already on stdout.

  Examples:
    PineRun strategy.pine candles.json
    PineRun strategy.pine candles.json settings.json
    PineRun strategy.pine candles.json settings.json result.json
    PineRun strategy.pine "[]" "{\"syntheticBars\": 500}" result.json
    PineRun strategy.pine                              (all-synthetic run) *)

{$APPTYPE CONSOLE}
{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

uses
  SysUtils,
  Classes,
  Pine.Types,
  Pine.Lexer,
  Pine.Ast,
  Pine.Parser,
  Pine.Runtime,
  Pine.Builtins,
  Pine.Interpreter,
  Pine.Json,
  Pine.JsonApi;

function ReadTextFile(const AFileName: string): string;
var
  LLines: TStringList;
begin
  LLines := TStringList.Create;
  try
    LLines.LoadFromFile(AFileName);
    Result := LLines.Text;
  finally
    LLines.Free;
  end;
end;

{ Any JSON argument may be a path to a JSON file or literal JSON text typed
  straight on the command line - whichever the caller finds handier. }
function ResolveJsonArgument(const AArg, ADefault: string): string;
begin
  if AArg = '' then
    Result := ADefault
  else if FileExists(AArg) then
    Result := ReadTextFile(AArg)
  else
    Result := AArg;
end;

procedure WriteTextFile(const AFileName, AContent: string);
var
  LLines: TStringList;
begin
  LLines := TStringList.Create;
  try
    LLines.Text := AContent;
    LLines.SaveToFile(AFileName);
  finally
    LLines.Free;
  end;
end;

function BuildErrorJson(const AMessage: string): string;
begin
  Result := '{"error":{"type":"input","message":"' +
    StringReplace(StringReplace(AMessage, '\', '\\', [rfReplaceAll]),
    '"', '\"', [rfReplaceAll]) + '"}}';
end;

var
  LScriptSource, LCandlesArg, LSettingsArg, LOutputArg, LResultJson: string;
begin
  if (ParamCount < 1) or not FileExists(ParamStr(1)) then
  begin
    Writeln(BuildErrorJson('Usage: PineRun <script.pine> [candles.json] ' +
      '[settings.json] [output.json]. The script file was not found.'));
    Halt(1);
  end;
  LScriptSource := ReadTextFile(ParamStr(1));
  if ParamCount >= 2 then
    LCandlesArg := ParamStr(2)
  else
    LCandlesArg := '';
  if ParamCount >= 3 then
    LSettingsArg := ParamStr(3)
  else
    LSettingsArg := '';
  if ParamCount >= 4 then
    LOutputArg := ParamStr(4)
  else
    LOutputArg := '';

  LResultJson := RunPine(LScriptSource, ResolveJsonArgument(LCandlesArg, '[]'),
    ResolveJsonArgument(LSettingsArg, '{}'));

  { The one and only line this program ever writes to stdout. }
  Writeln(LResultJson);

  if LOutputArg <> '' then
    try
      WriteTextFile(LOutputArg, LResultJson);
    except
      on E: Exception do
        // stdout must stay pure JSON - a save failure is reported on
        // stderr only, and never changes the process exit behaviour.
        Writeln(ErrOutput, 'Could not save output to "' + LOutputArg +
          '": ' + E.Message);
    end;
end.
