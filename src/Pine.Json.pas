unit Pine.Json;

{ A small, dependency-free JSON implementation.

  It intentionally does not use System.JSON / fpjson so the exact same code
  compiles unchanged under Delphi and Free Pascal and behaves identically on
  both. This is the only format the Pine library speaks: requests in,
  responses out, nothing else. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Math, Generics.Collections;

type
  EJsonError = class(Exception);

  TJsonKind = (jkNull, jkBool, jkNumber, jkString, jkArray, jkObject);

  TJsonValue = class;

  TJsonMember = record
    Name: string;
    Value: TJsonValue;
  end;

  { A single JSON value: null, bool, number, string, array or object.
    Arrays and objects own the values they contain. }
  TJsonValue = class
  private
    FKind: TJsonKind;
    FBool: Boolean;
    FNum: Double;
    FStr: string;
    FItems: TObjectList<TJsonValue>;
    FMembers: TList<TJsonMember>;
    function FindMember(const AName: string): Integer;
  public
    constructor CreateNull;
    constructor CreateBool(AValue: Boolean);
    constructor CreateNumber(AValue: Double);
    constructor CreateString(const AValue: string);
    constructor CreateArray;
    constructor CreateObject;
    destructor Destroy; override;

    { array API - Add takes ownership of AValue }
    procedure Add(AValue: TJsonValue);
    function ItemCount: Integer;
    function Item(AIndex: Integer): TJsonValue;

    { object API - Put takes ownership of AValue and replaces any
      existing member with the same name }
    procedure Put(const AName: string; AValue: TJsonValue);
    function Has(const AName: string): Boolean;
    function Get(const AName: string): TJsonValue; // nil if absent
    function MemberCount: Integer;
    function MemberName(AIndex: Integer): string;
    function MemberValue(AIndex: Integer): TJsonValue;

    { convenience getters with a default for a missing/wrong-kind member }
    function GetStr(const AName, ADefault: string): string;
    function GetNum(const AName: string; ADefault: Double): Double;
    function GetInt(const AName: string; ADefault: Integer): Integer;
    function GetBool(const AName: string; ADefault: Boolean): Boolean;

    { value accessors, tolerant of the "wrong" kind }
    function AsString: string;
    function AsFloat: Double;
    function AsInt: Integer;
    function AsBool: Boolean;
    function IsNull: Boolean;

    function ToJson(APretty: Boolean = False): string;

    property Kind: TJsonKind read FKind;
  end;

function JsonNull: TJsonValue;
function JsonBool(AValue: Boolean): TJsonValue;
function JsonNumber(AValue: Double): TJsonValue;
function JsonInt(AValue: Int64): TJsonValue;
function JsonStr(const AValue: string): TJsonValue;
function JsonArr: TJsonValue;
function JsonObj: TJsonValue;

{ Parses a JSON document. Raises EJsonError on malformed input;
  the caller owns the returned value. }
function ParseJson(const AText: string): TJsonValue;

implementation

var
  GFmt: TFormatSettings;

function JsonNull: TJsonValue;
begin
  Result := TJsonValue.CreateNull;
end;

function JsonBool(AValue: Boolean): TJsonValue;
begin
  Result := TJsonValue.CreateBool(AValue);
end;

function JsonNumber(AValue: Double): TJsonValue;
begin
  Result := TJsonValue.CreateNumber(AValue);
end;

function JsonInt(AValue: Int64): TJsonValue;
begin
  Result := TJsonValue.CreateNumber(AValue);
end;

function JsonStr(const AValue: string): TJsonValue;
begin
  Result := TJsonValue.CreateString(AValue);
end;

function JsonArr: TJsonValue;
begin
  Result := TJsonValue.CreateArray;
end;

function JsonObj: TJsonValue;
begin
  Result := TJsonValue.CreateObject;
end;

{ TJsonValue }

constructor TJsonValue.CreateNull;
begin
  inherited Create;
  FKind := jkNull;
end;

constructor TJsonValue.CreateBool(AValue: Boolean);
begin
  inherited Create;
  FKind := jkBool;
  FBool := AValue;
end;

constructor TJsonValue.CreateNumber(AValue: Double);
begin
  inherited Create;
  FKind := jkNumber;
  FNum := AValue;
end;

constructor TJsonValue.CreateString(const AValue: string);
begin
  inherited Create;
  FKind := jkString;
  FStr := AValue;
end;

constructor TJsonValue.CreateArray;
begin
  inherited Create;
  FKind := jkArray;
  FItems := TObjectList<TJsonValue>.Create(True);
end;

constructor TJsonValue.CreateObject;
begin
  inherited Create;
  FKind := jkObject;
  FMembers := TList<TJsonMember>.Create;
end;

destructor TJsonValue.Destroy;
var
  I: Integer;
begin
  FItems.Free;
  if FMembers <> nil then
  begin
    for I := 0 to FMembers.Count - 1 do
      FMembers[I].Value.Free;
    FMembers.Free;
  end;
  inherited Destroy;
end;

procedure TJsonValue.Add(AValue: TJsonValue);
begin
  if FKind <> jkArray then
    raise EJsonError.Create('Add() called on a non-array JSON value');
  FItems.Add(AValue);
end;

function TJsonValue.ItemCount: Integer;
begin
  if FKind = jkArray then
    Result := FItems.Count
  else
    Result := 0;
end;

function TJsonValue.Item(AIndex: Integer): TJsonValue;
begin
  if (FKind <> jkArray) or (AIndex < 0) or (AIndex >= FItems.Count) then
    raise EJsonError.CreateFmt('Array index %d out of range', [AIndex]);
  Result := FItems[AIndex];
end;

function TJsonValue.FindMember(const AName: string): Integer;
var
  I: Integer;
begin
  if FMembers <> nil then
    for I := 0 to FMembers.Count - 1 do
      if FMembers[I].Name = AName then
        Exit(I);
  Result := -1;
end;

procedure TJsonValue.Put(const AName: string; AValue: TJsonValue);
var
  LIndex: Integer;
  LMember: TJsonMember;
begin
  if FKind <> jkObject then
    raise EJsonError.Create('Put() called on a non-object JSON value');
  LIndex := FindMember(AName);
  if LIndex >= 0 then
  begin
    FMembers[LIndex].Value.Free;
    LMember := FMembers[LIndex];
    LMember.Value := AValue;
    FMembers[LIndex] := LMember;
  end
  else
  begin
    LMember.Name := AName;
    LMember.Value := AValue;
    FMembers.Add(LMember);
  end;
end;

function TJsonValue.Has(const AName: string): Boolean;
begin
  Result := (FKind = jkObject) and (FindMember(AName) >= 0);
end;

function TJsonValue.Get(const AName: string): TJsonValue;
var
  LIndex: Integer;
begin
  Result := nil;
  if FKind <> jkObject then
    Exit;
  LIndex := FindMember(AName);
  if LIndex >= 0 then
    Result := FMembers[LIndex].Value;
end;

function TJsonValue.MemberCount: Integer;
begin
  if FKind = jkObject then
    Result := FMembers.Count
  else
    Result := 0;
end;

function TJsonValue.MemberName(AIndex: Integer): string;
begin
  Result := FMembers[AIndex].Name;
end;

function TJsonValue.MemberValue(AIndex: Integer): TJsonValue;
begin
  Result := FMembers[AIndex].Value;
end;

function TJsonValue.GetStr(const AName, ADefault: string): string;
var
  LValue: TJsonValue;
begin
  LValue := Get(AName);
  if (LValue = nil) or (LValue.Kind = jkNull) then
    Result := ADefault
  else
    Result := LValue.AsString;
end;

function TJsonValue.GetNum(const AName: string; ADefault: Double): Double;
var
  LValue: TJsonValue;
begin
  LValue := Get(AName);
  if (LValue = nil) or (LValue.Kind = jkNull) then
    Result := ADefault
  else
    Result := LValue.AsFloat;
end;

function TJsonValue.GetInt(const AName: string; ADefault: Integer): Integer;
var
  LValue: TJsonValue;
begin
  LValue := Get(AName);
  if (LValue = nil) or (LValue.Kind = jkNull) then
    Result := ADefault
  else
    Result := LValue.AsInt;
end;

function TJsonValue.GetBool(const AName: string; ADefault: Boolean): Boolean;
var
  LValue: TJsonValue;
begin
  LValue := Get(AName);
  if (LValue = nil) or (LValue.Kind = jkNull) then
    Result := ADefault
  else
    Result := LValue.AsBool;
end;

function TJsonValue.AsString: string;
begin
  case FKind of
    jkNull:
      Result := '';
    jkBool:
      if FBool then
        Result := 'true'
      else
        Result := 'false';
    jkNumber:
      Result := FloatToStr(FNum, GFmt);
    jkString:
      Result := FStr;
  else
    Result := ToJson(False);
  end;
end;

function TJsonValue.AsFloat: Double;
begin
  case FKind of
    jkNumber:
      Result := FNum;
    jkBool:
      if FBool then
        Result := 1
      else
        Result := 0;
    jkString:
      if not TryStrToFloat(FStr, Result, GFmt) then
        Result := NaN;
  else
    Result := NaN;
  end;
end;

function TJsonValue.AsInt: Integer;
var
  LValue: Double;
begin
  LValue := AsFloat;
  if IsNan(LValue) then
    Result := 0
  else
    Result := Trunc(LValue);
end;

function TJsonValue.AsBool: Boolean;
begin
  case FKind of
    jkBool:
      Result := FBool;
    jkNumber:
      Result := FNum <> 0;
    jkString:
      Result := SameText(FStr, 'true') or (FStr = '1');
  else
    Result := False;
  end;
end;

function TJsonValue.IsNull: Boolean;
begin
  Result := FKind = jkNull;
end;

{ ---------------- string builder ---------------- }

type
  { Minimal append-only string builder used by the serializer and the parser.
    It deliberately offers exactly two non-overloaded methods instead of
    using the RTL's TJsonBuilder: that class has many Append overloads
    (Char, string, Integer, Boolean, ...) and Free Pascal in Unicode-strings
    mode cannot always decide which one a one-character literal or a Char
    variable means ("Can't determine which overloaded function to call").
    Append takes a string, AppendChar takes a Char - nothing to resolve. }
  TJsonBuilder = class
  private
    FBuf: string;
    FLen: Integer;
    procedure Grow(AExtra: Integer);
  public
    constructor Create(ACapacity: Integer = 256);
    function Append(const S: string): TJsonBuilder;
    function AppendChar(C: Char): TJsonBuilder;
    function AsString: string;
  end;

constructor TJsonBuilder.Create(ACapacity: Integer);
begin
  inherited Create;
  if ACapacity < 16 then
    ACapacity := 16;
  SetLength(FBuf, ACapacity);
  FLen := 0;
end;

procedure TJsonBuilder.Grow(AExtra: Integer);
var
  LNewCap: Integer;
begin
  if FLen + AExtra <= Length(FBuf) then
    Exit;
  LNewCap := Length(FBuf) * 2;
  if LNewCap < FLen + AExtra then
    LNewCap := FLen + AExtra;
  SetLength(FBuf, LNewCap);
end;

function TJsonBuilder.Append(const S: string): TJsonBuilder;
var
  LCount: Integer;
begin
  LCount := Length(S);
  if LCount > 0 then
  begin
    Grow(LCount);
    Move(S[1], FBuf[FLen + 1], LCount * SizeOf(Char));
    Inc(FLen, LCount);
  end;
  Result := Self;
end;

function TJsonBuilder.AppendChar(C: Char): TJsonBuilder;
begin
  Grow(1);
  Inc(FLen);
  FBuf[FLen] := C;
  Result := Self;
end;

function TJsonBuilder.AsString: string;
begin
  Result := Copy(FBuf, 1, FLen);
end;

{ ---------------- serialization ---------------- }

function EscapeJsonString(const S: string): string;
var
  I: Integer;
  C: Char;
  LOut: TJsonBuilder;
begin
  LOut := TJsonBuilder.Create(Length(S) + 2);
  try
    for I := 1 to Length(S) do
    begin
      C := S[I];
      case C of
        '"':
          LOut.Append('\"');
        '\':
          LOut.Append('\\');
        #8:
          LOut.Append('\b');
        #9:
          LOut.Append('\t');
        #10:
          LOut.Append('\n');
        #12:
          LOut.Append('\f');
        #13:
          LOut.Append('\r');
      else
        if C < #$20 then
          LOut.Append('\u').Append(IntToHex(Integer(Ord(C)), 4))
        else
          LOut.AppendChar(C);
      end;
    end;
    Result := LOut.AsString;
  finally
    LOut.Free;
  end;
end;

function FormatJsonNumber(const AValue: Double): string;
begin
  if IsNan(AValue) or IsInfinite(AValue) then
    Exit('null'); // JSON has no NaN/Infinity literal
  if (Abs(AValue) < 1.0E15) and (SameValue(AValue, Int(AValue))) then
    Result := IntToStr(Trunc(AValue))
  else
    Result := FloatToStr(AValue, GFmt);
end;

function TJsonValue.ToJson(APretty: Boolean): string;

  procedure Build(AValue: TJsonValue; ADepth: Integer; AOut: TJsonBuilder);
  var
    I: Integer;

    procedure NewLine(ALevel: Integer);
    begin
      if APretty then
        AOut.Append(sLineBreak).Append(StringOfChar(' ', ALevel * 2));
    end;

  begin
    if AValue = nil then
    begin
      AOut.Append('null');
      Exit;
    end;
    case AValue.Kind of
      jkNull:
        AOut.Append('null');
      jkBool:
        if AValue.FBool then
          AOut.Append('true')
        else
          AOut.Append('false');
      jkNumber:
        AOut.Append(FormatJsonNumber(AValue.FNum));
      jkString:
        AOut.Append('"').Append(EscapeJsonString(AValue.FStr)).Append('"');
      jkArray:
        begin
          if AValue.FItems.Count = 0 then
          begin
            AOut.Append('[]');
            Exit;
          end;
          AOut.Append('[');
          for I := 0 to AValue.FItems.Count - 1 do
          begin
            if I > 0 then
              AOut.Append(',');
            NewLine(ADepth + 1);
            Build(AValue.FItems[I], ADepth + 1, AOut);
          end;
          NewLine(ADepth);
          AOut.Append(']');
        end;
      jkObject:
        begin
          if AValue.FMembers.Count = 0 then
          begin
            AOut.Append('{}');
            Exit;
          end;
          AOut.Append('{');
          for I := 0 to AValue.FMembers.Count - 1 do
          begin
            if I > 0 then
              AOut.Append(',');
            NewLine(ADepth + 1);
            AOut.Append('"').Append(EscapeJsonString(AValue.FMembers[I].Name)).Append('"');
            AOut.Append(':');
            if APretty then
              AOut.Append(' ');
            Build(AValue.FMembers[I].Value, ADepth + 1, AOut);
          end;
          NewLine(ADepth);
          AOut.Append('}');
        end;
    end;
  end;

var
  LOut: TJsonBuilder;
begin
  LOut := TJsonBuilder.Create;
  try
    Build(Self, 0, LOut);
    Result := LOut.AsString;
  finally
    LOut.Free;
  end;
end;

{ ---------------- parsing ---------------- }

type
  TJsonParser = class
  private
    FText: string;
    FPos: Integer;
    FLen: Integer;
    function Cur: Char;
    procedure Advance;
    procedure SkipWhitespace;
    procedure Expect(AChar: Char);
    function ParseValue: TJsonValue;
    function ParseObject: TJsonValue;
    function ParseArray: TJsonValue;
    function ParseString: string;
    function ParseNumber: TJsonValue;
    function ParseLiteral(const AWord: string; AResult: TJsonValue): TJsonValue;
  public
    constructor Create(const AText: string);
    function Parse: TJsonValue;
  end;

constructor TJsonParser.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FPos := 1;
  FLen := Length(AText);
end;

function TJsonParser.Cur: Char;
begin
  if FPos <= FLen then
    Result := FText[FPos]
  else
    Result := #0;
end;

procedure TJsonParser.Advance;
begin
  Inc(FPos);
end;

procedure TJsonParser.SkipWhitespace;
begin
  while (FPos <= FLen) and CharInSet(FText[FPos], [' ', #9, #10, #13]) do
    Inc(FPos);
end;

procedure TJsonParser.Expect(AChar: Char);
begin
  if Cur <> AChar then
    raise EJsonError.CreateFmt('Expected "%s" at position %d, found "%s"',
      [AChar, FPos, Cur]);
  Advance;
end;

function TJsonParser.ParseLiteral(const AWord: string; AResult: TJsonValue): TJsonValue;
begin
  if Copy(FText, FPos, Length(AWord)) <> AWord then
  begin
    AResult.Free;
    raise EJsonError.CreateFmt('Invalid literal at position %d', [FPos]);
  end;
  Inc(FPos, Length(AWord));
  Result := AResult;
end;

function TJsonParser.ParseString: string;
var
  LOut: TJsonBuilder;
  C: Char;
  LCode: Integer;
  LHex: string;
begin
  Expect('"');
  LOut := TJsonBuilder.Create;
  try
    while True do
    begin
      if FPos > FLen then
        raise EJsonError.Create('Unterminated string in JSON input');
      C := FText[FPos];
      if C = '"' then
      begin
        Advance;
        Break;
      end;
      if C = '\' then
      begin
        Advance;
        C := Cur;
        case C of
          '"':
            LOut.Append('"');
          '\':
            LOut.Append('\');
          '/':
            LOut.Append('/');
          'b':
            LOut.AppendChar(#8);
          'f':
            LOut.AppendChar(#12);
          'n':
            LOut.AppendChar(#10);
          'r':
            LOut.AppendChar(#13);
          't':
            LOut.AppendChar(#9);
          'u':
            begin
              LHex := Copy(FText, FPos + 1, 4);
              if (Length(LHex) < 4) or not TryStrToInt('$' + LHex, LCode) then
                raise EJsonError.CreateFmt('Invalid \u escape at position %d', [FPos]);
              LOut.AppendChar(Char(LCode));
              Inc(FPos, 4);
            end;
        else
          raise EJsonError.CreateFmt('Invalid escape sequence at position %d', [FPos]);
        end;
        Advance;
      end
      else
      begin
        LOut.AppendChar(C);
        Advance;
      end;
    end;
    Result := LOut.AsString;
  finally
    LOut.Free;
  end;
end;

function TJsonParser.ParseNumber: TJsonValue;
var
  LStart: Integer;
  LText: string;
  LValue: Double;
begin
  LStart := FPos;
  if Cur = '-' then
    Advance;
  while CharInSet(Cur, ['0' .. '9']) do
    Advance;
  if Cur = '.' then
  begin
    Advance;
    while CharInSet(Cur, ['0' .. '9']) do
      Advance;
  end;
  if (Cur = 'e') or (Cur = 'E') then
  begin
    Advance;
    if (Cur = '+') or (Cur = '-') then
      Advance;
    while CharInSet(Cur, ['0' .. '9']) do
      Advance;
  end;
  LText := Copy(FText, LStart, FPos - LStart);
  if (LText = '') or not TryStrToFloat(LText, LValue, GFmt) then
    raise EJsonError.CreateFmt('Invalid number at position %d', [LStart]);
  Result := TJsonValue.CreateNumber(LValue);
end;

function TJsonParser.ParseArray: TJsonValue;
begin
  Result := TJsonValue.CreateArray;
  try
    Expect('[');
    SkipWhitespace;
    if Cur = ']' then
    begin
      Advance;
      Exit;
    end;
    while True do
    begin
      SkipWhitespace;
      Result.Add(ParseValue);
      SkipWhitespace;
      if Cur = ',' then
      begin
        Advance;
        Continue;
      end;
      Break;
    end;
    SkipWhitespace;
    Expect(']');
  except
    Result.Free;
    raise;
  end;
end;

function TJsonParser.ParseObject: TJsonValue;
var
  LName: string;
begin
  Result := TJsonValue.CreateObject;
  try
    Expect('{');
    SkipWhitespace;
    if Cur = '}' then
    begin
      Advance;
      Exit;
    end;
    while True do
    begin
      SkipWhitespace;
      if Cur <> '"' then
        raise EJsonError.CreateFmt('Expected a member name at position %d', [FPos]);
      LName := ParseString;
      SkipWhitespace;
      Expect(':');
      SkipWhitespace;
      Result.Put(LName, ParseValue);
      SkipWhitespace;
      if Cur = ',' then
      begin
        Advance;
        Continue;
      end;
      Break;
    end;
    SkipWhitespace;
    Expect('}');
  except
    Result.Free;
    raise;
  end;
end;

function TJsonParser.ParseValue: TJsonValue;
begin
  SkipWhitespace;
  case Cur of
    '{':
      Result := ParseObject;
    '[':
      Result := ParseArray;
    '"':
      Result := TJsonValue.CreateString(ParseString);
    't':
      Result := ParseLiteral('true', TJsonValue.CreateBool(True));
    'f':
      Result := ParseLiteral('false', TJsonValue.CreateBool(False));
    'n':
      Result := ParseLiteral('null', TJsonValue.CreateNull);
    '-', '0' .. '9':
      Result := ParseNumber;
  else
    raise EJsonError.CreateFmt('Unexpected character "%s" at position %d', [Cur, FPos]);
  end;
end;

function TJsonParser.Parse: TJsonValue;
begin
  SkipWhitespace;
  if FPos > FLen then
    raise EJsonError.Create('Empty JSON input');
  Result := ParseValue;
  SkipWhitespace;
  if FPos <= FLen then
  begin
    Result.Free;
    raise EJsonError.CreateFmt('Unexpected trailing data at position %d', [FPos]);
  end;
end;

function ParseJson(const AText: string): TJsonValue;
var
  LParser: TJsonParser;
begin
  LParser := TJsonParser.Create(AText);
  try
    Result := LParser.Parse;
  finally
    LParser.Free;
  end;
end;

initialization

{$IFDEF FPC}
  GFmt := DefaultFormatSettings;
{$ELSE}
  GFmt := TFormatSettings.Create('en-US');
{$ENDIF}
GFmt.DecimalSeparator := '.';
GFmt.ThousandSeparator := ',';

end.
