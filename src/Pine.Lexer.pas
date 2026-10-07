unit Pine.Lexer;

{ Tokenizer for Pine Script.

  Pine is an indentation based language, therefore the lexer produces
  virtual INDENT / DEDENT / NEWLINE tokens like Python does.
  A logical line continues on the next physical line when a bracket is
  still open or when the line ends with a binary operator or a comma. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, Pine.Types;

type
  TTokenKind = (tkEOF, tkNewLine, tkIndent, tkDedent, tkNumber, tkString,
    tkColor, tkIdent, tkKeyword, tkOp);

  TToken = record
    Kind: TTokenKind;
    Text: string;
    Num: Double;
    Line: Integer;
    Col: Integer;
    function Is_(AKind: TTokenKind; const AText: string): Boolean;
    function Describe: string;
  end;

  TTokenArray = TArray<TToken>;

  TPineLexer = class
  private
    FSource: string;
    FTokens: TList<TToken>;
    FIndents: TList<Integer>;
    FVersion: Integer;
    procedure AddToken(AKind: TTokenKind; const AText: string; ANum: Double;
      ALine, ACol: Integer);
    { Tokenizes one physical line into ATarget. ADepth accumulates the net
      bracket nesting ( '(' '[' vs ')' ']' ) and ATernaryDepth the net count
      of unmatched '?' vs ':' seen so far in the current logical line - both
      carried across physical lines by the caller. }
    procedure ScanLine(const ALine: string; ALineNo: Integer; ATarget: TList<TToken>;
      var ADepth, ATernaryDepth: Integer);
    function IsContinuation(ATokens: TList<TToken>): Boolean;
  public
    constructor Create(const ASource: string);
    destructor Destroy; override;
    function Tokenize: TTokenArray;
    property Version: Integer read FVersion;
  end;

function IsPineKeyword(const AWord: string): Boolean;

implementation

const
  CKeywords: array [0 .. 16] of string = ('if', 'else', 'for', 'to', 'by',
    'while', 'var', 'varip', 'and', 'or', 'not', 'true', 'false', 'na',
    'break', 'continue', 'switch');

function IsPineKeyword(const AWord: string): Boolean;
var
  I: Integer;
begin
  for I := Low(CKeywords) to High(CKeywords) do
    if CKeywords[I] = AWord then
      Exit(True);
  Result := False;
end;

{ TToken }

function TToken.Is_(AKind: TTokenKind; const AText: string): Boolean;
begin
  Result := (Kind = AKind) and ((AText = '') or (Text = AText));
end;

function TToken.Describe: string;
begin
  case Kind of
    tkEOF:
      Result := '<eof>';
    tkNewLine:
      Result := '<newline>';
    tkIndent:
      Result := '<indent>';
    tkDedent:
      Result := '<dedent>';
    tkNumber:
      Result := FormatNumber(Num);
  else
    Result := Text;
  end;
end;

{ TPineLexer }

constructor TPineLexer.Create(const ASource: string);
begin
  inherited Create;
  FSource := ASource;
  FTokens := TList<TToken>.Create;
  FIndents := TList<Integer>.Create;
  FVersion := 5;
end;

destructor TPineLexer.Destroy;
begin
  FIndents.Free;
  FTokens.Free;
  inherited Destroy;
end;

procedure TPineLexer.AddToken(AKind: TTokenKind; const AText: string; ANum: Double;
  ALine, ACol: Integer);
var
  LToken: TToken;
begin
  LToken.Kind := AKind;
  LToken.Text := AText;
  LToken.Num := ANum;
  LToken.Line := ALine;
  LToken.Col := ACol;
  FTokens.Add(LToken);
end;

procedure TPineLexer.ScanLine(const ALine: string; ALineNo: Integer;
  ATarget: TList<TToken>; var ADepth, ATernaryDepth: Integer);
var
  I, LLen, LStart: Integer;
  C: Char;
  LText: string;
  LNum: Double;
  LToken: TToken;
  LQuote: Char;
  LFmt: TFormatSettings;

  procedure Emit(AKind: TTokenKind; const AText: string; ANum: Double; ACol: Integer);
  begin
    LToken.Kind := AKind;
    LToken.Text := AText;
    LToken.Num := ANum;
    LToken.Line := ALineNo;
    LToken.Col := ACol;
    ATarget.Add(LToken);
  end;

begin
{$IFDEF FPC}
  LFmt := DefaultFormatSettings;
{$ELSE}
  LFmt := TFormatSettings.Create('en-US');
{$ENDIF}
  LFmt.DecimalSeparator := '.';
  I := 1;
  LLen := Length(ALine);
  while I <= LLen do
  begin
    C := ALine[I];
    // whitespace
    if (C = ' ') or (C = #9) or (C = #13) then
    begin
      Inc(I);
      Continue;
    end;
    // comment: the rest of the line is ignored
    if (C = '/') and (I < LLen) and (ALine[I + 1] = '/') then
    begin
      LText := Copy(ALine, I, LLen - I + 1);
      if Pos('@version', LText) > 0 then
        FVersion := StrToIntDef(Trim(Copy(LText, Pos('=', LText) + 1, 4)), FVersion);
      Exit;
    end;
    // number literal
    if CharInSet(C, ['0' .. '9']) or ((C = '.') and (I < LLen) and
      CharInSet(ALine[I + 1], ['0' .. '9'])) then
    begin
      LStart := I;
      while (I <= LLen) and CharInSet(ALine[I], ['0' .. '9', '.']) do
        Inc(I);
      if (I <= LLen) and CharInSet(ALine[I], ['e', 'E']) then
      begin
        Inc(I);
        if (I <= LLen) and CharInSet(ALine[I], ['+', '-']) then
          Inc(I);
        while (I <= LLen) and CharInSet(ALine[I], ['0' .. '9']) do
          Inc(I);
      end;
      LText := Copy(ALine, LStart, I - LStart);
      // "0." (a trailing decimal point with nothing after it) is valid Pine
      // and appears in real scripts (e.g. array.new_float(n, 0.)), but some
      // RTL versions of TryStrToFloat reject it - pad it before parsing.
      if (LText <> '') and (LText[Length(LText)] = '.') then
      begin
        if not TryStrToFloat(LText + '0', LNum, LFmt) then
          raise EPineSyntaxError.CreateFmt('Invalid number "%s" at line %d', [LText, ALineNo]);
      end
      else if not TryStrToFloat(LText, LNum, LFmt) then
        raise EPineSyntaxError.CreateFmt('Invalid number "%s" at line %d', [LText, ALineNo]);
      Emit(tkNumber, LText, LNum, LStart);
      Continue;
    end;
    // string literal
    if (C = '"') or (C = '''') then
    begin
      LQuote := C;
      LStart := I;
      Inc(I);
      LText := '';
      while (I <= LLen) and (ALine[I] <> LQuote) do
      begin
        if (ALine[I] = '\') and (I < LLen) then
        begin
          Inc(I);
          case ALine[I] of
            'n':
              LText := LText + #10;
            't':
              LText := LText + #9;
            'r':
              LText := LText + #13;
          else
            LText := LText + ALine[I];
          end;
        end
        else
          LText := LText + ALine[I];
        Inc(I);
      end;
      if I > LLen then
        raise EPineSyntaxError.CreateFmt('Unterminated string at line %d', [ALineNo]);
      Inc(I); // closing quote
      Emit(tkString, LText, 0, LStart);
      Continue;
    end;
    // color literal: #RRGGBB or #RRGGBBAA
    if C = '#' then
    begin
      LStart := I;
      Inc(I);
      LText := '';
      while (I <= LLen) and CharInSet(ALine[I], ['0' .. '9', 'a' .. 'f', 'A' .. 'F']) do
      begin
        LText := LText + ALine[I];
        Inc(I);
      end;
      if not(Length(LText) in [6, 8]) then
        raise EPineSyntaxError.CreateFmt('Invalid color literal at line %d', [ALineNo]);
      if Length(LText) = 6 then
        LNum := StrToInt64('$FF' + LText)
      else
        LNum := StrToInt64('$' + Copy(LText, 7, 2) + Copy(LText, 1, 6));
      Emit(tkColor, '#' + LText, LNum, LStart);
      Continue;
    end;
    // identifier or keyword
    if CharInSet(C, ['a' .. 'z', 'A' .. 'Z', '_']) then
    begin
      LStart := I;
      while (I <= LLen) and CharInSet(ALine[I], ['a' .. 'z', 'A' .. 'Z', '0' .. '9', '_']) do
        Inc(I);
      LText := Copy(ALine, LStart, I - LStart);
      if IsPineKeyword(LText) then
        Emit(tkKeyword, LText, 0, LStart)
      else
        Emit(tkIdent, LText, 0, LStart);
      Continue;
    end;
    // two character operators
    if I < LLen then
    begin
      LText := Copy(ALine, I, 2);
      if (LText = ':=') or (LText = '==') or (LText = '!=') or (LText = '<=') or
        (LText = '>=') or (LText = '=>') or (LText = '+=') or (LText = '-=') or
        (LText = '*=') or (LText = '/=') or (LText = '%=') then
      begin
        Emit(tkOp, LText, 0, I);
        Inc(I, 2);
        Continue;
      end;
    end;
    // single character operators
    if CharInSet(C, ['+', '-', '*', '/', '%', '=', '<', '>', '?', ':', '(', ')',
      '[', ']', ',', '.']) then
    begin
      if CharInSet(C, ['(', '[']) then
        Inc(ADepth);
      if CharInSet(C, [')', ']']) then
        Dec(ADepth);
      // a ternary's '?' and ':' can be separated by many lines and even by
      // a nested call that fully closes its own parens in between (e.g. a
      // multi-line line.new(...) call as the ternary's "then" branch), so
      // this is tracked the same way as bracket depth, independently of it.
      if C = '?' then
        Inc(ATernaryDepth);
      if C = ':' then
        Dec(ATernaryDepth);
      Emit(tkOp, C, 0, I);
      Inc(I);
      Continue;
    end;
    raise EPineSyntaxError.CreateFmt('Unexpected character "%s" at line %d, column %d',
      [C, ALineNo, I]);
  end;
end;

function TPineLexer.IsContinuation(ATokens: TList<TToken>): Boolean;
var
  LLast: TToken;
begin
  Result := False;
  if ATokens.Count = 0 then
    Exit;
  LLast := ATokens[ATokens.Count - 1];
  if LLast.Kind = tkOp then
    // '=>' always ends the header line of a function declaration - the
    // block that follows is introduced by NEWLINE + INDENT, exactly like
    // ')' and ']' already end their own line instead of continuing it.
    Result := (LLast.Text <> ')') and (LLast.Text <> ']') and (LLast.Text <> '=>');
  if LLast.Kind = tkKeyword then
    Result := (LLast.Text = 'and') or (LLast.Text = 'or') or (LLast.Text = 'not');
end;



function TPineLexer.Tokenize: TTokenArray;
var
  LLines: TStringList;
  LLineTokens, LLogical: TList<TToken>;
  I, J, LIndent, LDepth, LTernaryDepth, LLogicalLine: Integer;
  LRaw: string;
  LPending: Boolean;
begin
  FTokens.Clear;
  FIndents.Clear;
  FIndents.Add(0);
  LLines := TStringList.Create;
  LLineTokens := TList<TToken>.Create;
  LLogical := TList<TToken>.Create;
  try
    LLines.Text := FSource;
    LDepth := 0;
    LTernaryDepth := 0;
    LPending := False; // a logical line is still open
    LIndent := 0;
    LLogicalLine := 1;
    for I := 0 to LLines.Count - 1 do
    begin
      LRaw := LLines[I];
      LLineTokens.Clear;
      ScanLine(LRaw, I + 1, LLineTokens, LDepth, LTernaryDepth);
      if LLineTokens.Count = 0 then
      begin
        // an empty line never breaks an open logical line
        Continue;
      end;
      if not LPending then
      begin
        // measure indentation (a tab counts as 4 spaces)
        LIndent := 0;
        for J := 1 to Length(LRaw) do
        begin
          if LRaw[J] = ' ' then
            Inc(LIndent)
          else if LRaw[J] = #9 then
            Inc(LIndent, 4)
          else
            Break;
        end;
        LLogicalLine := I + 1;
        LLogical.Clear;
      end;
      for J := 0 to LLineTokens.Count - 1 do
        LLogical.Add(LLineTokens[J]);
      { A statement keeps going across lines while a bracket is still open,
        while a ternary's '?' is still waiting for its ':' - which may sit
        many lines later, even after a nested call has fully closed its own
        parens on a line in between (e.g. a multi-line line.new(...) call
        used as the ternary's "then" branch) - or while the line ends with
        an operator that demands more (and/or/not, or any operator other
        than the ones that always finish their own line: ')', ']', '=>'). }
      LPending := (LDepth > 0) or (LTernaryDepth > 0) or IsContinuation(LLogical);
      if LPending then
        Continue;
      // the logical line is complete: emit indentation changes first
      while LIndent < FIndents[FIndents.Count - 1] do
      begin
        FIndents.Delete(FIndents.Count - 1);
        AddToken(tkDedent, '', 0, LLogicalLine, 1);
      end;
      if LIndent > FIndents[FIndents.Count - 1] then
      begin
        FIndents.Add(LIndent);
        AddToken(tkIndent, '', 0, LLogicalLine, 1);
      end;
      for J := 0 to LLogical.Count - 1 do
        FTokens.Add(LLogical[J]);
      AddToken(tkNewLine, '', 0, LLogicalLine, 1);
      LLogical.Clear;
    end;
    if LLogical.Count > 0 then
    begin
      for J := 0 to LLogical.Count - 1 do
        FTokens.Add(LLogical[J]);
      AddToken(tkNewLine, '', 0, LLogicalLine, 1);
    end;
    while FIndents.Count > 1 do
    begin
      FIndents.Delete(FIndents.Count - 1);
      AddToken(tkDedent, '', 0, LLines.Count, 1);
    end;
    AddToken(tkEOF, '', 0, LLines.Count + 1, 1);
    Result := FTokens.ToArray;
  finally
    LLogical.Free;
    LLineTokens.Free;
    LLines.Free;
  end;
end;

end.
