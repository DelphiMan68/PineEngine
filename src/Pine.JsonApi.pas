unit Pine.JsonApi;

(* JSON facade of the interpreter. Three independent inputs on purpose:

    script (plain text) + candles (JSON array) + settings (JSON object)
      -> RunPine -> response (JSON)

  RunPine never raises - a malformed document, a script with a syntax
  error, or a runtime error all come back as a normal JSON string with an
  "error" member, so the caller never has to deal with anything other than
  JSON coming out.

  Candles JSON shape - a plain JSON array, one object per bar, or '' / '[]'
  to skip it and run on synthetic data instead:
  [
    {"time": 1704067200, "open": 1, "high": 1.2, "low": 0.9, "close": 1.1,
     "volume": 1000},
    ...
  ]
  A bar's "time" may be a JSON number (unix seconds) or a JSON string
  ("2024-01-31" or a unix timestamp as text); if omitted, the bar's index
  in the array is used as its time.

  Settings JSON shape (every field is optional, '' / '{}' means "defaults"):
  {
    "syntheticBars": 200,      // only used when no candles were given
    "seed": 12345,             // synthetic data is a deterministic random walk
    "startPrice": 100,
    "inputs": {"Length": 14, "Use EMA": true, "Mode": "fast"},  // input.*() overrides
    "pretty": false            // pretty-print the response, default false
  }

  Response shape (success):
  {
    "title": "...", "shortTitle": "...", "overlay": true, "isStrategy": false,
    "barCount": 200,
    "plots": [
      {"title": "...", "kind": "plot"|"hline"|"bgcolor", "color": "#RRGGBBAA",
       "values": [null, 1.23, ...]}    // one entry per bar, null = na
    ],
    "lines": [                          // from line.new(); deleted ones omitted
      {"x1": 10, "y1": 1.2, "x2": 15, "y2": 1.3, "color": "#RRGGBBAA",
       "style": "solid", "width": 1}
    ],
    "labels": [                         // from label.new(); deleted ones omitted
      {"x": 15, "y": 1.3, "text": "...", "color": "#RRGGBBAA",
       "textColor": "#RRGGBBAA", "style": "label_down"}
    ],
    "boxes": [                          // from box.new(); deleted ones omitted
      {"left": 10, "top": 1.3, "right": 15, "bottom": 1.1,
       "bgColor": "#RRGGBBAA", "borderColor": "#RRGGBBAA", "borderStyle": "solid"}
    ],
    "tables": [                         // from table.new(); deleted ones omitted
      {"position": "top_right", "columns": 3, "rows": 7,
       "cells": [{"column": 0, "row": 0, "text": "...", "textColor": "#RRGGBBAA",
                  "bgColor": "#RRGGBBAA", "mergeToColumn": 2, "mergeToRow": 0}]}
    ],
    "logs": ["bar 12 [info]: ..."],
    "alerts": ["bar 40: Golden cross"]
  }

  Response shape (error):
  { "error": { "type": "input"|"syntax"|"runtime"|"internal", "message": "...",
               "line": 12, "sourceLine": "x = foo(1,"  } }
  "line" is the 1-based line of the Pine script that caused a syntax or
  runtime error, and "sourceLine" the text of that line; both are left out
  when the error isn't tied to a script line (bad candles/settings JSON, an
  empty script, ...). For a runtime error inside a user-defined function
  it is the line inside that function's body where things went wrong. *)

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  Pine.Types, Pine.Runtime, Pine.Interpreter, Pine.Json;

(* Never raises: every failure is reported as {"error": {...}} in the
  returned string instead.
    AScriptSource   plain Pine Script text (not JSON).
    ACandlesJson    a JSON array of candles as described above, or '' / '[]'
                    to run on synthetic data instead.
    ASettingsJson   the JSON object described above, or '' / '{}' for
                    all defaults. *)
function RunPine(const AScriptSource: string; const ACandlesJson: string = '';
  const ASettingsJson: string = ''): string;

implementation

function KindName(AKind: TPinePlotKind): string;
begin
  case AKind of
    ppkPlot:
      Result := 'plot';
    ppkHLine:
      Result := 'hline';
    ppkBgColor:
      Result := 'bgcolor';
  else
    Result := 'plot';
  end;
end;

function ParseBarsFromJson(ABarsNode: TJsonValue): TPineBarSet;
var
  I: Integer;
  LItem, LTimeNode: TJsonValue;
  LBar: TPineBar;
begin
  Result := TPineBarSet.Create;
  try
    for I := 0 to ABarsNode.ItemCount - 1 do
    begin
      LItem := ABarsNode.Item(I);
      if LItem.Kind <> jkObject then
        raise EPineRuntimeError.CreateFmt('bars[%d] must be a JSON object', [I]);
      LBar.Open := LItem.GetNum('open', NaN);
      LBar.High := LItem.GetNum('high', NaN);
      LBar.Low := LItem.GetNum('low', NaN);
      LBar.Close := LItem.GetNum('close', NaN);
      LBar.Volume := LItem.GetNum('volume', 0);
      if IsNan(LBar.Open) or IsNan(LBar.High) or IsNan(LBar.Low) or IsNan(LBar.Close) then
        raise EPineRuntimeError.CreateFmt(
          'bars[%d] must have numeric open/high/low/close', [I]);
      LTimeNode := LItem.Get('time');
      if LTimeNode = nil then
        LBar.Time := I
      else if LTimeNode.Kind = jkString then
        LBar.Time := ParseBarTime(LTimeNode.AsString)
      else
        LBar.Time := Trunc(LTimeNode.AsFloat);
      Result.Add(LBar);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ Converts an "inputs" JSON object into typed Pine values, keyed by the
  input() title exactly as the script declares it. }
function BuildInputOverrides(AInputsNode: TJsonValue): TDictionary<string, TPineValue>;
var
  I: Integer;
  LValue: TJsonValue;
  LPine: TPineValue;
begin
  Result := TDictionary<string, TPineValue>.Create;
  if (AInputsNode = nil) or (AInputsNode.Kind <> jkObject) then
    Exit;
  for I := 0 to AInputsNode.MemberCount - 1 do
  begin
    LValue := AInputsNode.MemberValue(I);
    case LValue.Kind of
      jkBool:
        LPine := PineBool(LValue.AsBool);
      jkNumber:
        LPine := PineFloat(LValue.AsFloat);
      jkString:
        LPine := PineString(LValue.AsString);
    else
      Continue; // null / array / object overrides are ignored
    end;
    Result.AddOrSetValue(AInputsNode.MemberName(I), LPine);
  end;
end;

function BuildResponse(ACtx: TPineContext): TJsonValue;
var
  LPlots, LPlotObj, LValues, LLogs, LAlerts, LLines, LLineObj, LLabels, LLabelObj,
    LBoxes, LBoxObj, LTables, LTableObj, LCells, LCellObj: TJsonValue;
  LPlot: TPinePlot;
  I, J: Integer;
  LValue: Double;
  LLine: TPineLineObj;
  LLabel: TPineLabelObj;
  LBox: TPineBoxObj;
  LTable: TPineTableObj;
begin
  Result := JsonObj;
  try
    Result.Put('title', JsonStr(ACtx.Output.Title));
    Result.Put('shortTitle', JsonStr(ACtx.Output.ShortTitle));
    Result.Put('overlay', JsonBool(ACtx.Output.Overlay));
    Result.Put('isStrategy', JsonBool(ACtx.Output.IsStrategy));
    Result.Put('barCount', JsonInt(ACtx.Bars.Count));

    LPlots := JsonArr;
    for J := 0 to ACtx.Output.PlotCount - 1 do
    begin
      LPlot := ACtx.Output.Plots[J];
      LValues := JsonArr;
      for I := 0 to ACtx.Bars.Count - 1 do
      begin
        LValue := LPlot.ValueAt(I);
        if IsNan(LValue) then
          LValues.Add(JsonNull)
        else if LPlot.Kind = ppkBgColor then
          LValues.Add(JsonStr(ColorToHex(Cardinal(Trunc(LValue)))))
        else
          LValues.Add(JsonNumber(LValue));
      end;
      LPlotObj := JsonObj;
      LPlotObj.Put('title', JsonStr(LPlot.Title));
      LPlotObj.Put('kind', JsonStr(KindName(LPlot.Kind)));
      LPlotObj.Put('color', JsonStr(ColorToHex(LPlot.Color)));
      LPlotObj.Put('values', LValues);
      LPlots.Add(LPlotObj);
    end;
    Result.Put('plots', LPlots);

    { line.new()/label.new() drawings the script left on the chart, in
      creation order. Deleted ones (line.delete()/label.delete() was
      called and never re-created) are left out. There is no actual chart
      to draw these on - bar/price coordinates are reported as-is so the
      caller can render them if it wants to. }
    LLines := JsonArr;
    for I := 0 to ACtx.Output.Lines.Count - 1 do
    begin
      LLine := ACtx.Output.Lines[I];
      if LLine.Deleted then
        Continue;
      LLineObj := JsonObj;
      LLineObj.Put('x1', JsonNumber(LLine.X1));
      LLineObj.Put('y1', JsonNumber(LLine.Y1));
      LLineObj.Put('x2', JsonNumber(LLine.X2));
      LLineObj.Put('y2', JsonNumber(LLine.Y2));
      LLineObj.Put('color', JsonStr(ColorToHex(LLine.LineColor)));
      LLineObj.Put('style', JsonStr(LLine.Style));
      LLineObj.Put('width', JsonInt(LLine.Width));
      LLines.Add(LLineObj);
    end;
    Result.Put('lines', LLines);

    LLabels := JsonArr;
    for I := 0 to ACtx.Output.Labels.Count - 1 do
    begin
      LLabel := ACtx.Output.Labels[I];
      if LLabel.Deleted then
        Continue;
      LLabelObj := JsonObj;
      LLabelObj.Put('x', JsonNumber(LLabel.X));
      LLabelObj.Put('y', JsonNumber(LLabel.Y));
      LLabelObj.Put('text', JsonStr(LLabel.Text));
      LLabelObj.Put('color', JsonStr(ColorToHex(LLabel.LabelColor)));
      LLabelObj.Put('textColor', JsonStr(ColorToHex(LLabel.TextColor)));
      LLabelObj.Put('style', JsonStr(LLabel.Style));
      LLabels.Add(LLabelObj);
    end;
    Result.Put('labels', LLabels);

    LBoxes := JsonArr;
    for I := 0 to ACtx.Output.Boxes.Count - 1 do
    begin
      LBox := ACtx.Output.Boxes[I];
      if LBox.Deleted then
        Continue;
      LBoxObj := JsonObj;
      LBoxObj.Put('left', JsonNumber(LBox.Left));
      LBoxObj.Put('top', JsonNumber(LBox.Top));
      LBoxObj.Put('right', JsonNumber(LBox.Right));
      LBoxObj.Put('bottom', JsonNumber(LBox.Bottom));
      LBoxObj.Put('bgColor', JsonStr(ColorToHex(LBox.BgColor)));
      LBoxObj.Put('borderColor', JsonStr(ColorToHex(LBox.BorderColor)));
      LBoxObj.Put('borderStyle', JsonStr(LBox.BorderStyle));
      LBoxes.Add(LBoxObj);
    end;
    Result.Put('boxes', LBoxes);

    { table.new()/table.cell() dashboards. Each table's cells are listed as
      a flat array (sparse - only cells that were actually set appear);
      mergeToColumn/mergeToRow equal column/row for a cell that was never
      merged. }
    LTables := JsonArr;
    for I := 0 to ACtx.Output.Tables.Count - 1 do
    begin
      LTable := ACtx.Output.Tables[I];
      if LTable.Deleted then
        Continue;
      LTableObj := JsonObj;
      LTableObj.Put('position', JsonStr(LTable.Position));
      LTableObj.Put('columns', JsonInt(LTable.Columns));
      LTableObj.Put('rows', JsonInt(LTable.Rows));
      LCells := JsonArr;
      for J := 0 to LTable.Cells.Count - 1 do
      begin
        LCellObj := JsonObj;
        LCellObj.Put('column', JsonInt(LTable.Cells[J].Col));
        LCellObj.Put('row', JsonInt(LTable.Cells[J].Row));
        LCellObj.Put('text', JsonStr(LTable.Cells[J].Text));
        LCellObj.Put('textColor', JsonStr(ColorToHex(LTable.Cells[J].TextColor)));
        LCellObj.Put('bgColor', JsonStr(ColorToHex(LTable.Cells[J].BgColor)));
        LCellObj.Put('mergeToColumn', JsonInt(LTable.Cells[J].MergeToCol));
        LCellObj.Put('mergeToRow', JsonInt(LTable.Cells[J].MergeToRow));
        LCells.Add(LCellObj);
      end;
      LTableObj.Put('cells', LCells);
      LTables.Add(LTableObj);
    end;
    Result.Put('tables', LTables);

    LLogs := JsonArr;
    for I := 0 to ACtx.Output.Logs.Count - 1 do
      LLogs.Add(JsonStr(ACtx.Output.Logs[I]));
    Result.Put('logs', LLogs);

    LAlerts := JsonArr;
    for I := 0 to ACtx.Output.Alerts.Count - 1 do
      LAlerts.Add(JsonStr(ACtx.Output.Alerts[I]));
    Result.Put('alerts', LAlerts);
  except
    Result.Free;
    raise;
  end;
end;

{ Finds the script line a lexer/parser/interpreter message refers to, for
  errors that didn't get an explicit line stamped on them: the last
  "line <digits>" in the text ("... at line 12", "(line 12)", "at line 12,
  column 4"). 0 if there is none. }
function LineFromMessage(const AMessage: string): Integer;
var
  I, J, LStart: Integer;
begin
  Result := 0;
  I := 1;
  while I + 4 <= Length(AMessage) do
  begin
    if (AMessage[I] = 'l') and (Copy(AMessage, I, 5) = 'line ') then
    begin
      LStart := I + 5;
      J := LStart;
      while (J <= Length(AMessage)) and (AMessage[J] >= '0') and (AMessage[J] <= '9') do
        Inc(J);
      if J > LStart then
        Result := StrToIntDef(Copy(AMessage, LStart, J - LStart), 0);
      I := J;
    end
    else
      Inc(I);
  end;
end;

{ The text of one (1-based) line of the script, trimmed, or '' if the line
  number is out of range. }
function ScriptLineText(const AScript: string; ALine: Integer): string;
var
  LLines: TStringList;
begin
  Result := '';
  if ALine < 1 then
    Exit;
  LLines := TStringList.Create;
  try
    LLines.Text := AScript;
    if ALine <= LLines.Count then
      Result := Trim(LLines[ALine - 1]);
  finally
    LLines.Free;
  end;
end;

{ ALine = 0 means "no line known" and leaves "line"/"sourceLine" out. }
function BuildErrorJson(const AKind, AMessage: string; ALine: Integer;
  const ASourceLine: string): string;
var
  LRoot, LErr: TJsonValue;
begin
  LRoot := JsonObj;
  try
    LErr := JsonObj;
    LErr.Put('type', JsonStr(AKind));
    LErr.Put('message', JsonStr(AMessage));
    if ALine > 0 then
    begin
      LErr.Put('line', JsonInt(ALine));
      if ASourceLine <> '' then
        LErr.Put('sourceLine', JsonStr(ASourceLine));
    end;
    LRoot.Put('error', LErr);
    Result := LRoot.ToJson(False);
  finally
    LRoot.Free;
  end;
end;

function RunPine(const AScriptSource: string; const ACandlesJson: string;
  const ASettingsJson: string): string;
var
  LCandlesRoot, LSettingsRoot, LInputsNode, LResponse: TJsonValue;
  LBars: TPineBarSet;
  LInputs: TDictionary<string, TPineValue>;
  LCtx: TPineContext;
  LPretty: Boolean;
  LCandlesText, LSettingsText: string;
  LErrorLine: Integer;
begin
  LCandlesRoot := nil;
  LSettingsRoot := nil;
  LBars := nil;
  LInputs := nil;
  LCtx := nil;
  try
    try
      if Trim(AScriptSource) = '' then
        raise EPineRuntimeError.Create('The script is empty');

      LSettingsText := Trim(ASettingsJson);
      if LSettingsText = '' then
        LSettingsText := '{}';
      LSettingsRoot := ParseJson(LSettingsText);
      if LSettingsRoot.Kind <> jkObject then
        raise EPineRuntimeError.Create('The settings document must be a JSON object');
      LPretty := LSettingsRoot.GetBool('pretty', False);

      LCandlesText := Trim(ACandlesJson);
      if (LCandlesText <> '') and (LCandlesText <> '[]') then
      begin
        LCandlesRoot := ParseJson(LCandlesText);
        if LCandlesRoot.Kind <> jkArray then
          raise EPineRuntimeError.Create('The candles document must be a JSON array');
        if LCandlesRoot.ItemCount > 0 then
          LBars := ParseBarsFromJson(LCandlesRoot);
      end;
      if LBars = nil then
      begin
        LBars := TPineBarSet.Create;
        LBars.GenerateSynthetic(LSettingsRoot.GetInt('syntheticBars', 200),
          LSettingsRoot.GetInt('seed', 12345), LSettingsRoot.GetNum('startPrice', 100));
      end;
      if LBars.Count = 0 then
        raise EPineRuntimeError.Create('No bar data available');

      LInputsNode := LSettingsRoot.Get('inputs');
      LInputs := BuildInputOverrides(LInputsNode);

      LCtx := RunPineScript(AScriptSource, LBars, LInputs);
      LResponse := BuildResponse(LCtx);
      try
        Result := LResponse.ToJson(LPretty);
      finally
        LResponse.Free;
      end;
    except
      on E: EPineSyntaxError do
      begin
        LErrorLine := E.Line;
        if LErrorLine = 0 then
          LErrorLine := LineFromMessage(E.Message);
        Result := BuildErrorJson('syntax', E.Message, LErrorLine,
          ScriptLineText(AScriptSource, LErrorLine));
      end;
      on E: EPineRuntimeError do
      begin
        LErrorLine := E.Line;
        if LErrorLine = 0 then
          LErrorLine := LineFromMessage(E.Message);
        Result := BuildErrorJson('runtime', E.Message, LErrorLine,
          ScriptLineText(AScriptSource, LErrorLine));
      end;
      on E: EJsonError do
        Result := BuildErrorJson('input', 'Invalid JSON: ' + E.Message, 0, '');
      on E: Exception do
        Result := BuildErrorJson('internal', E.Message, 0, '');
    end;
  finally
    LCtx.Free;
    LInputs.Free;
    LBars.Free;
    LSettingsRoot.Free;
    LCandlesRoot.Free;
  end;
end;

end.
