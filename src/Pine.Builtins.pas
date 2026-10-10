unit Pine.Builtins;

{ Built-in variables and functions of Pine Script.

  Stateful indicators keep their memory in the TCallState object bound to the
  call site (SiteId), so two different ta.ema() calls never interfere with
  each other even when they use the same length. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, Pine.Types, Pine.Runtime;

{ Resolves a built-in constant or series such as close, hl2, bar_index,
  color.red, math.pi. Returns False when the name is unknown. }
function TryBuiltinValue(ACtx: TPineContext; const AName: string;
  out AValue: TPineValue): Boolean;

{ Resolves a built-in constant with a history offset, e.g. close[3]. }
function TryBuiltinHistory(ACtx: TPineContext; const AName: string; AOffset: Integer;
  out AValue: TPineValue): Boolean;

{ Executes a built-in function. AHandled is False when the name is not a
  built-in (the interpreter then looks for a user defined function). }
function CallBuiltin(ACtx: TPineContext; const AName: string; ASiteId: Integer;
  AArgs: TPineArgs; out AHandled: Boolean): TPineValue;

implementation

const
  // named colors, stored as ARGB
  CColorNames: array [0 .. 15] of string = ('red', 'green', 'blue', 'white',
    'black', 'orange', 'purple', 'yellow', 'gray', 'lime', 'aqua', 'fuchsia',
    'maroon', 'navy', 'olive', 'teal');
  CColorValues: array [0 .. 15] of Cardinal = ($FFF23645, $FF089981, $FF2196F3,
    $FFFFFFFF, $FF000000, $FFFF9800, $FF9C27B0, $FFFFEB3B, $FF787B86, $FF00E676,
    $FF00BCD4, $FFE040FB, $FF880E4F, $FF311B92, $FF808000, $FF00897B);

function LastSegment(const AName: string): string;
var
  P: Integer;
begin
  Result := AName;
  P := LastDelimiter('.', Result);
  if P > 0 then
    Result := Copy(Result, P + 1, Length(Result) - P);
end;

{ Whether a bar's own timestamp falls inside a Pine session spec such as
  "1300-2200" or "2100-0600:1234567" (day codes 1=Sunday..7=Saturday,
  matching Pine and DecodeBarTime), after converting the bar's UTC time
  into the given timezone. Handles sessions that cross midnight. An empty
  or malformed spec never matches, same as real Pine returning na. }
function IsBarInSession(AUnixTime: Int64; const ASessionSpec, ATimezone: string): Boolean;
var
  LSpec, LDays: string;
  LColonPos, LDashPos: Integer;
  LStartHHMM, LEndHHMM, LNowHHMM: Integer;
  LOffsetMinutes: Integer;
  LYear, LMonth, LDay, LHour, LMinute, LDow: Integer;
begin
  Result := False;
  LSpec := Trim(ASessionSpec);
  if LSpec = '' then
    Exit;
  LDays := '';
  LColonPos := Pos(':', LSpec);
  if LColonPos > 0 then
  begin
    LDays := Copy(LSpec, LColonPos + 1, MaxInt);
    LSpec := Copy(LSpec, 1, LColonPos - 1);
  end;
  LDashPos := Pos('-', LSpec);
  if LDashPos <= 0 then
    Exit;
  LStartHHMM := StrToIntDef(Trim(Copy(LSpec, 1, LDashPos - 1)), -1);
  LEndHHMM := StrToIntDef(Trim(Copy(LSpec, LDashPos + 1, MaxInt)), -1);
  if (LStartHHMM < 0) or (LEndHHMM < 0) then
    Exit;
  LOffsetMinutes := ParseTimezoneOffsetMinutes(ATimezone);
  DecodeBarTime(AUnixTime, LOffsetMinutes, LYear, LMonth, LDay, LHour, LMinute, LDow);
  LNowHHMM := LHour * 100 + LMinute;
  if LStartHHMM = LEndHHMM then
    Result := True // a zero-length range means "all day", like real Pine
  else if LStartHHMM < LEndHHMM then
    Result := (LNowHHMM >= LStartHHMM) and (LNowHHMM < LEndHHMM)
  else
    Result := (LNowHHMM >= LStartHHMM) or (LNowHHMM < LEndHHMM); // crosses midnight
  if Result and (LDays <> '') then
    Result := Pos(IntToStr(LDow), LDays) > 0;
end;

{ Formats a number the way Pine's format.volume does: a K/M/B/T suffix
  picked by magnitude, two decimal places, no suffix under 1000. }
function FormatVolumeNumber(AValue: Double): string;
var
  LAbs, LScaled: Double;
  LSuffix: string;
  LSign: string;
begin
  if IsNan(AValue) then
    Exit('NaN');
  LSign := '';
  if AValue < 0 then
    LSign := '-';
  LAbs := Abs(AValue);
  if LAbs >= 1.0E12 then
  begin
    LScaled := LAbs / 1.0E12;
    LSuffix := 'T';
  end
  else if LAbs >= 1.0E9 then
  begin
    LScaled := LAbs / 1.0E9;
    LSuffix := 'B';
  end
  else if LAbs >= 1.0E6 then
  begin
    LScaled := LAbs / 1.0E6;
    LSuffix := 'M';
  end
  else if LAbs >= 1.0E3 then
  begin
    LScaled := LAbs / 1.0E3;
    LSuffix := 'K';
  end
  else
  begin
    LScaled := LAbs;
    LSuffix := '';
  end;
  if LSuffix = '' then
    Result := LSign + FormatNumber(LScaled, 0)
  else
    Result := LSign + FormatNumber(LScaled, 2) + LSuffix;
end;

{ ---------------- helpers for stateful calculations ---------------- }

{ Simple moving average of the values pushed into buffer ABufIdx. }
function SmaStep(ASt: TCallState; ABufIdx, ABar: Integer; AValue: Double;
  ALen: Integer): Double;
var
  LBuf: TPineBuffer;
  I: Integer;
  LSum, LItem: Double;
begin
  LBuf := ASt.Buffer(ABufIdx);
  LBuf.Push(ABar, AValue);
  if (ALen <= 0) or (LBuf.Count < ALen) then
    Exit(NaN);
  LSum := 0;
  for I := 0 to ALen - 1 do
  begin
    LItem := LBuf.Get(I);
    if IsNan(LItem) then
      Exit(NaN);
    LSum := LSum + LItem;
  end;
  Result := LSum / ALen;
end;

{ Exponential moving average, seeded with the SMA of the first ALen values. }
function EmaStep(ASt: TCallState; ABufIdx, ASlot, ABar: Integer; AValue: Double;
  ALen: Integer): Double;
var
  LSeed, LAlpha: Double;
begin
  LSeed := SmaStep(ASt, ABufIdx, ABar, AValue, ALen);
  if not ASt.Flags[ASlot] then
  begin
    if IsNan(LSeed) then
      Exit(NaN);
    ASt.Flags[ASlot] := True;
    ASt.Nums[ASlot] := LSeed;
    Exit(LSeed);
  end;
  if IsNan(AValue) then
    Exit(ASt.Nums[ASlot]);
  LAlpha := 2 / (ALen + 1);
  ASt.Nums[ASlot] := LAlpha * AValue + (1 - LAlpha) * ASt.Nums[ASlot];
  Result := ASt.Nums[ASlot];
end;

{ Wilder's smoothing (used by RSI and ATR). }
function RmaStep(ASt: TCallState; ABufIdx, ASlot, ABar: Integer; AValue: Double;
  ALen: Integer): Double;
var
  LSeed: Double;
begin
  LSeed := SmaStep(ASt, ABufIdx, ABar, AValue, ALen);
  if not ASt.Flags[ASlot] then
  begin
    if IsNan(LSeed) then
      Exit(NaN);
    ASt.Flags[ASlot] := True;
    ASt.Nums[ASlot] := LSeed;
    Exit(LSeed);
  end;
  if IsNan(AValue) then
    Exit(ASt.Nums[ASlot]);
  ASt.Nums[ASlot] := (ASt.Nums[ASlot] * (ALen - 1) + AValue) / ALen;
  Result := ASt.Nums[ASlot];
end;

function WmaStep(ASt: TCallState; ABufIdx, ABar: Integer; AValue: Double;
  ALen: Integer): Double;
var
  LBuf: TPineBuffer;
  I: Integer;
  LSum, LWeightSum, LItem: Double;
begin
  LBuf := ASt.Buffer(ABufIdx);
  LBuf.Push(ABar, AValue);
  if (ALen <= 0) or (LBuf.Count < ALen) then
    Exit(NaN);
  LSum := 0;
  LWeightSum := 0;
  for I := 0 to ALen - 1 do
  begin
    LItem := LBuf.Get(I);
    if IsNan(LItem) then
      Exit(NaN);
    LSum := LSum + LItem * (ALen - I);
    LWeightSum := LWeightSum + (ALen - I);
  end;
  Result := LSum / LWeightSum;
end;

function StdevStep(ASt: TCallState; ABufIdx, ABar: Integer; AValue: Double;
  ALen: Integer): Double;
var
  LBuf: TPineBuffer;
  I: Integer;
  LMean, LSum, LItem: Double;
begin
  LBuf := ASt.Buffer(ABufIdx);
  LBuf.Push(ABar, AValue);
  if (ALen <= 1) or (LBuf.Count < ALen) then
    Exit(NaN);
  LMean := 0;
  for I := 0 to ALen - 1 do
  begin
    LItem := LBuf.Get(I);
    if IsNan(LItem) then
      Exit(NaN);
    LMean := LMean + LItem;
  end;
  LMean := LMean / ALen;
  LSum := 0;
  for I := 0 to ALen - 1 do
    LSum := LSum + Sqr(LBuf.Get(I) - LMean);
  Result := Sqrt(LSum / ALen); // population standard deviation, like Pine
end;

{ Mean absolute deviation: average of |x - mean(x)| over the window. This is
  what Pine's own ta.dev()/cci() use - it is NOT the same as standard
  deviation (StdevStep above), which several bars' worth of scripts rely on
  for exact CCI values. }
function MeanDevStep(ASt: TCallState; ABufIdx, ABar: Integer; AValue: Double;
  ALen: Integer): Double;
var
  LBuf: TPineBuffer;
  I: Integer;
  LMean, LSum, LItem: Double;
begin
  LBuf := ASt.Buffer(ABufIdx);
  LBuf.Push(ABar, AValue);
  if (ALen <= 0) or (LBuf.Count < ALen) then
    Exit(NaN);
  LMean := 0;
  for I := 0 to ALen - 1 do
  begin
    LItem := LBuf.Get(I);
    if IsNan(LItem) then
      Exit(NaN);
    LMean := LMean + LItem;
  end;
  LMean := LMean / ALen;
  LSum := 0;
  for I := 0 to ALen - 1 do
    LSum := LSum + Abs(LBuf.Get(I) - LMean);
  Result := LSum / ALen;
end;

function HighestStep(ASt: TCallState; ABufIdx, ABar: Integer; AValue: Double;
  ALen: Integer): Double;
var
  LBuf: TPineBuffer;
  I: Integer;
  LItem: Double;
begin
  LBuf := ASt.Buffer(ABufIdx);
  LBuf.Push(ABar, AValue);
  if (ALen <= 0) or (LBuf.Count < ALen) then
    Exit(NaN);
  Result := -MaxDouble;
  for I := 0 to ALen - 1 do
  begin
    LItem := LBuf.Get(I);
    if IsNan(LItem) then
      Exit(NaN);
    if LItem > Result then
      Result := LItem;
  end;
end;

function LowestStep(ASt: TCallState; ABufIdx, ABar: Integer; AValue: Double;
  ALen: Integer): Double;
var
  LBuf: TPineBuffer;
  I: Integer;
  LItem: Double;
begin
  LBuf := ASt.Buffer(ABufIdx);
  LBuf.Push(ABar, AValue);
  if (ALen <= 0) or (LBuf.Count < ALen) then
    Exit(NaN);
  Result := MaxDouble;
  for I := 0 to ALen - 1 do
  begin
    LItem := LBuf.Get(I);
    if IsNan(LItem) then
      Exit(NaN);
    if LItem < Result then
      Result := LItem;
  end;
end;

{ True range of the current bar. }
function TrueRange(ACtx: TPineContext; AHandleNA: Boolean): Double;
var
  LBar, LPrev: TPineBar;
begin
  LBar := ACtx.Bar;
  if ACtx.BarIndex = 0 then
  begin
    if AHandleNA then
      Exit(LBar.High - LBar.Low)
    else
      Exit(NaN);
  end;
  LPrev := ACtx.BarAt(1);
  Result := Max(LBar.High - LBar.Low,
    Max(Abs(LBar.High - LPrev.Close), Abs(LBar.Low - LPrev.Close)));
end;

{ ---------------- built-in constants ---------------- }

function TryBuiltinHistory(ACtx: TPineContext; const AName: string; AOffset: Integer;
  out AValue: TPineValue): Boolean;
var
  LBar: TPineBar;
  LName: string;
begin
  Result := True;
  LName := LowerCase(AName);
  LBar := ACtx.BarAt(AOffset);
  if LName = 'open' then
    AValue := PineFloat(LBar.Open)
  else if LName = 'high' then
    AValue := PineFloat(LBar.High)
  else if LName = 'low' then
    AValue := PineFloat(LBar.Low)
  else if LName = 'close' then
    AValue := PineFloat(LBar.Close)
  else if LName = 'volume' then
    AValue := PineFloat(LBar.Volume)
  else if LName = 'hl2' then
    AValue := PineFloat((LBar.High + LBar.Low) / 2)
  else if LName = 'hlc3' then
    AValue := PineFloat((LBar.High + LBar.Low + LBar.Close) / 3)
  else if LName = 'ohlc4' then
    AValue := PineFloat((LBar.Open + LBar.High + LBar.Low + LBar.Close) / 4)
  else if LName = 'time' then
    AValue := PineInt(LBar.Time)
  else if LName = 'bar_index' then
  begin
    if ACtx.BarIndex - AOffset < 0 then
      AValue := PineNA
    else
      AValue := PineInt(ACtx.BarIndex - AOffset);
  end
  else
    Result := False;
end;

function TryBuiltinValue(ACtx: TPineContext; const AName: string;
  out AValue: TPineValue): Boolean;
var
  LName, LSeg: string;
  I: Integer;
  LYear, LMonth, LDay, LHour, LMinute, LDow: Integer;
begin
  if TryBuiltinHistory(ACtx, AName, 0, AValue) then
    Exit(True);
  Result := True;
  LName := LowerCase(AName);
  if LName = 'na' then
    AValue := PineNA
  else if LName = 'last_bar_index' then
    AValue := PineInt(ACtx.Bars.Count - 1)
  else if LName = 'math.pi' then
    AValue := PineFloat(Pi)
  else if LName = 'math.e' then
    AValue := PineFloat(Exp(1))
  else if LName = 'math.phi' then
    AValue := PineFloat((1 + Sqrt(5)) / 2)
  else if LName = 'barstate.isfirst' then
    AValue := PineBool(ACtx.BarIndex = 0)
  else if LName = 'barstate.islast' then
    AValue := PineBool(ACtx.IsLastBar)
  else if (LName = 'barstate.isnew') or (LName = 'barstate.isconfirmed') then
    AValue := PineBool(True)
  else if LName = 'barstate.isrealtime' then
    AValue := PineBool(False)
  else if LName = 'barstate.ishistory' then
    AValue := PineBool(True)
  else if Copy(LName, 1, 6) = 'color.' then
  begin
    LSeg := LastSegment(LName);
    Result := False;
    for I := Low(CColorNames) to High(CColorNames) do
      if CColorNames[I] = LSeg then
      begin
        AValue := PineColorValue(CColorValues[I]);
        Exit(True);
      end;
    if LSeg = 'silver' then
    begin
      AValue := PineColorValue($FFC0C0C0);
      Exit(True);
    end;
  end
  else if (LName = 'plot.style_line') or (LName = 'plot.style_histogram') or
    (LName = 'plot.style_columns') or (LName = 'plot.style_circles') or
    (LName = 'plot.style_stepline') or (LName = 'plot.style_area') then
    AValue := PineString(LastSegment(LName))
  else if (LName = 'location.abovebar') or (LName = 'location.belowbar') or
    (LName = 'location.absolute') or (LName = 'location.top') or
    (LName = 'location.bottom') then
    AValue := PineString(LastSegment(LName))
  else if (LName = 'alert.freq_once_per_bar') or
    (LName = 'alert.freq_once_per_bar_close') or (LName = 'alert.freq_all') then
    AValue := PineString(LastSegment(LName))
  else if (LName = 'line.style_solid') or (LName = 'line.style_dashed') or
    (LName = 'line.style_dotted') or (LName = 'line.style_arrow_left') or
    (LName = 'line.style_arrow_right') or (LName = 'line.style_arrow_both') then
    AValue := PineString(Copy(LastSegment(LName), 7, MaxInt)) // strip the "style_" prefix
  else if (LName = 'label.style_label_down') or (LName = 'label.style_label_up') or
    (LName = 'label.style_label_left') or (LName = 'label.style_label_right') or
    (LName = 'label.style_label_center') or (LName = 'label.style_circle') or
    (LName = 'label.style_cross') or (LName = 'label.style_none') then
    AValue := PineString(LastSegment(LName))
  else if (LName = 'shape.labeldown') or (LName = 'shape.labelup') or
    (LName = 'shape.xcross') or (LName = 'shape.cross') or (LName = 'shape.circle') or
    (LName = 'shape.triangleup') or (LName = 'shape.triangledown') or
    (LName = 'shape.flag') or (LName = 'shape.arrowup') or (LName = 'shape.arrowdown') or
    (LName = 'shape.square') or (LName = 'shape.diamond') then
    AValue := PineString(LastSegment(LName))
  else if LName = 'obv' then
    AValue := PineFloat(ACtx.ObvValue)
  else if LName = 'dayofweek' then
  begin
    // 1 = Sunday .. 7 = Saturday, same convention DecodeBarTime returns
    DecodeBarTime(ACtx.Bar.Time, 0, LYear, LMonth, LDay, LHour, LMinute, LDow);
    AValue := PineInt(LDow);
  end
  else if (LName = 'dayofweek.sunday') or (LName = 'dayofweek.monday') or
    (LName = 'dayofweek.tuesday') or (LName = 'dayofweek.wednesday') or
    (LName = 'dayofweek.thursday') or (LName = 'dayofweek.friday') or
    (LName = 'dayofweek.saturday') then
  begin
    LSeg := LastSegment(LName);
    if LSeg = 'sunday' then AValue := PineInt(1)
    else if LSeg = 'monday' then AValue := PineInt(2)
    else if LSeg = 'tuesday' then AValue := PineInt(3)
    else if LSeg = 'wednesday' then AValue := PineInt(4)
    else if LSeg = 'thursday' then AValue := PineInt(5)
    else if LSeg = 'friday' then AValue := PineInt(6)
    else AValue := PineInt(7); // saturday
  end
  else if (LName = 'text.align_right') or (LName = 'text.align_left') or
    (LName = 'text.align_center') or (LName = 'text.align_top') or
    (LName = 'text.align_bottom') or (LName = 'text.wrap_auto') or
    (LName = 'text.wrap_none') or (LName = 'text.format_none') or
    (LName = 'text.format_bold') or (LName = 'text.format_italic') then
    AValue := PineString(Copy(LastSegment(LName), Pos('_', LastSegment(LName)) + 1, MaxInt))
  else if LName = 'format.volume' then
    AValue := PineString('volume')
  else if (LName = 'format.price') or (LName = 'format.mintick') or
    (LName = 'format.percent') then
    AValue := PineString(LastSegment(LName))
  else if LName = 'xloc.bar_time' then
    AValue := PineString('bar_time')
  else if LName = 'xloc.bar_index' then
    AValue := PineString('bar_index')
  else if (LName = 'extend.both') or (LName = 'extend.left') or
    (LName = 'extend.right') or (LName = 'extend.none') then
    AValue := PineString(LastSegment(LName))
  else if (LName = 'display.all') or (LName = 'display.none') or
    (LName = 'display.pane') or (LName = 'display.data_window') or
    (LName = 'display.status_line') or (LName = 'display.price_scale') then
  begin
    // real bit-flag values, so scripts that combine them with +/- (e.g.
    // "display.all - display.status_line") get a sensible number back;
    // this interpreter never renders anything, so the exact bits are moot
    if LName = 'display.none' then AValue := PineInt(0)
    else if LName = 'display.pane' then AValue := PineInt(1)
    else if LName = 'display.data_window' then AValue := PineInt(2)
    else if LName = 'display.price_scale' then AValue := PineInt(4)
    else if LName = 'display.status_line' then AValue := PineInt(8)
    else AValue := PineInt(15); // display.all
  end
  else if (LName = 'size.auto') or (LName = 'size.tiny') or (LName = 'size.small') or
    (LName = 'size.normal') or (LName = 'size.large') or (LName = 'size.huge') then
    AValue := PineString(LastSegment(LName))
  else if (LName = 'position.top_right') or (LName = 'position.top_left') or
    (LName = 'position.top_center') or (LName = 'position.bottom_right') or
    (LName = 'position.bottom_left') or (LName = 'position.bottom_center') or
    (LName = 'position.middle_right') or (LName = 'position.middle_left') or
    (LName = 'position.middle_center') then
    AValue := PineString(LastSegment(LName))
  else if LName = 'syminfo.ticker' then
    AValue := PineString('SYMBOL')
  else if LName = 'syminfo.timezone' then
    AValue := PineString('UTC')
  else if LName = 'syminfo.mintick' then
    AValue := PineFloat(0.01)
  else if LName = 'timeframe.period' then
    AValue := PineString('D')
  else
    Result := False;
end;

{ ---------------- function dispatch ---------------- }

function CallBuiltin(ACtx: TPineContext; const AName: string; ASiteId: Integer;
  AArgs: TPineArgs; out AHandled: Boolean): TPineValue;
var
  LName, LFunc, LKey, LTitle: string;
  LSt: TCallState;
  LBar: Integer;
  LPlot: TPinePlot;
  A, B, C, D, LTmp: Double;
  I, LLen, LFast, LSlow, LSignal: Integer;
  LMacd, LSig, LMid, LDev: Double;
  LValue: TPineValue;
  LOverride: TPineValue;
  LColor: Cardinal;
  LArrObj: TPineArrayObj;
  LLineObj: TPineLineObj;
  LLabelObj: TPineLabelObj;
  LBoxObj: TPineBoxObj;
  LTableObj: TPineTableObj;
  LArrType: string;
  LArrSize, LIdx, LFrom, LTo: Integer;
  LDefaultItem: TPineValue;
  LFoundBool: Boolean;
  LLeftBars, LRightBars: Integer;
  LPivotSrc, LPivotVal: Double;
  LIsPivot: Boolean;

  function ArgNum(AIndex: Integer; const AArgName: string; const ADefault: Double): Double;
  begin
    Result := AArgs.Num(AIndex, AArgName, ADefault);
  end;

  function ArgColor(AIndex: Integer; const AArgName: string; ADefault: Cardinal): Cardinal;
  var
    LArg: TPineValue;
  begin
    LArg := AArgs.Get(AIndex, AArgName);
    if LArg.Kind = pvkColor then
      Result := Cardinal(Trunc(LArg.Num))
    else
      Result := ADefault;
  end;

  function ExpectArray(const AValue: TPineValue; const AWhere: string): TPineArrayObj;
  begin
    if (AValue.Kind <> pvkRef) or not(AValue.Ref is TPineArrayObj) then
      raise EPineRuntimeError.CreateFmt('%s expects an array', [AWhere]);
    Result := TPineArrayObj(AValue.Ref);
  end;

  function ValuesEqual(const X, Y: TPineValue): Boolean;
  begin
    if X.IsNA or Y.IsNA then
      Exit(X.IsNA and Y.IsNA);
    if (X.Kind = pvkString) or (Y.Kind = pvkString) then
      Exit(X.AsString = Y.AsString);
    Result := SameValue(X.AsFloat, Y.AsFloat);
  end;

begin
  AHandled := True;
  Result := PineNA;
  LName := LowerCase(AName);
  LSt := ACtx.State(ASiteId);
  LBar := ACtx.BarIndex;

  { ----- declaration statements ----- }
  if (LName = 'indicator') or (LName = 'study') or (LName = 'strategy') then
  begin
    ACtx.Output.Title := AArgs.Str(0, 'title', 'Untitled');
    ACtx.Output.ShortTitle := AArgs.Str(1, 'shorttitle', ACtx.Output.Title);
    ACtx.Output.Overlay := AArgs.Bool(-1, 'overlay', False);
    ACtx.Output.IsStrategy := LName = 'strategy';
    Exit(PineNA);
  end;

  { ----- input.* ----- }
  if (LName = 'input') or (Copy(LName, 1, 6) = 'input.') then
  begin
    LValue := AArgs.Get(0, 'defval');
    LTitle := AArgs.Str(1, 'title', '');
    if LTitle = '' then
      LKey := 'input' + IntToStr(ASiteId)
    else
      LKey := LTitle;
    if ACtx.TryInputOverride(LKey, LOverride) then
    begin
      // the override already carries the right Pine type (from JSON),
      // so it is used as-is except for a couple of int/float coercions
      if (LName = 'input.int') and (LOverride.Kind <> pvkInt) then
        Result := PineInt(LOverride.AsInt)
      else if (LName = 'input.float') and (LOverride.Kind <> pvkFloat) then
        Result := PineFloat(LOverride.AsFloat)
      else
        Result := LOverride;
    end
    else
      Result := LValue;
    Exit;
  end;

  { ----- color.* ----- }
  if LName = 'color.new' then
  begin
    LColor := ArgColor(0, 'color', $FF2196F3);
    A := ArgNum(1, 'transp', 0);
    if IsNan(A) then
      A := 0;
    LColor := (LColor and $00FFFFFF) or (Cardinal(Round(255 * (100 - A) / 100)) shl 24);
    Exit(PineColorValue(LColor));
  end;
  if LName = 'color.rgb' then
  begin
    LColor := (Cardinal(Round(ArgNum(3, 'transp', 100))) shl 24) or
      (Cardinal(Round(ArgNum(0, 'red', 0))) shl 16) or
      (Cardinal(Round(ArgNum(1, 'green', 0))) shl 8) or
      Cardinal(Round(ArgNum(2, 'blue', 0)));
    Exit(PineColorValue(LColor or $FF000000));
  end;

  { ----- str.* ----- }
  if Copy(LName, 1, 4) = 'str.' then
  begin
    LFunc := LastSegment(LName);
    if LFunc = 'tostring' then
    begin
      LValue := AArgs.Get(0, 'value');
      if AArgs.Has(1, 'format') and LValue.IsNumeric then
      begin
        LKey := AArgs.Str(1, 'format', '#.##');
        if SameText(LKey, 'volume') then
          Exit(PineString(FormatVolumeNumber(LValue.AsFloat)));
        Exit(PineString(FormatNumber(LValue.AsFloat, Max(0, Length(LKey) - 2))));
      end;
      Exit(PineString(LValue.AsString));
    end;
    if LFunc = 'tonumber' then
    begin
      if TryStrToFloat(AArgs.Str(0, 'string', ''), A) then
        Exit(PineFloat(A))
      else
        Exit(PineNA);
    end;
    if LFunc = 'length' then
      Exit(PineInt(Length(AArgs.Str(0, 'string', ''))));
    if LFunc = 'upper' then
      Exit(PineString(UpperCase(AArgs.Str(0, 'string', ''))));
    if LFunc = 'lower' then
      Exit(PineString(LowerCase(AArgs.Str(0, 'string', ''))));
    if LFunc = 'contains' then
      Exit(PineBool(Pos(AArgs.Str(1, 'substring', ''), AArgs.Str(0, 'source', '')) > 0));
    if LFunc = 'format' then
    begin
      LKey := AArgs.Str(0, 'formatString', '');
      for I := 1 to AArgs.Count - 1 do
        LKey := StringReplace(LKey, '{' + IntToStr(I - 1) + '}',
          AArgs.Get(I, '').AsString, [rfReplaceAll]);
      Exit(PineString(LKey));
    end;
  end;

  { v3/v4 scripts often call tostring(x) without the str. prefix. }
  if LName = 'tostring' then
  begin
    LValue := AArgs.Get(0, 'value');
    if AArgs.Has(1, '') and LValue.IsNumeric then
    begin
      LKey := AArgs.Get(1, '').AsString;
      if SameText(LKey, 'volume') then
        Exit(PineString(FormatVolumeNumber(LValue.AsFloat)));
      Exit(PineString(FormatNumber(LValue.AsFloat, Max(0, Length(LKey) - 2))));
    end;
    Exit(PineString(LValue.AsString));
  end;

  { ----- len() -----
    Pine itself has no built-in named "len" (the closest thing is
    str.length()); this is added as a plain-string-length convenience so
    that scripts calling len(x) work instead of failing with "unknown
    function". If a script actually means array/collection length, arrays
    are not implemented yet - see the README. }
  if LName = 'len' then
    Exit(PineInt(Length(AArgs.Get(0, 'x').AsString)));

  { ----- log.* / alert ----- }
  if (Copy(LName, 1, 4) = 'log.') or (LName = 'alert') then
  begin
    LKey := AArgs.Get(0, 'message').AsString;
    if LName = 'alert' then
      ACtx.Output.Alerts.Add(Format('bar %d: %s', [LBar, LKey]))
    else
      ACtx.Output.Logs.Add(Format('bar %d [%s]: %s', [LBar, LastSegment(LName), LKey]));
    Exit(PineNA);
  end;

  { alertcondition(condition, title=, message=) - declarative form of
    alert(): logs an alert whenever the condition is true on a bar. }
  if LName = 'alertcondition' then
  begin
    if AArgs.Get(0, 'condition').AsBool then
      ACtx.Output.Alerts.Add(Format('bar %d: %s', [LBar,
        AArgs.Str(2, 'message', AArgs.Str(1, 'title', ''))]));
    Exit(PineNA);
  end;

  { ----- array.* -----
    Elements are stored as plain TPineValue regardless of the array's
    declared element type. The array object itself is a heap reference
    (see TPineArrayObj) owned by the context, so array.set/push/pop and
    friends mutate the SAME array everywhere it is referenced, matching
    Pine's by-reference array semantics. }
  if Copy(LName, 1, 10) = 'array.new_' then
  begin
    LArrType := Copy(LName, 11, MaxInt);
    LArrSize := AArgs.Int(0, 'size', 0);
    if LArrType = 'int' then
      LDefaultItem := PineInt(AArgs.Int(1, 'initial_value', 0))
    else if LArrType = 'float' then
      LDefaultItem := PineFloat(AArgs.Num(1, 'initial_value', 0))
    else if LArrType = 'bool' then
      LDefaultItem := PineBool(AArgs.Bool(1, 'initial_value', False))
    else if LArrType = 'string' then
      LDefaultItem := PineString(AArgs.Str(1, 'initial_value', ''))
    else if LArrType = 'color' then
    begin
      if AArgs.Has(1, 'initial_value') then
        LDefaultItem := PineColorValue(ArgColor(1, 'initial_value', $FF000000))
      else
        LDefaultItem := PineNA;
    end
    else
      LDefaultItem := PineNA; // line / label / matrix elements start as na
    LArrObj := TPineArrayObj.Create;
    ACtx.TrackRef(LArrObj);
    for I := 1 to LArrSize do
      LArrObj.Items.Add(LDefaultItem);
    Exit(PineRef(LArrObj));
  end;
  if LName = 'array.get' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.get');
    LIdx := AArgs.Int(1, 'index', 0);
    if (LIdx < 0) or (LIdx >= LArrObj.Items.Count) then
      raise EPineRuntimeError.CreateFmt('array.get: index %d out of bounds (size %d)',
        [LIdx, LArrObj.Items.Count]);
    Exit(LArrObj.Items[LIdx]);
  end;
  if LName = 'array.set' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.set');
    LIdx := AArgs.Int(1, 'index', 0);
    if (LIdx < 0) or (LIdx >= LArrObj.Items.Count) then
      raise EPineRuntimeError.CreateFmt('array.set: index %d out of bounds (size %d)',
        [LIdx, LArrObj.Items.Count]);
    LArrObj.Items[LIdx] := AArgs.Get(2, 'value');
    Exit(PineNA);
  end;
  if LName = 'array.push' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.push');
    LArrObj.Items.Add(AArgs.Get(1, 'value'));
    Exit(PineNA);
  end;
  if LName = 'array.pop' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.pop');
    if LArrObj.Items.Count = 0 then
      raise EPineRuntimeError.Create('array.pop: array is empty');
    Result := LArrObj.Items[LArrObj.Items.Count - 1];
    LArrObj.Items.Delete(LArrObj.Items.Count - 1);
    Exit(Result);
  end;
  if LName = 'array.shift' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.shift');
    if LArrObj.Items.Count = 0 then
      raise EPineRuntimeError.Create('array.shift: array is empty');
    Result := LArrObj.Items[0];
    LArrObj.Items.Delete(0);
    Exit(Result);
  end;
  if LName = 'array.unshift' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.unshift');
    LArrObj.Items.Insert(0, AArgs.Get(1, 'value'));
    Exit(PineNA);
  end;
  if LName = 'array.size' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.size');
    Exit(PineInt(LArrObj.Items.Count));
  end;
  if LName = 'array.clear' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.clear');
    LArrObj.Items.Clear;
    Exit(PineNA);
  end;
  if LName = 'array.fill' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.fill');
    LValue := AArgs.Get(1, 'value');
    LFrom := AArgs.Int(2, 'index_from', 0);
    LTo := AArgs.Int(3, 'index_to', LArrObj.Items.Count);
    for I := Max(0, LFrom) to Min(LArrObj.Items.Count, LTo) - 1 do
      LArrObj.Items[I] := LValue;
    Exit(PineNA);
  end;
  if LName = 'array.includes' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.includes');
    LValue := AArgs.Get(1, 'value');
    LFoundBool := False;
    for I := 0 to LArrObj.Items.Count - 1 do
      if ValuesEqual(LArrObj.Items[I], LValue) then
      begin
        LFoundBool := True;
        Break;
      end;
    Exit(PineBool(LFoundBool));
  end;
  if LName = 'array.indexof' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.indexof');
    LValue := AArgs.Get(1, 'value');
    Result := PineInt(-1);
    for I := 0 to LArrObj.Items.Count - 1 do
      if ValuesEqual(LArrObj.Items[I], LValue) then
      begin
        Result := PineInt(I);
        Break;
      end;
    Exit(Result);
  end;
  if LName = 'array.remove' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.remove');
    LIdx := AArgs.Int(1, 'index', 0);
    if (LIdx < 0) or (LIdx >= LArrObj.Items.Count) then
      raise EPineRuntimeError.Create('array.remove: index out of bounds');
    Result := LArrObj.Items[LIdx];
    LArrObj.Items.Delete(LIdx);
    Exit(Result);
  end;
  if LName = 'array.insert' then
  begin
    LArrObj := ExpectArray(AArgs.Get(0, 'id'), 'array.insert');
    LIdx := Max(0, Min(AArgs.Int(1, 'index', 0), LArrObj.Items.Count));
    LArrObj.Items.Insert(LIdx, AArgs.Get(2, 'value'));
    Exit(PineNA);
  end;

  { ----- line.* / label.* -----
    No chart to draw on, so these are pure bookkeeping objects: enough for
    scripts that create, reposition, and delete lines/labels to run
    without crashing, even though nothing is actually rendered. }
  if LName = 'line.new' then
  begin
    LLineObj := TPineLineObj.Create;
    ACtx.TrackRef(LLineObj);
    ACtx.Output.Lines.Add(LLineObj);
    LLineObj.X1 := AArgs.Num(0, 'x1', 0);
    LLineObj.Y1 := AArgs.Num(1, 'y1', 0);
    LLineObj.X2 := AArgs.Num(2, 'x2', 0);
    LLineObj.Y2 := AArgs.Num(3, 'y2', 0);
    LLineObj.LineColor := ArgColor(-1, 'color', $FF787B86);
    LLineObj.Style := AArgs.Str(-1, 'style', 'solid');
    LLineObj.Width := AArgs.Int(-1, 'width', 1);
    Exit(PineRef(LLineObj));
  end;
  if LName = 'line.delete' then
  begin
    LValue := AArgs.Get(0, 'id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineLineObj) then
      TPineLineObj(LValue.Ref).Deleted := True;
    Exit(PineNA);
  end;
  if (LName = 'line.set_xy1') or (LName = 'line.set_xy2') or (LName = 'line.set_color') or
    (LName = 'line.set_x1') or (LName = 'line.set_y1') or (LName = 'line.set_x2') or
    (LName = 'line.set_y2') or (LName = 'line.set_width') or (LName = 'line.set_style') then
  begin
    LValue := AArgs.Get(0, 'id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineLineObj) then
    begin
      LLineObj := TPineLineObj(LValue.Ref);
      if LName = 'line.set_xy1' then
      begin
        LLineObj.X1 := AArgs.Num(1, 'x', LLineObj.X1);
        LLineObj.Y1 := AArgs.Num(2, 'y', LLineObj.Y1);
      end
      else if LName = 'line.set_xy2' then
      begin
        LLineObj.X2 := AArgs.Num(1, 'x', LLineObj.X2);
        LLineObj.Y2 := AArgs.Num(2, 'y', LLineObj.Y2);
      end
      else if LName = 'line.set_x1' then
        LLineObj.X1 := AArgs.Num(1, 'x', LLineObj.X1)
      else if LName = 'line.set_y1' then
        LLineObj.Y1 := AArgs.Num(1, 'y', LLineObj.Y1)
      else if LName = 'line.set_x2' then
        LLineObj.X2 := AArgs.Num(1, 'x', LLineObj.X2)
      else if LName = 'line.set_y2' then
        LLineObj.Y2 := AArgs.Num(1, 'y', LLineObj.Y2)
      else if LName = 'line.set_width' then
        LLineObj.Width := AArgs.Int(1, 'width', LLineObj.Width)
      else if LName = 'line.set_style' then
        LLineObj.Style := AArgs.Str(1, 'style', LLineObj.Style)
      else
        LLineObj.LineColor := ArgColor(1, 'color', LLineObj.LineColor);
    end;
    Exit(PineNA);
  end;
  if LName = 'label.new' then
  begin
    LLabelObj := TPineLabelObj.Create;
    ACtx.TrackRef(LLabelObj);
    ACtx.Output.Labels.Add(LLabelObj);
    LLabelObj.X := AArgs.Num(0, 'x', 0);
    LLabelObj.Y := AArgs.Num(1, 'y', 0);
    LLabelObj.Text := AArgs.Str(2, 'text', '');
    LLabelObj.LabelColor := ArgColor(-1, 'color', $FF787B86);
    LLabelObj.TextColor := ArgColor(-1, 'textcolor', $FFFFFFFF);
    LLabelObj.Style := AArgs.Str(-1, 'style', 'label_down');
    Exit(PineRef(LLabelObj));
  end;
  if LName = 'label.delete' then
  begin
    LValue := AArgs.Get(0, 'id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineLabelObj) then
      TPineLabelObj(LValue.Ref).Deleted := True;
    Exit(PineNA);
  end;
  if (LName = 'label.set_text') or (LName = 'label.set_xy') then
  begin
    LValue := AArgs.Get(0, 'id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineLabelObj) then
    begin
      LLabelObj := TPineLabelObj(LValue.Ref);
      if LName = 'label.set_text' then
        LLabelObj.Text := AArgs.Str(1, 'text', LLabelObj.Text)
      else
      begin
        LLabelObj.X := AArgs.Num(1, 'x', LLabelObj.X);
        LLabelObj.Y := AArgs.Num(2, 'y', LLabelObj.Y);
      end;
    end;
    Exit(PineNA);
  end;

  { ----- box.* -----
    Same bookkeeping-only approach as line/label: no chart to draw on, but
    creation/mutation/deletion all behave correctly and are reported in
    the JSON response. }
  if LName = 'box.new' then
  begin
    LBoxObj := TPineBoxObj.Create;
    ACtx.TrackRef(LBoxObj);
    ACtx.Output.Boxes.Add(LBoxObj);
    LBoxObj.Left := AArgs.Num(0, 'left', 0);
    LBoxObj.Top := AArgs.Num(1, 'top', 0);
    LBoxObj.Right := AArgs.Num(2, 'right', 0);
    LBoxObj.Bottom := AArgs.Num(3, 'bottom', 0);
    LBoxObj.BgColor := ArgColor(-1, 'bgcolor', $FF000000);
    LBoxObj.BorderColor := ArgColor(-1, 'border_color', $FF787B86);
    LBoxObj.BorderStyle := AArgs.Str(-1, 'border_style', 'solid');
    LBoxObj.BorderWidth := AArgs.Int(-1, 'border_width', 1);
    Exit(PineRef(LBoxObj));
  end;
  if LName = 'box.delete' then
  begin
    LValue := AArgs.Get(0, 'id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineBoxObj) then
      TPineBoxObj(LValue.Ref).Deleted := True;
    Exit(PineNA);
  end;
  if (LName = 'box.set_top') or (LName = 'box.set_bottom') or (LName = 'box.set_left') or
    (LName = 'box.set_right') or (LName = 'box.set_lefttop') or
    (LName = 'box.set_rightbottom') or (LName = 'box.set_bgcolor') or
    (LName = 'box.set_border_color') then
  begin
    LValue := AArgs.Get(0, 'id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineBoxObj) then
    begin
      LBoxObj := TPineBoxObj(LValue.Ref);
      if LName = 'box.set_top' then
        LBoxObj.Top := AArgs.Num(1, 'top', LBoxObj.Top)
      else if LName = 'box.set_bottom' then
        LBoxObj.Bottom := AArgs.Num(1, 'bottom', LBoxObj.Bottom)
      else if LName = 'box.set_left' then
        LBoxObj.Left := AArgs.Num(1, 'left', LBoxObj.Left)
      else if LName = 'box.set_right' then
        LBoxObj.Right := AArgs.Num(1, 'right', LBoxObj.Right)
      else if LName = 'box.set_lefttop' then
      begin
        LBoxObj.Left := AArgs.Num(1, 'left', LBoxObj.Left);
        LBoxObj.Top := AArgs.Num(2, 'top', LBoxObj.Top);
      end
      else if LName = 'box.set_rightbottom' then
      begin
        LBoxObj.Right := AArgs.Num(1, 'right', LBoxObj.Right);
        LBoxObj.Bottom := AArgs.Num(2, 'bottom', LBoxObj.Bottom);
      end
      else if LName = 'box.set_bgcolor' then
        LBoxObj.BgColor := ArgColor(1, 'color', LBoxObj.BgColor)
      else
        LBoxObj.BorderColor := ArgColor(1, 'color', LBoxObj.BorderColor);
    end;
    Exit(PineNA);
  end;

  { ----- table.* -----
    A sparse grid of cells (see TPineTableObj). Reported in the JSON
    response as its final cell contents - there is no chart to draw it on. }
  if LName = 'table.new' then
  begin
    LTableObj := TPineTableObj.Create;
    ACtx.TrackRef(LTableObj);
    ACtx.Output.Tables.Add(LTableObj);
    LTableObj.Position := AArgs.Str(0, 'position', 'top_right');
    LTableObj.Columns := AArgs.Int(1, 'columns', 1);
    LTableObj.Rows := AArgs.Int(2, 'rows', 1);
    Exit(PineRef(LTableObj));
  end;
  if LName = 'table.delete' then
  begin
    LValue := AArgs.Get(0, 'id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineTableObj) then
      TPineTableObj(LValue.Ref).Deleted := True;
    Exit(PineNA);
  end;
  if LName = 'table.cell' then
  begin
    LValue := AArgs.Get(0, 'table_id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineTableObj) then
      TPineTableObj(LValue.Ref).SetCell(AArgs.Int(1, 'column', 0),
        AArgs.Int(2, 'row', 0), AArgs.Str(3, 'text', ''),
        ArgColor(-1, 'text_color', $FF000000), ArgColor(-1, 'bgcolor', $FF000000),
        AArgs.Str(-1, 'text_halign', 'center'), AArgs.Num(-1, 'height', 0));
    Exit(PineNA);
  end;
  if LName = 'table.cell_set_text' then
  begin
    LValue := AArgs.Get(0, 'table_id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineTableObj) then
    begin
      LTableObj := TPineTableObj(LValue.Ref);
      LIdx := LTableObj.FindCell(AArgs.Int(1, 'column', 0), AArgs.Int(2, 'row', 0));
      if LIdx >= 0 then
        LTableObj.SetCell(AArgs.Int(1, 'column', 0), AArgs.Int(2, 'row', 0),
          AArgs.Str(3, 'text', ''), LTableObj.Cells[LIdx].TextColor,
          LTableObj.Cells[LIdx].BgColor, LTableObj.Cells[LIdx].Alignment,
          LTableObj.Cells[LIdx].Height);
    end;
    Exit(PineNA);
  end;
  if LName = 'table.merge_cells' then
  begin
    LValue := AArgs.Get(0, 'table_id');
    if (LValue.Kind = pvkRef) and (LValue.Ref is TPineTableObj) then
      TPineTableObj(LValue.Ref).MergeCells(AArgs.Int(1, 'start_column', 0),
        AArgs.Int(2, 'start_row', 0), AArgs.Int(3, 'end_column', 0),
        AArgs.Int(4, 'end_row', 0));
    Exit(PineNA);
  end;

  { ----- time(): session detection -----
    time(timeframe, session, timezone) returns the bar's own timestamp
    when it falls inside the given session (see IsBarInSession), or na
    otherwise. This interpreter only ever runs on the chart's own already-
    loaded bars (no multi-timeframe access), so the timeframe argument is
    accepted but not otherwise used. }
  if LName = 'time' then
  begin
    if IsBarInSession(ACtx.Bar.Time, AArgs.Str(1, 'session', ''),
      AArgs.Str(2, 'timezone', '')) then
      Exit(PineInt(ACtx.Bar.Time))
    else
      Exit(PineNA);
  end;

  { ----- plotting ----- }
  if LName = 'plot' then
  begin
    LPlot := ACtx.Output.PlotForSite(ASiteId, ppkPlot);
    if LPlot.Title = '' then
    begin
      LPlot.Title := AArgs.Str(1, 'title', 'plot' + IntToStr(ACtx.Output.PlotCount));
      LPlot.Color := ArgColor(-1, 'color', $FF2196F3);
      LPlot.Width := AArgs.Int(-1, 'linewidth', 1);
    end;
    LPlot.SetAt(LBar, AArgs.Get(0, 'series').AsFloat,
      ArgColor(-1, 'color', LPlot.Color));
    Exit(PineNA);
  end;
  if LName = 'hline' then
  begin
    LPlot := ACtx.Output.PlotForSite(ASiteId, ppkHLine);
    if LPlot.Title = '' then
    begin
      LPlot.Title := AArgs.Str(1, 'title', 'hline');
      LPlot.Color := ArgColor(-1, 'color', $FF787B86);
    end;
    LPlot.SetAt(LBar, ArgNum(0, 'price', NaN), LPlot.Color);
    Exit(PineNA);
  end;
  if LName = 'bgcolor' then
  begin
    LPlot := ACtx.Output.PlotForSite(ASiteId, ppkBgColor);
    if LPlot.Title = '' then
      LPlot.Title := AArgs.Str(-1, 'title', 'bgcolor');
    LColor := ArgColor(0, 'color', 0);
    LPlot.SetAt(LBar, LColor, LColor);
    Exit(PineNA);
  end;
  if (LName = 'plotshape') or (LName = 'plotchar') or (LName = 'plotarrow') then
  begin
    LPlot := ACtx.Output.PlotForSite(ASiteId, ppkPlot);
    if LPlot.Title = '' then
      LPlot.Title := AArgs.Str(-1, 'title', LName);
    if AArgs.Get(0, 'series').AsBool then
      LPlot.SetAt(LBar, 1, ArgColor(-1, 'color', $FF089981))
    else
      LPlot.SetAt(LBar, NaN, LPlot.Color);
    Exit(PineNA);
  end;
  if LName = 'fill' then
    Exit(PineNA); // not supported, ignored on purpose

  { ----- generic helpers ----- }
  LFunc := LastSegment(LName);

  if LFunc = 'na' then
    Exit(PineBool(AArgs.Get(0, 'x').IsNA));
  if LFunc = 'nz' then
  begin
    LValue := AArgs.Get(0, 'x');
    if LValue.IsNA then
    begin
      if AArgs.Has(1, 'y') then
        Exit(AArgs.Get(1, 'y'))
      else
        Exit(PineFloat(0));
    end;
    Exit(LValue);
  end;
  if LFunc = 'fixnan' then
  begin
    LValue := AArgs.Get(0, 'x');
    if LValue.IsNA then
      Exit(PineFloat(LSt.Nums[0]));
    LSt.Nums[0] := LValue.AsFloat;
    Exit(LValue);
  end;

  { ----- math.* and casts ----- }
  A := ArgNum(0, 'x', NaN);
  // ta.* functions name their first argument "source"
  if IsNan(A) and AArgs.Has(-1, 'source') then
    A := AArgs.Num(-1, 'source', NaN);
  if LFunc = 'abs' then
    Exit(PineFloat(Abs(A)));
  if LFunc = 'sqrt' then
    Exit(PineFloat(Sqrt(Max(0.0, A))));
  if LFunc = 'exp' then
    Exit(PineFloat(Exp(A)));
  if LFunc = 'log' then
    Exit(PineFloat(Ln(A)));
  if LFunc = 'log10' then
    Exit(PineFloat(Log10(A)));
  if LFunc = 'sign' then
    Exit(PineFloat(Sign(A)));
  if LFunc = 'floor' then
    Exit(PineFloat(Floor(A)));
  if LFunc = 'ceil' then
    Exit(PineFloat(Ceil(A)));
  if LFunc = 'sin' then
    Exit(PineFloat(Sin(A)));
  if LFunc = 'cos' then
    Exit(PineFloat(Cos(A)));
  if LFunc = 'tan' then
    Exit(PineFloat(Tan(A)));
  if LFunc = 'round' then
  begin
    I := AArgs.Int(1, 'precision', 0);
    if IsNan(A) then
      Exit(PineNA);
    if I <= 0 then
      Exit(PineFloat(Round(A)))
    else
      Exit(PineFloat(Round(A * IntPower(10, I)) / IntPower(10, I)));
  end;
  if LFunc = 'pow' then
    Exit(PineFloat(Power(A, ArgNum(1, 'y', 0))));
  if LFunc = 'max' then
  begin
    LTmp := -MaxDouble;
    for I := 0 to AArgs.Count - 1 do
    begin
      B := AArgs.Get(I, '').AsFloat;
      if not IsNan(B) then
        LTmp := Max(LTmp, B);
    end;
    if LTmp = -MaxDouble then
      Exit(PineNA);
    Exit(PineFloat(LTmp));
  end;
  if LFunc = 'min' then
  begin
    LTmp := MaxDouble;
    for I := 0 to AArgs.Count - 1 do
    begin
      B := AArgs.Get(I, '').AsFloat;
      if not IsNan(B) then
        LTmp := Min(LTmp, B);
    end;
    if LTmp = MaxDouble then
      Exit(PineNA);
    Exit(PineFloat(LTmp));
  end;
  if LFunc = 'avg' then
  begin
    LTmp := 0;
    I := 0;
    for I := 0 to AArgs.Count - 1 do
      LTmp := LTmp + AArgs.Get(I, '').AsFloat;
    if AArgs.Count = 0 then
      Exit(PineNA);
    Exit(PineFloat(LTmp / AArgs.Count));
  end;
  if (LName = 'int') or (LName = 'math.toint') then
  begin
    if IsNan(A) then
      Exit(PineNA);
    Exit(PineInt(Trunc(A)));
  end;
  if LName = 'float' then
    Exit(PineFloat(A));
  if LName = 'bool' then
    Exit(PineBool(AArgs.Get(0, 'x').AsBool));
  if LName = 'string' then
    Exit(PineString(AArgs.Get(0, 'x').AsString));

  { ----- ta.* ----- }
  LLen := AArgs.Int(1, 'length', 14);

  if LFunc = 'sma' then
    Exit(PineFloat(SmaStep(LSt, 0, LBar, A, LLen)));
  if LFunc = 'ema' then
    Exit(PineFloat(EmaStep(LSt, 0, 0, LBar, A, LLen)));
  if LFunc = 'rma' then
    Exit(PineFloat(RmaStep(LSt, 0, 0, LBar, A, LLen)));
  if LFunc = 'wma' then
    Exit(PineFloat(WmaStep(LSt, 0, LBar, A, LLen)));
  if (LFunc = 'stdev') or (LFunc = 'dev') then
    Exit(PineFloat(StdevStep(LSt, 0, LBar, A, LLen)));
  if LFunc = 'variance' then
  begin
    B := StdevStep(LSt, 0, LBar, A, LLen);
    Exit(PineFloat(B * B));
  end;
  if LFunc = 'highest' then
  begin
    if AArgs.Count = 1 then
    begin
      LLen := AArgs.Int(0, 'length', 14);
      A := ACtx.Bar.High;
    end;
    Exit(PineFloat(HighestStep(LSt, 0, LBar, A, LLen)));
  end;
  if LFunc = 'lowest' then
  begin
    if AArgs.Count = 1 then
    begin
      LLen := AArgs.Int(0, 'length', 14);
      A := ACtx.Bar.Low;
    end;
    Exit(PineFloat(LowestStep(LSt, 0, LBar, A, LLen)));
  end;
  if (LFunc = 'change') or (LFunc = 'mom') then
  begin
    LLen := AArgs.Int(1, 'length', 1);
    LSt.Buffer(0).Push(LBar, A);
    B := LSt.Buffer(0).Get(LLen);
    Exit(PineFloat(A - B));
  end;
  if LFunc = 'roc' then
  begin
    LLen := AArgs.Int(1, 'length', 1);
    LSt.Buffer(0).Push(LBar, A);
    B := LSt.Buffer(0).Get(LLen);
    if IsNan(B) or (B = 0) then
      Exit(PineNA);
    Exit(PineFloat(100 * (A - B) / B));
  end;
  if LFunc = 'cum' then
  begin
    if not LSt.Flags[0] then
    begin
      LSt.Flags[0] := True;
      LSt.Nums[0] := 0;
    end;
    if not IsNan(A) then
      LSt.Nums[0] := LSt.Nums[0] + A;
    Exit(PineFloat(LSt.Nums[0]));
  end;
  if LFunc = 'sum' then
  begin
    LSt.Buffer(0).Push(LBar, A);
    if LSt.Buffer(0).Count < LLen then
      Exit(PineNA);
    LTmp := 0;
    for I := 0 to LLen - 1 do
      LTmp := LTmp + LSt.Buffer(0).Get(I);
    Exit(PineFloat(LTmp));
  end;
  if LFunc = 'tr' then
    Exit(PineFloat(TrueRange(ACtx, AArgs.Bool(0, 'handle_na', True))));
  if LFunc = 'atr' then
  begin
    LLen := AArgs.Int(0, 'length', 14);
    Exit(PineFloat(RmaStep(LSt, 0, 0, LBar, TrueRange(ACtx, True), LLen)));
  end;
  if LFunc = 'rsi' then
  begin
    LLen := AArgs.Int(1, 'length', 14);
    LSt.Buffer(3).Push(LBar, A);
    B := LSt.Buffer(3).Get(1);
    if IsNan(B) then
      C := NaN
    else
      C := A - B;
    if IsNan(C) then
      Exit(PineNA);
    B := RmaStep(LSt, 0, 0, LBar, Max(C, 0.0), LLen);
    D := RmaStep(LSt, 1, 1, LBar, Max(-C, 0.0), LLen);
    if IsNan(B) or IsNan(D) then
      Exit(PineNA);
    if D = 0 then
      Exit(PineFloat(100));
    if B = 0 then
      Exit(PineFloat(0));
    Exit(PineFloat(100 - 100 / (1 + B / D)));
  end;
  if (LFunc = 'crossover') or (LFunc = 'crossunder') or (LFunc = 'cross') then
  begin
    B := ArgNum(1, 'source2', NaN);
    LSt.Buffer(0).Push(LBar, A);
    LSt.Buffer(1).Push(LBar, B);
    C := LSt.Buffer(0).Get(1);
    D := LSt.Buffer(1).Get(1);
    if IsNan(A) or IsNan(B) or IsNan(C) or IsNan(D) then
      Exit(PineBool(False));
    if LFunc = 'crossover' then
      Exit(PineBool((C <= D) and (A > B)));
    if LFunc = 'crossunder' then
      Exit(PineBool((C >= D) and (A < B)));
    Exit(PineBool(((C <= D) and (A > B)) or ((C >= D) and (A < B))));
  end;
  if LFunc = 'barssince' then
  begin
    if AArgs.Get(0, 'condition').AsBool then
      LSt.Ints[0] := 0
    else if LSt.Flags[0] then
      Inc(LSt.Ints[0])
    else
      Exit(PineNA);
    LSt.Flags[0] := True;
    Exit(PineInt(LSt.Ints[0]));
  end;
  if (LFunc = 'rising') or (LFunc = 'falling') then
  begin
    LSt.Buffer(0).Push(LBar, A);
    if LSt.Buffer(0).Count < LLen + 1 then
      Exit(PineBool(False));
    for I := 0 to LLen - 1 do
    begin
      C := LSt.Buffer(0).Get(I);
      D := LSt.Buffer(0).Get(I + 1);
      if IsNan(C) or IsNan(D) then
        Exit(PineBool(False));
      if (LFunc = 'rising') and (C <= D) then
        Exit(PineBool(False));
      if (LFunc = 'falling') and (C >= D) then
        Exit(PineBool(False));
    end;
    Exit(PineBool(True));
  end;
  if LFunc = 'macd' then
  begin
    LFast := AArgs.Int(1, 'fastlen', 12);
    LSlow := AArgs.Int(2, 'slowlen', 26);
    LSignal := AArgs.Int(3, 'siglen', 9);
    B := EmaStep(LSt, 0, 0, LBar, A, LFast);
    C := EmaStep(LSt, 1, 1, LBar, A, LSlow);
    if IsNan(B) or IsNan(C) then
      Exit(PineTuple([PineNA, PineNA, PineNA]));
    LMacd := B - C;
    LSig := EmaStep(LSt, 2, 2, LBar, LMacd, LSignal);
    if IsNan(LSig) then
      Exit(PineTuple([PineFloat(LMacd), PineNA, PineNA]));
    Exit(PineTuple([PineFloat(LMacd), PineFloat(LSig), PineFloat(LMacd - LSig)]));
  end;
  if LFunc = 'bb' then
  begin
    LLen := AArgs.Int(1, 'length', 20);
    D := ArgNum(2, 'mult', 2);
    LMid := SmaStep(LSt, 0, LBar, A, LLen);
    LDev := StdevStep(LSt, 1, LBar, A, LLen) * D;
    if IsNan(LMid) or IsNan(LDev) then
      Exit(PineTuple([PineNA, PineNA, PineNA]));
    Exit(PineTuple([PineFloat(LMid), PineFloat(LMid + LDev), PineFloat(LMid - LDev)]));
  end;
  if LFunc = 'stoch' then
  begin
    // ta.stoch(source, high, low, length)
    B := ArgNum(1, 'high', ACtx.Bar.High);
    C := ArgNum(2, 'low', ACtx.Bar.Low);
    LLen := AArgs.Int(3, 'length', 14);
    D := HighestStep(LSt, 0, LBar, B, LLen);
    LTmp := LowestStep(LSt, 1, LBar, C, LLen);
    if IsNan(D) or IsNan(LTmp) or (D = LTmp) then
      Exit(PineNA);
    Exit(PineFloat(100 * (A - LTmp) / (D - LTmp)));
  end;
  if LFunc = 'vwma' then
  begin
    B := ACtx.Bar.Volume;
    C := SmaStep(LSt, 0, LBar, A * B, LLen);
    D := SmaStep(LSt, 1, LBar, B, LLen);
    if IsNan(C) or IsNan(D) or (D = 0) then
      Exit(PineNA);
    Exit(PineFloat(C / D));
  end;
  if LFunc = 'cci' then
  begin
    // ta.cci(source, length): distance from the mean, scaled by mean
    // absolute deviation - NOT standard deviation (see MeanDevStep).
    LLen := AArgs.Int(1, 'length', 20);
    B := SmaStep(LSt, 0, LBar, A, LLen);
    C := MeanDevStep(LSt, 1, LBar, A, LLen);
    if IsNan(B) or IsNan(C) or (C = 0) then
      Exit(PineNA);
    Exit(PineFloat((A - B) / (0.015 * C)));
  end;
  if LFunc = 'mfi' then
  begin
    // ta.mfi(source, length): the "source" stands in for the typical
    // price, exactly like real Pine's mfi() built-in.
    LLen := AArgs.Int(1, 'length', 14);
    LSt.Buffer(2).Push(LBar, A);
    B := LSt.Buffer(2).Get(1); // previous bar's source value
    if IsNan(B) or (A > B) then
      LTmp := A * ACtx.Bar.Volume
    else
      LTmp := 0;
    C := SmaStep(LSt, 0, LBar, LTmp, LLen); // positive money flow
    if IsNan(B) or (A < B) then
      LTmp := A * ACtx.Bar.Volume
    else
      LTmp := 0;
    D := SmaStep(LSt, 1, LBar, LTmp, LLen); // negative money flow
    if IsNan(C) or IsNan(D) then
      Exit(PineNA);
    if D = 0 then
      Exit(PineFloat(100));
    Exit(PineFloat(100 - 100 / (1 + C / D)));
  end;
  if (LFunc = 'pivothigh') or (LFunc = 'pivotlow') then
  begin
    // pivothigh([source], leftbars, rightbars) - a pivot LEFTBARS+RIGHTBARS
    // wide is only knowable RIGHTBARS bars after it happened, which is
    // exactly how far back this looks: no real look-ahead is needed since
    // every bar involved has already elapsed by the time the pivot is
    // reported.
    if AArgs.Count >= 3 then
    begin
      LPivotSrc := ArgNum(0, 'source', NaN);
      LLeftBars := AArgs.Int(1, 'leftbars', 0);
      LRightBars := AArgs.Int(2, 'rightbars', 0);
    end
    else
    begin
      if LFunc = 'pivothigh' then
        LPivotSrc := ACtx.Bar.High
      else
        LPivotSrc := ACtx.Bar.Low;
      LLeftBars := AArgs.Int(0, 'leftbars', 0);
      LRightBars := AArgs.Int(1, 'rightbars', 0);
    end;
    LSt.Buffer(0).Push(LBar, LPivotSrc);
    if LSt.Buffer(0).Count < LLeftBars + LRightBars + 1 then
      Exit(PineNA);
    LPivotVal := LSt.Buffer(0).Get(LRightBars);
    LIsPivot := True;
    for I := 0 to LLeftBars + LRightBars do
    begin
      C := LSt.Buffer(0).Get(I);
      if IsNan(C) then
      begin
        LIsPivot := False;
        Break;
      end;
      if I = LRightBars then
        Continue;
      if (LFunc = 'pivothigh') and (C > LPivotVal) then
      begin
        LIsPivot := False;
        Break;
      end;
      if (LFunc = 'pivotlow') and (C < LPivotVal) then
      begin
        LIsPivot := False;
        Break;
      end;
    end;
    if LIsPivot then
      Exit(PineFloat(LPivotVal))
    else
      Exit(PineNA);
  end;
  if LFunc = 'valuewhen' then
  begin
    if AArgs.Get(0, 'condition').AsBool then
      LSt.Nums[0] := ArgNum(1, 'source', NaN);
    Exit(PineFloat(LSt.Nums[0]));
  end;

  AHandled := False;
end;

end.
