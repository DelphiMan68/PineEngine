unit Pine.Runtime;

{ Runtime environment of the interpreter:
  - TPineBarSet  : OHLCV data the script is executed on
  - TPinePlot    : one output series produced by plot()/hline()/bgcolor()
  - TPineOutput  : everything a script produced (plots, logs, alerts, metadata)
  - TPineContext : bar cursor + variable storage + per-call-site state }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Math, DateUtils, Generics.Collections, Pine.Types;

type
  TPineBar = record
    Time: Int64; // unix time in seconds
    Open: Double;
    High: Double;
    Low: Double;
    Close: Double;
    Volume: Double;
  end;

  TPineBarSet = class
  private
    FBars: TArray<TPineBar>;
    FCount: Integer;
    function GetBar(AIndex: Integer): TPineBar;
  public
    procedure Add(const ABar: TPineBar);
    { Loads a CSV file with the columns: time,open,high,low,close,volume
      The header line is optional, time may be a unix stamp or YYYY-MM-DD. }
    procedure LoadFromCSV(const AFileName: string);
    { Builds a deterministic random walk, useful for demos and tests. }
    procedure GenerateSynthetic(ACount: Integer; ASeed: Integer = 12345;
      AStartPrice: Double = 100);
    property Count: Integer read FCount;
    property Bars[AIndex: Integer]: TPineBar read GetBar; default;
  end;

  TPinePlotKind = (ppkPlot, ppkHLine, ppkBgColor);

  TPinePlot = class
  private
    FValues: TList<Double>;
    FColors: TList<Cardinal>;
    function GetCount: Integer;
  public
    Title: string;
    Color: Cardinal;
    Width: Integer;
    Kind: TPinePlotKind;
    constructor Create;
    destructor Destroy; override;
    procedure SetAt(ABar: Integer; AValue: Double; AColor: Cardinal);
    function ValueAt(ABar: Integer): Double;
    function ColorAt(ABar: Integer): Cardinal;
    property Count: Integer read GetCount;
  end;

  TPineOutput = class
  private
    FPlots: TObjectDictionary<Integer, TPinePlot>;
    FOrder: TList<Integer>;
    function GetPlot(AIndex: Integer): TPinePlot;
    function GetPlotCount: Integer;
  public
    Title: string;
    ShortTitle: string;
    Overlay: Boolean;
    IsStrategy: Boolean;
    Logs: TStringList;
    Alerts: TStringList;
    { Every line.new()/label.new() call registers itself here (in creation
      order) so the JSON API can report the script's drawings alongside its
      plots. Not owned here - the objects themselves live for the whole run
      via TPineContext.TrackRef; a Deleted flag (see TPineLineObj/
      TPineLabelObj) marks ones the script has since removed. }
    Lines: TList<TPineLineObj>;
    Labels: TList<TPineLabelObj>;
    Boxes: TList<TPineBoxObj>;
    Tables: TList<TPineTableObj>;
    constructor Create;
    destructor Destroy; override;
    { Returns the plot bound to the given call site, creating it on demand. }
    function PlotForSite(ASiteId: Integer; AKind: TPinePlotKind): TPinePlot;
    procedure SaveToCSV(const AFileName: string; ABars: TPineBarSet);
    property Plots[AIndex: Integer]: TPinePlot read GetPlot;
    property PlotCount: Integer read GetPlotCount;
  end;

  TPineContext = class
  private
    FGlobals: TObjectDictionary<string, TPineSeries>;
    FStates: TObjectDictionary<Integer, TCallState>;
    FInputOverrides: TDictionary<string, TPineValue>;
    FRefObjects: TObjectList<TObject>;
    FObvValue: Double;
    FObvBar: Integer;
  public
    Bars: TPineBarSet;
    BarIndex: Integer;
    Output: TPineOutput;
    constructor Create(ABars: TPineBarSet);
    destructor Destroy; override;
    function State(ASiteId: Integer): TCallState;
    function Series(const AName: string): TPineSeries;
    function HasSeries(const AName: string): Boolean;
    function Bar: TPineBar;
    function BarAt(AOffset: Integer): TPineBar;
    function IsLastBar: Boolean;
    { Typed input() overrides, keyed by the input's title. The JSON API uses
      this so a JSON bool/number/string reaches input.*() with its real
      type instead of being round-tripped through a text value. }
    procedure SetInputOverride(const AKey: string; const AValue: TPineValue);
    function TryInputOverride(const AKey: string; out AValue: TPineValue): Boolean;
    { Registers a newly created array/line/label object for ownership: it
      is freed when the context is destroyed, and never before, so a
      TPineValue holding a reference to it stays valid for the whole run.
      Returns AObj unchanged, so it can be used inline at the creation site. }
    function TrackRef(AObj: TObject): TObject;
    { on-balance volume: a single well-known series computed lazily and
      cached per bar, regardless of how many places in the script read the
      bare `obv` identifier on that bar. }
    function ObvValue: Double;
  end;

{ Parses a bar timestamp: a plain unix time (seconds) or a YYYY-MM-DD /
  YYYY/MM/DD date. Shared by the CSV loader and the JSON API. }
function ParseBarTime(const AText: string): Int64;

{ Breaks a unix timestamp (seconds, UTC) into calendar parts after shifting
  it by AOffsetMinutes. ADayOfWeek follows Pine's convention: 1 = Sunday
  ... 7 = Saturday. }
procedure DecodeBarTime(AUnixTime: Int64; AOffsetMinutes: Integer;
  out AYear, AMonth, ADay, AHour, AMinute, ADayOfWeek: Integer);

{ Parses a timezone string such as "UTC", "UTC+3", "UTC-05:30" or "GMT+2"
  into minutes east of UTC. Named zones ("America/New_York") can't be
  resolved without a timezone database, so they - and anything else
  unrecognized - resolve to 0, i.e. UTC. }
function ParseTimezoneOffsetMinutes(const ATimezone: string): Integer;

implementation

{$Q-}
{ Overflow checking is off for this whole unit: TPineBarSet.GenerateSynthetic
  below uses a Cardinal LCG whose wraparound is intentional. Nothing else in
  this unit relies on overflow checking being on. }

function ParseBarTime(const AText: string): Int64;
var
  LDate: TDateTime;
  LText: string;
  LValue: Int64;
begin
  LText := Trim(AText);
  if TryStrToInt64(LText, LValue) then
    Exit(LValue);
  LText := StringReplace(LText, '/', '-', [rfReplaceAll]);
  if TryEncodeDate(StrToIntDef(Copy(LText, 1, 4), 1970),
    StrToIntDef(Copy(LText, 6, 2), 1), StrToIntDef(Copy(LText, 9, 2), 1), LDate) then
    Result := DateTimeToUnix(LDate)
  else
    Result := 0;
end;

procedure DecodeBarTime(AUnixTime: Int64; AOffsetMinutes: Integer;
  out AYear, AMonth, ADay, AHour, AMinute, ADayOfWeek: Integer);
var
  LDateTime: TDateTime;
  LYear, LMonth, LDay, LHour, LMinute, LSecond, LMilli: Word;
begin
  LDateTime := UnixToDateTime(AUnixTime + Int64(AOffsetMinutes) * 60);
  DecodeDate(LDateTime, LYear, LMonth, LDay);
  DecodeTime(LDateTime, LHour, LMinute, LSecond, LMilli);
  AYear := LYear;
  AMonth := LMonth;
  ADay := LDay;
  AHour := LHour;
  AMinute := LMinute;
  ADayOfWeek := DayOfWeek(LDateTime); // 1 = Sunday ... 7 = Saturday, same as Pine
end;

function ParseTimezoneOffsetMinutes(const ATimezone: string): Integer;
var
  LText, LRest: string;
  LSign, LColon, LHours, LMinutes: Integer;
begin
  Result := 0;
  LText := UpperCase(Trim(ATimezone));
  if (Copy(LText, 1, 3) <> 'UTC') and (Copy(LText, 1, 3) <> 'GMT') then
    Exit; // a named zone: no timezone database here, treat as UTC
  LRest := Copy(LText, 4, MaxInt);
  if LRest = '' then
    Exit;
  if LRest[1] = '+' then
    LSign := 1
  else if LRest[1] = '-' then
    LSign := -1
  else
    Exit;
  LRest := Copy(LRest, 2, MaxInt);
  LColon := Pos(':', LRest);
  if LColon > 0 then
  begin
    LHours := StrToIntDef(Copy(LRest, 1, LColon - 1), 0);
    LMinutes := StrToIntDef(Copy(LRest, LColon + 1, MaxInt), 0);
  end
  else
  begin
    LHours := StrToIntDef(LRest, 0);
    LMinutes := 0;
  end;
  Result := LSign * (LHours * 60 + LMinutes);
end;

{ TPineBarSet }

function TPineBarSet.GetBar(AIndex: Integer): TPineBar;
begin
  if (AIndex < 0) or (AIndex >= FCount) then
  begin
    Result := Default (TPineBar);
    Result.Open := NaN;
    Result.High := NaN;
    Result.Low := NaN;
    Result.Close := NaN;
    Result.Volume := NaN;
  end
  else
    Result := FBars[AIndex];
end;

procedure TPineBarSet.Add(const ABar: TPineBar);
begin
  if FCount >= Length(FBars) then
    SetLength(FBars, Max(64, Length(FBars) * 2));
  FBars[FCount] := ABar;
  Inc(FCount);
end;

procedure TPineBarSet.LoadFromCSV(const AFileName: string);
var
  LLines: TStringList;
  LParts: TStringList;
  LBar: TPineBar;
  LLine: string;
  I: Integer;
  LFmt: TFormatSettings;

  function ParseFloat(const S: string): Double;
  begin
    if not TryStrToFloat(Trim(S), Result, LFmt) then
      Result := NaN;
  end;

begin
{$IFDEF FPC}
  LFmt := DefaultFormatSettings;
{$ELSE}
  LFmt := TFormatSettings.Create('en-US');
{$ENDIF}
  LFmt.DecimalSeparator := '.';
  FCount := 0;
  SetLength(FBars, 0);
  LLines := TStringList.Create;
  LParts := TStringList.Create;
  try
    LLines.LoadFromFile(AFileName);
    LParts.StrictDelimiter := True;
    LParts.Delimiter := ',';
    for I := 0 to LLines.Count - 1 do
    begin
      LLine := Trim(LLines[I]);
      if (LLine = '') or (LLine[1] = '#') then
        Continue;
      LParts.DelimitedText := LLine;
      if LParts.Count < 5 then
        Continue;
      // skip the header row
      if IsNan(ParseFloat(LParts[1])) then
        Continue;
      LBar.Time := ParseBarTime(LParts[0]);
      LBar.Open := ParseFloat(LParts[1]);
      LBar.High := ParseFloat(LParts[2]);
      LBar.Low := ParseFloat(LParts[3]);
      LBar.Close := ParseFloat(LParts[4]);
      if LParts.Count > 5 then
        LBar.Volume := ParseFloat(LParts[5])
      else
        LBar.Volume := 0;
      Add(LBar);
    end;
  finally
    LParts.Free;
    LLines.Free;
  end;
end;

procedure TPineBarSet.GenerateSynthetic(ACount, ASeed: Integer; AStartPrice: Double);
var
  I: Integer;
  LPrice, LOpen, LHigh, LLow, LClose, LStep: Double;
  LBar: TPineBar;
  LRand: Cardinal;

  (* This is a classic LCG and relies on Cardinal wraparound on purpose
    (see the {$Q-} directive at the top of this unit's implementation). *)
  function NextRandom: Double;
  begin
    LRand := LRand * 1103515245 + 12345;
    Result := ((LRand shr 16) and $7FFF) / $7FFF;
  end;

begin
  FCount := 0;
  SetLength(FBars, 0);
  LRand := Cardinal(ASeed);
  LPrice := AStartPrice;
  for I := 0 to ACount - 1 do
  begin
    LOpen := LPrice;
    LStep := (NextRandom - 0.48) * AStartPrice * 0.02;
    LClose := Max(0.01, LOpen + LStep);
    LHigh := Max(LOpen, LClose) + NextRandom * AStartPrice * 0.006;
    LLow := Min(LOpen, LClose) - NextRandom * AStartPrice * 0.006;
    LBar.Time := DateTimeToUnix(EncodeDate(2024, 1, 1)) + Int64(I) * 86400;
    LBar.Open := LOpen;
    LBar.High := LHigh;
    LBar.Low := Max(0.01, LLow);
    LBar.Close := LClose;
    LBar.Volume := 1000 + Round(NextRandom * 5000);
    Add(LBar);
    LPrice := LClose;
  end;
end;

{ TPinePlot }

constructor TPinePlot.Create;
begin
  inherited Create;
  FValues := TList<Double>.Create;
  FColors := TList<Cardinal>.Create;
  Width := 1;
  Color := $FF2196F3;
  Kind := ppkPlot;
end;

destructor TPinePlot.Destroy;
begin
  FValues.Free;
  FColors.Free;
  inherited Destroy;
end;

procedure TPinePlot.SetAt(ABar: Integer; AValue: Double; AColor: Cardinal);
begin
  while FValues.Count <= ABar do
  begin
    FValues.Add(NaN);
    FColors.Add(Color);
  end;
  FValues[ABar] := AValue;
  FColors[ABar] := AColor;
end;

function TPinePlot.GetCount: Integer;
begin
  Result := FValues.Count;
end;

function TPinePlot.ValueAt(ABar: Integer): Double;
begin
  if (ABar < 0) or (ABar >= FValues.Count) then
    Result := NaN
  else
    Result := FValues[ABar];
end;

function TPinePlot.ColorAt(ABar: Integer): Cardinal;
begin
  if (ABar < 0) or (ABar >= FColors.Count) then
    Result := Color
  else
    Result := FColors[ABar];
end;

{ TPineOutput }

constructor TPineOutput.Create;
begin
  inherited Create;
  FPlots := TObjectDictionary<Integer, TPinePlot>.Create([doOwnsValues]);
  FOrder := TList<Integer>.Create;
  Logs := TStringList.Create;
  Alerts := TStringList.Create;
  Lines := TList<TPineLineObj>.Create;
  Labels := TList<TPineLabelObj>.Create;
  Boxes := TList<TPineBoxObj>.Create;
  Tables := TList<TPineTableObj>.Create;
  Overlay := False;
end;

destructor TPineOutput.Destroy;
begin
  Tables.Free;
  Boxes.Free;
  Labels.Free;
  Lines.Free;
  Alerts.Free;
  Logs.Free;
  FOrder.Free;
  FPlots.Free;
  inherited Destroy;
end;

function TPineOutput.PlotForSite(ASiteId: Integer; AKind: TPinePlotKind): TPinePlot;
begin
  if not FPlots.TryGetValue(ASiteId, Result) then
  begin
    Result := TPinePlot.Create;
    Result.Kind := AKind;
    FPlots.Add(ASiteId, Result);
    FOrder.Add(ASiteId);
  end;
end;

function TPineOutput.GetPlot(AIndex: Integer): TPinePlot;
begin
  Result := FPlots[FOrder[AIndex]];
end;

function TPineOutput.GetPlotCount: Integer;
begin
  Result := FOrder.Count;
end;

procedure TPineOutput.SaveToCSV(const AFileName: string; ABars: TPineBarSet);
var
  LOut: TStringList;
  LLine: string;
  I, J: Integer;
  LPlot: TPinePlot;
begin
  LOut := TStringList.Create;
  try
    LLine := 'bar_index,time,open,high,low,close,volume';
    for J := 0 to PlotCount - 1 do
      LLine := LLine + ',' + StringReplace(Plots[J].Title, ',', ' ', [rfReplaceAll]);
    LOut.Add(LLine);
    for I := 0 to ABars.Count - 1 do
    begin
      LLine := Format('%d,%d,%s,%s,%s,%s,%s', [I, ABars[I].Time,
        FormatNumber(ABars[I].Open), FormatNumber(ABars[I].High),
        FormatNumber(ABars[I].Low), FormatNumber(ABars[I].Close),
        FormatNumber(ABars[I].Volume)]);
      for J := 0 to PlotCount - 1 do
      begin
        LPlot := Plots[J];
        if IsNan(LPlot.ValueAt(I)) then
          LLine := LLine + ','
        else
          LLine := LLine + ',' + FormatNumber(LPlot.ValueAt(I));
      end;
      LOut.Add(LLine);
    end;
    LOut.SaveToFile(AFileName);
  finally
    LOut.Free;
  end;
end;

{ TPineContext }

constructor TPineContext.Create(ABars: TPineBarSet);
begin
  inherited Create;
  Bars := ABars;
  FGlobals := TObjectDictionary<string, TPineSeries>.Create([doOwnsValues]);
  FStates := TObjectDictionary<Integer, TCallState>.Create([doOwnsValues]);
  FInputOverrides := TDictionary<string, TPineValue>.Create;
  FRefObjects := TObjectList<TObject>.Create(True);
  FObvBar := -1;
  Output := TPineOutput.Create;
  BarIndex := 0;
end;

destructor TPineContext.Destroy;
begin
  Output.Free;
  FRefObjects.Free;
  FInputOverrides.Free;
  FStates.Free;
  FGlobals.Free;
  inherited Destroy;
end;

function TPineContext.State(ASiteId: Integer): TCallState;
begin
  if not FStates.TryGetValue(ASiteId, Result) then
  begin
    Result := TCallState.Create;
    FStates.Add(ASiteId, Result);
  end;
end;

function TPineContext.Series(const AName: string): TPineSeries;
begin
  if not FGlobals.TryGetValue(AName, Result) then
  begin
    Result := TPineSeries.Create;
    FGlobals.Add(AName, Result);
  end;
end;

function TPineContext.HasSeries(const AName: string): Boolean;
begin
  Result := FGlobals.ContainsKey(AName);
end;

function TPineContext.Bar: TPineBar;
begin
  Result := Bars[BarIndex];
end;

function TPineContext.BarAt(AOffset: Integer): TPineBar;
begin
  Result := Bars[BarIndex - AOffset];
end;

function TPineContext.IsLastBar: Boolean;
begin
  Result := BarIndex = Bars.Count - 1;
end;

procedure TPineContext.SetInputOverride(const AKey: string; const AValue: TPineValue);
begin
  FInputOverrides.AddOrSetValue(AKey, AValue);
end;

function TPineContext.TryInputOverride(const AKey: string; out AValue: TPineValue): Boolean;
begin
  Result := FInputOverrides.TryGetValue(AKey, AValue);
end;

function TPineContext.TrackRef(AObj: TObject): TObject;
begin
  FRefObjects.Add(AObj);
  Result := AObj;
end;

function TPineContext.ObvValue: Double;
begin
  if FObvBar <> BarIndex then
  begin
    if BarIndex = 0 then
      FObvValue := 0
    else if Bar.Close > BarAt(1).Close then
      FObvValue := FObvValue + Bar.Volume
    else if Bar.Close < BarAt(1).Close then
      FObvValue := FObvValue - Bar.Volume;
    // an unchanged close leaves the running total as it was, same as Pine
    FObvBar := BarIndex;
  end;
  Result := FObvValue;
end;

end.
