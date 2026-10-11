unit Pine.Types;

{ Core data types of the Pine Script interpreter:
  - TPineValue  : dynamically typed value (na / bool / int / float / string / color / tuple)
  - TPineSeries : full history of a named variable, indexed by bar
  - TPineBuffer : rolling history buffer used by built-in functions (ta.*)
  - TCallState  : persistent per-call-site state (needed by stateful indicators)
  - TPineArgs   : positional + named argument list of a function call }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Math, Generics.Collections;

type
  { Base class of every error the interpreter raises on purpose. Line is the
    1-based line of the script that caused it, or 0 when it isn't known
    (yet): the lexer/parser put the line in the message, and the
    interpreter stamps Line on runtime errors as they unwind through the
    statement/call that was executing - see TPineInterpreter.ExecStatement. }
  EPineError = class(Exception)
  public
    Line: Integer;
  end;
  EPineSyntaxError = class(EPineError);
  EPineRuntimeError = class(EPineError);

  TPineValueKind = (pvkNA, pvkBool, pvkInt, pvkFloat, pvkString, pvkColor, pvkTuple, pvkRef);

  { Dynamically typed value used everywhere inside the interpreter.
    pvkRef is a reference to a heap object owned by the TPineContext that
    created it (an array, a line, or a label - see TPineArrayObj /
    TPineLineObj / TPineLabelObj below); copying a TPineValue copies the
    reference, not the object, which is exactly Pine's by-reference
    semantics for these types. Ref = nil for a pvkRef value means na. }
  TPineValue = record
    Kind: TPineValueKind;
    Num: Double;          // numeric payload, also used for colors (ARGB)
    Str: string;          // string payload
    Items: TArray<TPineValue>; // tuple payload
    Ref: TObject;          // array/line/label payload
    { Name of the global variable or built-in bar-data field (close, high,
      rsi, macd, ...) this value was last read from, or '' if it isn't tied
      to one (e.g. it's the result of arithmetic). Copied along with the
      value through local-variable reads, function-parameter passing, and
      ternaries, so that a LOCAL bound to a series - e.g. a function
      parameter such as `src` in `f(src) => ... src[1] ...` - can still
      resolve history indexing by re-consulting the ORIGINAL series,
      exactly like Pine's own "series" parameters do. Cleared to '' by any
      arithmetic or function-call result. See TPineInterpreter.EvalHistory. }
    SeriesTag: string;
    function IsNA: Boolean;
    function IsNumeric: Boolean;
    function AsFloat: Double;   // NaN when the value is na
    function AsInt: Integer;
    function AsBool: Boolean;
    function AsString: string;
    function KindName: string;
  end;

  { A Pine array (array.new_int/float/string/bool/color/line/label and the
    [a, b, c] literal syntax). Elements are stored generically as
    TPineValue regardless of the array's declared element type, since the
    interpreter is dynamically typed throughout. Owned by the TPineContext
    that created it (see TPineContext.TrackRef) - never freed by hand. }
  TPineArrayObj = class
  public
    Items: TList<TPineValue>;
    constructor Create;
    destructor Destroy; override;
  end;

  { A line.new(...) object. Purely bookkeeping - this interpreter has no
    chart to draw on, so the fields are kept only so scripts that create,
    reposition, and delete lines run without crashing. }
  TPineLineObj = class
  public
    X1, Y1, X2, Y2: Double;
    LineColor: Cardinal;
    Style: string;
    Width: Integer;
    Deleted: Boolean;
  end;

  { A label.new(...) object - see TPineLineObj. }
  TPineLabelObj = class
  public
    X, Y: Double;
    Text: string;
    LabelColor: Cardinal;
    TextColor: Cardinal;
    Style: string;
    Deleted: Boolean;
  end;

  { A box.new(...) object - see TPineLineObj. Left/Right are bar indexes
    (or times, depending on xloc), Top/Bottom are prices. }
  TPineBoxObj = class
  public
    Left, Top, Right, Bottom: Double;
    BgColor: Cardinal;      // 0 = no fill
    BorderColor: Cardinal;
    BorderStyle: string;
    BorderWidth: Integer;
    Deleted: Boolean;
  end;

  { One cell of a table.new(...) grid. Colors of 0 mean "not set" (na). }
  TPineTableCell = record
    Col, Row: Integer;
    Text: string;
    TextColor: Cardinal;
    BgColor: Cardinal;
    Alignment: string;
    Height: Double;
    MergeToCol, MergeToRow: Integer; // far corner of a merged area, else = Col/Row
  end;

  { A table.new(...) object: a sparse grid of cells. Bookkeeping only, like
    lines/labels/boxes - it is reported in the JSON response, never drawn. }
  TPineTableObj = class
  public
    Position: string;
    Columns, Rows: Integer;
    Cells: TList<TPineTableCell>;
    Deleted: Boolean;
    constructor Create;
    destructor Destroy; override;
    { index of the cell at (ACol, ARow), or -1 }
    function FindCell(ACol, ARow: Integer): Integer;
    { creates the cell if it doesn't exist yet; updates it otherwise,
      leaving any merge info from merge_cells() intact }
    procedure SetCell(ACol, ARow: Integer; const AText: string;
      ATextColor, ABgColor: Cardinal; const AAlignment: string; AHeight: Double);
    procedure MergeCells(AStartCol, AStartRow, AEndCol, AEndRow: Integer);
  end;

  { History of one variable. Index 0 is the first bar of the data set. }
  TPineSeries = class
  private
    FValues: TArray<TPineValue>;
    FCount: Integer;
    procedure EnsureCapacity(ACount: Integer);
  public
    procedure SetAt(ABar: Integer; const AValue: TPineValue);
    function GetAt(ABar: Integer): TPineValue;
    { Value ABarsBack bars before ACurrentBar; na when out of range. }
    function History(ACurrentBar, ABarsBack: Integer): TPineValue;
    property Count: Integer read FCount;
  end;

  { Rolling buffer of plain doubles (NaN means na). One value per bar. }
  TPineBuffer = class
  private
    FItems: TList<Double>;
    FLastBar: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { Stores AValue for bar ABar. Calling it twice for the same bar
      overwrites the value instead of appending a new one. }
    procedure Push(ABar: Integer; AValue: Double);
    { Get(0) is the most recent value, Get(1) the previous one, ... }
    function Get(AOffset: Integer): Double;
    function Count: Integer;
  end;

  { Generic state bag attached to a single call site in the source code.
    Stateful built-ins (ema, rma, rsi, barssince, ...) keep their memory here. }
  TCallState = class
  private
    FBuffers: TObjectList<TPineBuffer>;
  public
    Nums: array [0 .. 15] of Double;
    Ints: array [0 .. 15] of Integer;
    Flags: array [0 .. 15] of Boolean;
    Obj: TObject; // optional payload (owned by the creator, not freed here)
    constructor Create;
    destructor Destroy; override;
    function Buffer(AIndex: Integer): TPineBuffer;
  end;

  { Evaluated arguments of a function call. }
  TPineArgs = class
  private
    FValues: TArray<TPineValue>;
    FNames: TArray<string>;
  public
    procedure Add(const AName: string; const AValue: TPineValue);
    function Count: Integer;
    function Has(AIndex: Integer; const AName: string): Boolean;
    function Get(AIndex: Integer; const AName: string): TPineValue;
    function Num(AIndex: Integer; const AName: string; const ADefault: Double): Double;
    function Int(AIndex: Integer; const AName: string; ADefault: Integer): Integer;
    function Bool(AIndex: Integer; const AName: string; ADefault: Boolean): Boolean;
    function Str(AIndex: Integer; const AName, ADefault: string): string;
    property Values: TArray<TPineValue> read FValues;
    property Names: TArray<string> read FNames;
  end;

function PineNA: TPineValue;
function PineFloat(const AValue: Double): TPineValue;
function PineInt(const AValue: Int64): TPineValue;
function PineBool(const AValue: Boolean): TPineValue;
function PineString(const AValue: string): TPineValue;
function PineColorValue(const AValue: Cardinal): TPineValue;
function PineTuple(const AItems: array of TPineValue): TPineValue;
function PineRef(AObj: TObject): TPineValue;

function ColorToHex(AColor: Cardinal): string;
function FormatNumber(const AValue: Double; APrecision: Integer = 6): string;

implementation

var
  GFormat: TFormatSettings;

function PineNA: TPineValue;
begin
  Result := Default (TPineValue);
  Result.Kind := pvkNA;
  Result.Num := NaN;
end;

function PineFloat(const AValue: Double): TPineValue;
begin
  Result := Default (TPineValue);
  if IsNan(AValue) then
  begin
    Result.Kind := pvkNA;
    Result.Num := NaN;
  end
  else
  begin
    Result.Kind := pvkFloat;
    Result.Num := AValue;
  end;
end;

function PineInt(const AValue: Int64): TPineValue;
begin
  Result := Default (TPineValue);
  Result.Kind := pvkInt;
  Result.Num := AValue;
end;

function PineBool(const AValue: Boolean): TPineValue;
begin
  Result := Default (TPineValue);
  Result.Kind := pvkBool;
  if AValue then
    Result.Num := 1
  else
    Result.Num := 0;
end;

function PineString(const AValue: string): TPineValue;
begin
  Result := Default (TPineValue);
  Result.Kind := pvkString;
  Result.Str := AValue;
end;

function PineColorValue(const AValue: Cardinal): TPineValue;
begin
  Result := Default (TPineValue);
  Result.Kind := pvkColor;
  Result.Num := AValue;
end;

function PineTuple(const AItems: array of TPineValue): TPineValue;
var
  I: Integer;
begin
  Result := Default (TPineValue);
  Result.Kind := pvkTuple;
  SetLength(Result.Items, Length(AItems));
  for I := 0 to High(AItems) do
    Result.Items[I] := AItems[I];
end;

function PineRef(AObj: TObject): TPineValue;
begin
  Result := Default (TPineValue);
  Result.Kind := pvkRef;
  Result.Ref := AObj;
end;

function ColorToHex(AColor: Cardinal): string;
begin
  Result := '#' + IntToHex(AColor and $00FFFFFF, 6);
  if (AColor shr 24) <> $FF then
    Result := Result + IntToHex(AColor shr 24, 2);
end;

function FormatNumber(const AValue: Double; APrecision: Integer): string;
var
  LMask: string;
begin
  if IsNan(AValue) then
    Exit('NaN');
  if APrecision <= 0 then
    LMask := '0'
  else
    LMask := '0.' + StringOfChar('#', APrecision);
  Result := FormatFloat(LMask, AValue, GFormat);
end;

function ArrayRefToString(AArr: TPineArrayObj): string;
var
  I: Integer;
begin
  Result := '[';
  for I := 0 to AArr.Items.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ', ';
    Result := Result + AArr.Items[I].AsString;
  end;
  Result := Result + ']';
end;

{ TPineValue }

function TPineValue.IsNA: Boolean;
begin
  Result := (Kind = pvkNA) or ((Kind in [pvkInt, pvkFloat]) and IsNan(Num)) or
    ((Kind = pvkRef) and (Ref = nil));
end;

function TPineValue.IsNumeric: Boolean;
begin
  Result := Kind in [pvkInt, pvkFloat, pvkBool];
end;

function TPineValue.AsFloat: Double;
begin
  case Kind of
    pvkInt, pvkFloat, pvkBool, pvkColor:
      Result := Num;
    pvkString:
      if not TryStrToFloat(Str, Result, GFormat) then
        Result := NaN;
  else
    Result := NaN;
  end;
end;

function TPineValue.AsInt: Integer;
var
  LValue: Double;
begin
  LValue := AsFloat;
  if IsNan(LValue) then
    Result := 0
  else
    Result := Trunc(LValue);
end;

function TPineValue.AsBool: Boolean;
begin
  case Kind of
    pvkBool, pvkInt, pvkFloat:
      Result := (not IsNan(Num)) and (Num <> 0);
    pvkString:
      Result := Str <> '';
    pvkRef:
      Result := Ref <> nil;
  else
    Result := False;
  end;
end;

function TPineValue.AsString: string;
var
  I: Integer;
begin
  case Kind of
    pvkNA:
      Result := 'NaN';
    pvkBool:
      if Num <> 0 then
        Result := 'true'
      else
        Result := 'false';
    pvkInt:
      Result := IntToStr(Trunc(Num));
    pvkFloat:
      Result := FormatNumber(Num);
    pvkString:
      Result := Str;
    pvkColor:
      Result := ColorToHex(Cardinal(Trunc(Num)));
    pvkTuple:
      begin
        Result := '[';
        for I := 0 to High(Items) do
        begin
          if I > 0 then
            Result := Result + ', ';
          Result := Result + Items[I].AsString;
        end;
        Result := Result + ']';
      end;
    pvkRef:
      if Ref = nil then
        Result := 'NaN'
      else if Ref is TPineArrayObj then
        Result := ArrayRefToString(TPineArrayObj(Ref))
      else
        Result := KindName;
  else
    Result := '';
  end;
end;

function TPineValue.KindName: string;
begin
  case Kind of
    pvkNA:
      Result := 'na';
    pvkBool:
      Result := 'bool';
    pvkInt:
      Result := 'int';
    pvkFloat:
      Result := 'float';
    pvkString:
      Result := 'string';
    pvkColor:
      Result := 'color';
    pvkTuple:
      Result := 'tuple';
    pvkRef:
      if Ref = nil then
        Result := 'na'
      else if Ref is TPineArrayObj then
        Result := 'array'
      else if Ref is TPineLineObj then
        Result := 'line'
      else if Ref is TPineLabelObj then
        Result := 'label'
      else if Ref is TPineBoxObj then
        Result := 'box'
      else if Ref is TPineTableObj then
        Result := 'table'
      else
        Result := 'object';
  else
    Result := '?';
  end;
end;

{ TPineTableObj }

constructor TPineTableObj.Create;
begin
  inherited Create;
  Cells := TList<TPineTableCell>.Create;
end;

destructor TPineTableObj.Destroy;
begin
  Cells.Free;
  inherited Destroy;
end;

function TPineTableObj.FindCell(ACol, ARow: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to Cells.Count - 1 do
    if (Cells[I].Col = ACol) and (Cells[I].Row = ARow) then
      Exit(I);
  Result := -1;
end;

procedure TPineTableObj.SetCell(ACol, ARow: Integer; const AText: string;
  ATextColor, ABgColor: Cardinal; const AAlignment: string; AHeight: Double);
var
  LIdx: Integer;
  LCell: TPineTableCell;
begin
  LIdx := FindCell(ACol, ARow);
  if LIdx >= 0 then
    LCell := Cells[LIdx]
  else
  begin
    LCell := Default (TPineTableCell);
    LCell.Col := ACol;
    LCell.Row := ARow;
    LCell.MergeToCol := ACol;
    LCell.MergeToRow := ARow;
  end;
  LCell.Text := AText;
  LCell.TextColor := ATextColor;
  LCell.BgColor := ABgColor;
  LCell.Alignment := AAlignment;
  LCell.Height := AHeight;
  if LIdx >= 0 then
    Cells[LIdx] := LCell
  else
    Cells.Add(LCell);
end;

procedure TPineTableObj.MergeCells(AStartCol, AStartRow, AEndCol, AEndRow: Integer);
var
  LIdx: Integer;
  LCell: TPineTableCell;
begin
  LIdx := FindCell(AStartCol, AStartRow);
  if LIdx >= 0 then
    LCell := Cells[LIdx]
  else
  begin
    LCell := Default (TPineTableCell);
    LCell.Col := AStartCol;
    LCell.Row := AStartRow;
  end;
  LCell.MergeToCol := AEndCol;
  LCell.MergeToRow := AEndRow;
  if LIdx >= 0 then
    Cells[LIdx] := LCell
  else
    Cells.Add(LCell);
end;

{ TPineArrayObj }

constructor TPineArrayObj.Create;
begin
  inherited Create;
  Items := TList<TPineValue>.Create;
end;

destructor TPineArrayObj.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

{ TPineSeries }

procedure TPineSeries.EnsureCapacity(ACount: Integer);
var
  LOld, I: Integer;
begin
  if ACount <= Length(FValues) then
    Exit;
  LOld := Length(FValues);
  SetLength(FValues, Max(ACount, Max(16, LOld * 2)));
  for I := LOld to High(FValues) do
    FValues[I] := PineNA;
end;

procedure TPineSeries.SetAt(ABar: Integer; const AValue: TPineValue);
var
  I: Integer;
begin
  if ABar < 0 then
    Exit;
  EnsureCapacity(ABar + 1);
  // fill the gap when the variable was not assigned on some bars
  for I := FCount to ABar - 1 do
    FValues[I] := PineNA;
  FValues[ABar] := AValue;
  if ABar >= FCount then
    FCount := ABar + 1;
end;

function TPineSeries.GetAt(ABar: Integer): TPineValue;
begin
  if (ABar < 0) or (ABar >= FCount) then
    Result := PineNA
  else
    Result := FValues[ABar];
end;

function TPineSeries.History(ACurrentBar, ABarsBack: Integer): TPineValue;
begin
  Result := GetAt(ACurrentBar - ABarsBack);
end;

{ TPineBuffer }

constructor TPineBuffer.Create;
begin
  inherited Create;
  FItems := TList<Double>.Create;
  FLastBar := -1;
end;

destructor TPineBuffer.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TPineBuffer.Push(ABar: Integer; AValue: Double);
begin
  if (ABar = FLastBar) and (FItems.Count > 0) then
    FItems[FItems.Count - 1] := AValue
  else
  begin
    FItems.Add(AValue);
    FLastBar := ABar;
  end;
end;

function TPineBuffer.Get(AOffset: Integer): Double;
var
  LIndex: Integer;
begin
  LIndex := FItems.Count - 1 - AOffset;
  if (LIndex < 0) or (LIndex >= FItems.Count) then
    Result := NaN
  else
    Result := FItems[LIndex];
end;

function TPineBuffer.Count: Integer;
begin
  Result := FItems.Count;
end;

{ TCallState }

constructor TCallState.Create;
var
  I: Integer;
begin
  inherited Create;
  FBuffers := TObjectList<TPineBuffer>.Create(True);
  for I := Low(Nums) to High(Nums) do
    Nums[I] := NaN;
  for I := Low(Ints) to High(Ints) do
    Ints[I] := 0;
  for I := Low(Flags) to High(Flags) do
    Flags[I] := False;
end;

destructor TCallState.Destroy;
begin
  FBuffers.Free;
  inherited Destroy;
end;

function TCallState.Buffer(AIndex: Integer): TPineBuffer;
begin
  while FBuffers.Count <= AIndex do
    FBuffers.Add(TPineBuffer.Create);
  Result := FBuffers[AIndex];
end;

{ TPineArgs }

procedure TPineArgs.Add(const AName: string; const AValue: TPineValue);
var
  N: Integer;
begin
  N := Length(FValues);
  SetLength(FValues, N + 1);
  SetLength(FNames, N + 1);
  FValues[N] := AValue;
  FNames[N] := AName;
end;

function TPineArgs.Count: Integer;
begin
  Result := Length(FValues);
end;

function TPineArgs.Has(AIndex: Integer; const AName: string): Boolean;
var
  I, LPos: Integer;
begin
  if AName <> '' then
    for I := 0 to High(FNames) do
      if SameText(FNames[I], AName) then
        Exit(True);
  LPos := 0;
  for I := 0 to High(FValues) do
    if FNames[I] = '' then
    begin
      if LPos = AIndex then
        Exit(True);
      Inc(LPos);
    end;
  Result := False;
end;

function TPineArgs.Get(AIndex: Integer; const AName: string): TPineValue;
var
  I, LPos: Integer;
begin
  if AName <> '' then
    for I := 0 to High(FNames) do
      if SameText(FNames[I], AName) then
        Exit(FValues[I]);
  LPos := 0;
  for I := 0 to High(FValues) do
    if FNames[I] = '' then
    begin
      if LPos = AIndex then
        Exit(FValues[I]);
      Inc(LPos);
    end;
  Result := PineNA;
end;

function TPineArgs.Num(AIndex: Integer; const AName: string; const ADefault: Double): Double;
var
  LValue: TPineValue;
begin
  LValue := Get(AIndex, AName);
  if LValue.IsNA and not Has(AIndex, AName) then
    Result := ADefault
  else
    Result := LValue.AsFloat;
end;

function TPineArgs.Int(AIndex: Integer; const AName: string; ADefault: Integer): Integer;
var
  LValue: Double;
begin
  LValue := Num(AIndex, AName, ADefault);
  if IsNan(LValue) then
    Result := ADefault
  else
    Result := Trunc(LValue);
end;

function TPineArgs.Bool(AIndex: Integer; const AName: string; ADefault: Boolean): Boolean;
begin
  if not Has(AIndex, AName) then
    Result := ADefault
  else
    Result := Get(AIndex, AName).AsBool;
end;

function TPineArgs.Str(AIndex: Integer; const AName, ADefault: string): string;
begin
  if not Has(AIndex, AName) then
    Result := ADefault
  else
    Result := Get(AIndex, AName).AsString;
end;

initialization

{$IFDEF FPC}
  GFormat := DefaultFormatSettings;
{$ELSE}
  GFormat := TFormatSettings.Create('en-US');
{$ENDIF}
GFormat.DecimalSeparator := '.';
GFormat.ThousandSeparator := ',';

end.
