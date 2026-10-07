unit Pine.Parser;

(* Recursive descent parser for the supported subset of Pine Script v4/v5.

  Grammar (informal):
    program     := { statement }
    statement   := funcDecl | varDecl | assignment | ifStmt | forStmt
                 | whileStmt | 'break' | 'continue' | exprStmt
    funcDecl    := ident '(' [params] ')' '=>' ( expr | block )
    varDecl     := ['var'|'varip'] [type] ident '=' expr
                 | '[' ident {',' ident} ']' '=' expr
    assignment  := ident ':=' expr
    ifStmt      := 'if' expr block [ 'else' (ifStmt | block) ]
    forStmt     := 'for' ident '=' expr 'to' expr ['by' expr] block
    expr        := ternary
    ternary     := orExpr [ '?' expr ':' expr ]
    orExpr      := andExpr { 'or' andExpr }
    andExpr     := notExpr { 'and' notExpr }
    notExpr     := [ 'not' ] comparison
    comparison  := additive { ('=='|'!='|'<'|'<='|'>'|'>=') additive }
    additive    := multiplicative { ('+'|'-') multiplicative }
    multiplicative := unary { ('*'|'/'|'%') unary }
    unary       := ['+'|'-'|'not'] postfix
    postfix     := primary { '(' args ')' | '[' expr ']' }
    primary     := number | string | color | 'true' | 'false' | 'na'
                 | qualifiedIdent | '(' expr ')' | ifExpr } *)

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Generics.Collections, Pine.Types, Pine.Lexer, Pine.Ast;

type
  TPineParser = class
  private
    FTokens: TTokenArray;
    FPos: Integer;
    FProgram: TPineProgram;
    function Cur: TToken;
    function Peek(AOffset: Integer): TToken;
    function AtOp(const AText: string): Boolean;
    function AtKeyword(const AText: string): Boolean;
    function AcceptOp(const AText: string): Boolean;
    function AcceptKeyword(const AText: string): Boolean;
    procedure ExpectOp(const AText: string);
    procedure ExpectKind(AKind: TTokenKind; const AWhat: string);
    procedure SkipNewLines;
    function NewSite: Integer;
    procedure Attach(ANode: TPineNode; const AToken: TToken);
    { statements }
    procedure ParseStatementInto(ATarget: TPineNodeList);
    procedure ParseSingleStatement(ATarget: TPineNodeList);
    function ParseBlock: TPineNodeList;
    function ParseIf: TIfNode;
    function ParseSwitch: TSwitchNode;
    function IsTupleDeclAhead: Boolean;
    function ParseFor: TForNode;
    function ParseWhile: TWhileNode;
    function TryParseFuncDecl: TFuncDeclNode;
    function ParseTupleDecl: TTupleDeclNode;
    { expressions }
    function ParseExpression: TPineNode;
    function ParseTernary: TPineNode;
    function ParseOr: TPineNode;
    function ParseAnd: TPineNode;
    function ParseComparison: TPineNode;
    function ParseAdditive: TPineNode;
    function ParseMultiplicative: TPineNode;
    function ParseUnary: TPineNode;
    function ParsePostfix: TPineNode;
    function ParsePrimary: TPineNode;
    function ParseCallArgs(ACall: TCallNode): Boolean;
  public
    constructor Create(const ATokens: TTokenArray);
    { Parses the token stream. The caller owns the returned program. }
    function ParseProgram(AVersion: Integer): TPineProgram;
  end;

{ Convenience helper: source text -> compiled program. }
function CompilePine(const ASource: string): TPineProgram;

implementation

const
  CTypeNames: array [0 .. 12] of string = ('int', 'float', 'bool', 'string',
    'color', 'label', 'line', 'array', 'matrix', 'table', 'box', 'polyline',
    'linefill');

  { Identifiers whose leading segment starts a fully qualified BUILT-IN
    name (ta.sma, shape.labeldown, dayofweek.sunday, ...): a dotted chain
    starting with one of these is flattened into a single qualified
    TIdentNode/TCallNode name, exactly as before. A dotted chain starting
    with anything else is a plain variable, and further dots after it are
    method-call syntax (base.method(args)) resolved at evaluation time from
    the value's runtime type - see ParsePostfix and
    TPineInterpreter.EvalMethodCall. }
  CNamespaces: array [0 .. 40] of string = ('ta', 'math', 'str', 'array',
    'matrix', 'map', 'color', 'line', 'label', 'box', 'table', 'input',
    'plot', 'log', 'alert', 'syminfo', 'timeframe', 'barstate', 'strategy',
    'ticker', 'request', 'polyline', 'linefill', 'runtime', 'chart',
    'session', 'dayofweek', 'format', 'shape', 'location', 'xloc', 'extend',
    'display', 'text', 'size', 'position', 'currency', 'adjustment',
    'settlement', 'splits', 'dividends');

function IsTypeName(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := Low(CTypeNames) to High(CTypeNames) do
    if CTypeNames[I] = AName then
      Exit(True);
  Result := False;
end;

function IsNamespace(const AName: string): Boolean;
var
  I: Integer;
begin
  for I := Low(CNamespaces) to High(CNamespaces) do
    if CNamespaces[I] = AName then
      Exit(True);
  Result := False;
end;

function CompilePine(const ASource: string): TPineProgram;
var
  LLexer: TPineLexer;
  LParser: TPineParser;
  LTokens: TTokenArray;
begin
  LLexer := TPineLexer.Create(ASource);
  try
    LTokens := LLexer.Tokenize;
    LParser := TPineParser.Create(LTokens);
    try
      Result := LParser.ParseProgram(LLexer.Version);
    finally
      LParser.Free;
    end;
  finally
    LLexer.Free;
  end;
end;

{ TPineParser }

constructor TPineParser.Create(const ATokens: TTokenArray);
begin
  inherited Create;
  FTokens := ATokens;
  FPos := 0;
end;

function TPineParser.Cur: TToken;
begin
  Result := FTokens[FPos];
end;

function TPineParser.Peek(AOffset: Integer): TToken;
var
  LIndex: Integer;
begin
  LIndex := FPos + AOffset;
  if LIndex >= Length(FTokens) then
    LIndex := High(FTokens);
  Result := FTokens[LIndex];
end;

function TPineParser.AtOp(const AText: string): Boolean;
begin
  Result := (Cur.Kind = tkOp) and (Cur.Text = AText);
end;

function TPineParser.AtKeyword(const AText: string): Boolean;
begin
  Result := (Cur.Kind = tkKeyword) and (Cur.Text = AText);
end;

function TPineParser.AcceptOp(const AText: string): Boolean;
begin
  Result := AtOp(AText);
  if Result then
    Inc(FPos);
end;

function TPineParser.AcceptKeyword(const AText: string): Boolean;
begin
  Result := AtKeyword(AText);
  if Result then
    Inc(FPos);
end;

procedure TPineParser.ExpectOp(const AText: string);
begin
  if not AcceptOp(AText) then
    raise EPineSyntaxError.CreateFmt('Expected "%s" but found "%s" at line %d',
      [AText, Cur.Describe, Cur.Line]);
end;

procedure TPineParser.ExpectKind(AKind: TTokenKind; const AWhat: string);
begin
  if Cur.Kind <> AKind then
    raise EPineSyntaxError.CreateFmt('Expected %s but found "%s" at line %d',
      [AWhat, Cur.Describe, Cur.Line]);
  Inc(FPos);
end;

procedure TPineParser.SkipNewLines;
begin
  while Cur.Kind = tkNewLine do
    Inc(FPos);
end;

function TPineParser.NewSite: Integer;
begin
  Result := FProgram.SiteCount;
  Inc(FProgram.SiteCount);
end;

procedure TPineParser.Attach(ANode: TPineNode; const AToken: TToken);
begin
  ANode.Line := AToken.Line;
  ANode.Col := AToken.Col;
  ANode.SiteId := NewSite;
end;

function TPineParser.ParseProgram(AVersion: Integer): TPineProgram;
begin
  FProgram := TPineProgram.Create;
  try
    FProgram.Version := AVersion;
    SkipNewLines;
    while Cur.Kind <> tkEOF do
    begin
      if Cur.Kind in [tkIndent, tkDedent, tkNewLine] then
      begin
        Inc(FPos);
        Continue;
      end;
      ParseStatementInto(FProgram.Body);
      SkipNewLines;
    end;
    Result := FProgram;
  except
    FProgram.Free;
    raise;
  end;
end;

function TPineParser.ParseBlock: TPineNodeList;
begin
  Result := TPineNodeList.Create(True);
  try
    if Cur.Kind = tkNewLine then
    begin
      SkipNewLines;
      if Cur.Kind <> tkIndent then
        raise EPineSyntaxError.CreateFmt('Indented block expected at line %d', [Cur.Line]);
      Inc(FPos); // consume INDENT
      while not(Cur.Kind in [tkDedent, tkEOF]) do
      begin
        if Cur.Kind = tkNewLine then
        begin
          Inc(FPos);
          Continue;
        end;
        ParseStatementInto(Result);
      end;
      if Cur.Kind = tkDedent then
        Inc(FPos);
    end
    else
      // single statement on the same line, e.g. "if cond \n" is normal Pine,
      // but "f(x) => x * 2" style one liners end up here as well
      ParseStatementInto(Result);
  except
    Result.Free;
    raise;
  end;
end;

procedure TPineParser.ParseStatementInto(ATarget: TPineNodeList);
begin
  ParseSingleStatement(ATarget);
  // Pine allows chaining simple statements on one physical/logical line
  // with commas, e.g. "a = f(x), b = g(y), c = a - b".
  while AcceptOp(',') do
    ParseSingleStatement(ATarget);
end;

procedure TPineParser.ParseSingleStatement(ATarget: TPineNodeList);
var
  LToken: TToken;
  LVarKind: TVarKind;
  LName, LOp: string;
  LDecl: TVarDeclNode;
  LAssign: TAssignNode;
  LStmt: TExprStmtNode;
  LFunc: TFuncDeclNode;
  LNode: TPineNode;
  LBinary: TBinaryNode;
  LLeftIdent: TIdentNode;
  LSave: Integer;
begin
  LToken := Cur;
  // break / continue
  if AtKeyword('break') then
  begin
    Inc(FPos);
    LNode := TBreakNode.Create;
    Attach(LNode, LToken);
    ATarget.Add(LNode);
    Exit;
  end;
  if AtKeyword('continue') then
  begin
    Inc(FPos);
    LNode := TContinueNode.Create;
    Attach(LNode, LToken);
    ATarget.Add(LNode);
    Exit;
  end;
  if AtKeyword('if') then
  begin
    ATarget.Add(ParseIf);
    Exit;
  end;
  if AtKeyword('for') then
  begin
    ATarget.Add(ParseFor);
    Exit;
  end;
  if AtKeyword('while') then
  begin
    ATarget.Add(ParseWhile);
    Exit;
  end;
  // tuple declaration: [a, b] = expr (but a bare "[a, b]" with no '=' after
  // it is a tuple/array EXPRESSION - e.g. a function's implicit return
  // value - and falls through to the plain expression statement below)
  if AtOp('[') and IsTupleDeclAhead then
  begin
    ATarget.Add(ParseTupleDecl);
    Exit;
  end;
  // function declaration: name(a, b) => ...
  LSave := FPos;
  LFunc := TryParseFuncDecl;
  if LFunc <> nil then
  begin
    FProgram.Functions.AddOrSetValue(LFunc.Name, LFunc);
    ATarget.Add(LFunc);
    Exit;
  end;
  FPos := LSave;
  // var / varip declaration
  LVarKind := vkPlain;
  if AcceptKeyword('var') then
    LVarKind := vkVar
  else if AcceptKeyword('varip') then
    LVarKind := vkVarIp;
  // optional type annotation, e.g. "float x = 1.0"
  if (Cur.Kind = tkIdent) and IsTypeName(Cur.Text) and (Peek(1).Kind = tkIdent) then
    Inc(FPos);
  if (Cur.Kind = tkIdent) and (Peek(1).Kind = tkOp) and (Peek(1).Text = '=') then
  begin
    LName := Cur.Text;
    Inc(FPos, 2);
    LDecl := TVarDeclNode.Create;
    Attach(LDecl, LToken);
    LDecl.Name := LName;
    LDecl.VarKind := LVarKind;
    LDecl.Expr := ParseExpression;
    ATarget.Add(LDecl);
    Exit;
  end;
  if LVarKind <> vkPlain then
    raise EPineSyntaxError.CreateFmt('Invalid declaration at line %d', [LToken.Line]);
  // assignment with :=
  if (Cur.Kind = tkIdent) and (Peek(1).Kind = tkOp) and (Peek(1).Text = ':=') then
  begin
    LName := Cur.Text;
    Inc(FPos, 2);
    LAssign := TAssignNode.Create;
    Attach(LAssign, LToken);
    LAssign.Name := LName;
    LAssign.Expr := ParseExpression;
    ATarget.Add(LAssign);
    Exit;
  end;
  // compound assignment: x += e is sugar for x := x + e (likewise -= *= /= %=)
  if (Cur.Kind = tkIdent) and (Peek(1).Kind = tkOp) and
    ((Peek(1).Text = '+=') or (Peek(1).Text = '-=') or (Peek(1).Text = '*=') or
    (Peek(1).Text = '/=') or (Peek(1).Text = '%=')) then
  begin
    LName := Cur.Text;
    LOp := Copy(Peek(1).Text, 1, 1);
    Inc(FPos, 2);
    LBinary := TBinaryNode.Create;
    try
      Attach(LBinary, LToken);
      LBinary.Op := LOp;
      LLeftIdent := TIdentNode.Create(LName);
      Attach(LLeftIdent, LToken);
      LBinary.Left := LLeftIdent;
      LBinary.Right := ParseExpression;
    except
      LBinary.Free;
      raise;
    end;
    LAssign := TAssignNode.Create;
    Attach(LAssign, LToken);
    LAssign.Name := LName;
    LAssign.Expr := LBinary;
    ATarget.Add(LAssign);
    Exit;
  end;
  // plain expression statement (plot(...), a function call, ...)
  LStmt := TExprStmtNode.Create;
  Attach(LStmt, LToken);
  try
    LStmt.Expr := ParseExpression;
  except
    LStmt.Free;
    raise;
  end;
  ATarget.Add(LStmt);
end;

function TPineParser.ParseTupleDecl: TTupleDeclNode;
var
  LToken: TToken;
  LNames: TArray<string>;
begin
  LToken := Cur;
  ExpectOp('[');
  SetLength(LNames, 0);
  repeat
    if Cur.Kind <> tkIdent then
      raise EPineSyntaxError.CreateFmt('Identifier expected at line %d', [Cur.Line]);
    SetLength(LNames, Length(LNames) + 1);
    LNames[High(LNames)] := Cur.Text;
    Inc(FPos);
  until not AcceptOp(',');
  ExpectOp(']');
  ExpectOp('=');
  Result := TTupleDeclNode.Create;
  Attach(Result, LToken);
  Result.Names := LNames;
  Result.Expr := ParseExpression;
end;

function TPineParser.TryParseFuncDecl: TFuncDeclNode;
var
  LToken: TToken;
  LName: string;
  LParams: TArray<string>;
  LDefaults: TArray<TPineNode>;
  LDepth, LScan, I: Integer;
  LFound: Boolean;
begin
  Result := nil;
  if (Cur.Kind <> tkIdent) or not((Peek(1).Kind = tkOp) and (Peek(1).Text = '(')) then
    Exit;
  // look ahead for the "=>" that follows the parameter list
  LScan := FPos + 1;
  LDepth := 0;
  LFound := False;
  while LScan < Length(FTokens) do
  begin
    if FTokens[LScan].Kind in [tkNewLine, tkEOF] then
      Break;
    if FTokens[LScan].Kind = tkOp then
    begin
      if (FTokens[LScan].Text = '(') or (FTokens[LScan].Text = '[') then
        Inc(LDepth)
      else if (FTokens[LScan].Text = ')') or (FTokens[LScan].Text = ']') then
      begin
        Dec(LDepth);
        if LDepth = 0 then
        begin
          LFound := (FTokens[LScan + 1].Kind = tkOp) and (FTokens[LScan + 1].Text = '=>');
          Break;
        end;
      end;
    end;
    Inc(LScan);
  end;
  if not LFound then
    Exit;
  LToken := Cur;
  LName := Cur.Text;
  Inc(FPos);
  ExpectOp('(');
  SetLength(LParams, 0);
  SetLength(LDefaults, 0);
  try
    if not AtOp(')') then
      repeat
        // optional type qualifier before a parameter name
        if (Cur.Kind = tkIdent) and IsTypeName(Cur.Text) and (Peek(1).Kind = tkIdent) then
          Inc(FPos);
        if Cur.Kind <> tkIdent then
          raise EPineSyntaxError.CreateFmt('Parameter name expected at line %d', [Cur.Line]);
        SetLength(LParams, Length(LParams) + 1);
        SetLength(LDefaults, Length(LDefaults) + 1);
        LParams[High(LParams)] := Cur.Text;
        LDefaults[High(LDefaults)] := nil;
        Inc(FPos);
        // optional default value: f(a, b = 10)
        if AcceptOp('=') then
          LDefaults[High(LDefaults)] := ParseExpression;
      until not AcceptOp(',');
    ExpectOp(')');
    ExpectOp('=>');
  except
    // the default expressions aren't owned by any node yet - free them
    for I := 0 to High(LDefaults) do
      LDefaults[I].Free;
    raise;
  end;
  Result := TFuncDeclNode.Create;
  try
    Attach(Result, LToken);
    Result.Name := LName;
    Result.Params := LParams;
    Result.Defaults := LDefaults; // ownership passes to the node
    if Cur.Kind = tkNewLine then
    begin
      Result.Body.Free;
      Result.Body := ParseBlock;
    end
    else
      ParseStatementInto(Result.Body);
  except
    Result.Free;
    raise;
  end;
end;

{ True if the '[' at FPos begins "[a, b, ...] =" - a tuple DECLARATION -
  rather than a bare tuple/array expression such as the implicit return
  value "[a, b]" on the last line of a function body. The closing ']' of
  the outermost bracket pair decides: a tuple declaration is followed by a
  single '='. }
function TPineParser.IsTupleDeclAhead: Boolean;
var
  LScan, LDepth: Integer;
begin
  Result := False;
  LScan := FPos;
  LDepth := 0;
  while LScan < Length(FTokens) do
  begin
    if FTokens[LScan].Kind in [tkNewLine, tkEOF] then
      Exit(False);
    if FTokens[LScan].Kind = tkOp then
    begin
      if (FTokens[LScan].Text = '(') or (FTokens[LScan].Text = '[') then
        Inc(LDepth)
      else if (FTokens[LScan].Text = ')') or (FTokens[LScan].Text = ']') then
      begin
        Dec(LDepth);
        if LDepth = 0 then
        begin
          Result := (LScan + 1 < Length(FTokens)) and
            (FTokens[LScan + 1].Kind = tkOp) and (FTokens[LScan + 1].Text = '=');
          Exit;
        end;
      end;
    end;
    Inc(LScan);
  end;
end;

(* switch [subject] NEWLINE INDENT { pattern => body } DEDENT
  A case without a pattern ("=> body") is the default case. Each body is
  either a single statement on the same line as the arrow or an indented
  block on the following lines. *)
function TPineParser.ParseSwitch: TSwitchNode;
var
  LToken: TToken;
  LPattern: TPineNode;
  LBody: TPineNodeList;
begin
  LToken := Cur;
  AcceptKeyword('switch');
  Result := TSwitchNode.Create;
  try
    Attach(Result, LToken);
    if Cur.Kind <> tkNewLine then
      Result.Subject := ParseExpression;
    if Cur.Kind = tkNewLine then
    begin
      SkipNewLines;
      if Cur.Kind <> tkIndent then
        raise EPineSyntaxError.CreateFmt('Indented switch cases expected at line %d',
          [Cur.Line]);
      Inc(FPos); // consume INDENT
      while not(Cur.Kind in [tkDedent, tkEOF]) do
      begin
        if Cur.Kind = tkNewLine then
        begin
          Inc(FPos);
          Continue;
        end;
        LPattern := nil;
        LBody := nil;
        try
          if not AtOp('=>') then
            LPattern := ParseExpression;
          if not AcceptOp('=>') then
            raise EPineSyntaxError.CreateFmt('"=>" expected in switch case at line %d',
              [Cur.Line]);
          if Cur.Kind = tkNewLine then
            LBody := ParseBlock
          else
          begin
            LBody := TPineNodeList.Create(True);
            ParseStatementInto(LBody);
          end;
        except
          // neither is owned by the switch node until AddCase succeeds
          LPattern.Free;
          LBody.Free;
          raise;
        end;
        Result.AddCase(LPattern, LBody);
      end;
      if Cur.Kind = tkDedent then
        Inc(FPos);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TPineParser.ParseIf: TIfNode;
var
  LToken: TToken;
  LElse: TIfNode;
begin
  LToken := Cur;
  if not AcceptKeyword('if') then
    raise EPineSyntaxError.CreateFmt('"if" expected at line %d', [Cur.Line]);
  Result := TIfNode.Create;
  try
    Attach(Result, LToken);
    Result.Cond := ParseExpression;
    Result.ThenBody.Free;
    Result.ThenBody := ParseBlock;
    SkipNewLines;
    if AtKeyword('else') then
    begin
      Inc(FPos);
      if AtKeyword('if') then
      begin
        LElse := ParseIf;
        Result.ElseBody := TPineNodeList.Create(True);
        Result.ElseBody.Add(LElse);
      end
      else
        Result.ElseBody := ParseBlock;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TPineParser.ParseFor: TForNode;
var
  LToken: TToken;
begin
  LToken := Cur;
  AcceptKeyword('for');
  Result := TForNode.Create;
  try
    Attach(Result, LToken);
    if Cur.Kind <> tkIdent then
      raise EPineSyntaxError.CreateFmt('Loop variable expected at line %d', [Cur.Line]);
    Result.VarName := Cur.Text;
    Inc(FPos);
    ExpectOp('=');
    Result.FromExpr := ParseExpression;
    if not AcceptKeyword('to') then
      raise EPineSyntaxError.CreateFmt('"to" expected at line %d', [Cur.Line]);
    Result.ToExpr := ParseExpression;
    if AcceptKeyword('by') then
      Result.StepExpr := ParseExpression;
    Result.Body.Free;
    Result.Body := ParseBlock;
  except
    Result.Free;
    raise;
  end;
end;

function TPineParser.ParseWhile: TWhileNode;
var
  LToken: TToken;
begin
  LToken := Cur;
  AcceptKeyword('while');
  Result := TWhileNode.Create;
  try
    Attach(Result, LToken);
    Result.Cond := ParseExpression;
    Result.Body.Free;
    Result.Body := ParseBlock;
  except
    Result.Free;
    raise;
  end;
end;

function TPineParser.ParseExpression: TPineNode;
begin
  Result := ParseTernary;
end;

function TPineParser.ParseTernary: TPineNode;
var
  LNode: TTernaryNode;
  LToken: TToken;
  LCond: TPineNode;
begin
  LToken := Cur;
  LCond := ParseOr;
  if AtOp('?') then
  begin
    Inc(FPos);
    LNode := TTernaryNode.Create;
    Attach(LNode, LToken);
    LNode.Cond := LCond;
    try
      LNode.ThenExpr := ParseExpression;
      ExpectOp(':');
      LNode.ElseExpr := ParseExpression;
    except
      LNode.Free;
      raise;
    end;
    Result := LNode;
  end
  else
    Result := LCond;
end;

function TPineParser.ParseOr: TPineNode;
var
  LNode: TBinaryNode;
  LToken: TToken;
begin
  Result := ParseAnd;
  while AtKeyword('or') do
  begin
    LToken := Cur;
    Inc(FPos);
    LNode := TBinaryNode.Create;
    Attach(LNode, LToken);
    LNode.Op := 'or';
    LNode.Left := Result;
    LNode.Right := ParseAnd;
    Result := LNode;
  end;
end;

function TPineParser.ParseAnd: TPineNode;
var
  LNode: TBinaryNode;
  LToken: TToken;
begin
  Result := ParseComparison;
  while AtKeyword('and') do
  begin
    LToken := Cur;
    Inc(FPos);
    LNode := TBinaryNode.Create;
    Attach(LNode, LToken);
    LNode.Op := 'and';
    LNode.Left := Result;
    LNode.Right := ParseComparison;
    Result := LNode;
  end;
end;

function TPineParser.ParseComparison: TPineNode;
var
  LNode: TBinaryNode;
  LToken: TToken;
  LOp: string;
begin
  Result := ParseAdditive;
  while (Cur.Kind = tkOp) and ((Cur.Text = '==') or (Cur.Text = '!=') or
    (Cur.Text = '<') or (Cur.Text = '<=') or (Cur.Text = '>') or (Cur.Text = '>=')) do
  begin
    LToken := Cur;
    LOp := Cur.Text;
    Inc(FPos);
    LNode := TBinaryNode.Create;
    Attach(LNode, LToken);
    LNode.Op := LOp;
    LNode.Left := Result;
    LNode.Right := ParseAdditive;
    Result := LNode;
  end;
end;

function TPineParser.ParseAdditive: TPineNode;
var
  LNode: TBinaryNode;
  LToken: TToken;
  LOp: string;
begin
  Result := ParseMultiplicative;
  while (Cur.Kind = tkOp) and ((Cur.Text = '+') or (Cur.Text = '-')) do
  begin
    LToken := Cur;
    LOp := Cur.Text;
    Inc(FPos);
    LNode := TBinaryNode.Create;
    Attach(LNode, LToken);
    LNode.Op := LOp;
    LNode.Left := Result;
    LNode.Right := ParseMultiplicative;
    Result := LNode;
  end;
end;

function TPineParser.ParseMultiplicative: TPineNode;
var
  LNode: TBinaryNode;
  LToken: TToken;
  LOp: string;
begin
  Result := ParseUnary;
  while (Cur.Kind = tkOp) and ((Cur.Text = '*') or (Cur.Text = '/') or (Cur.Text = '%')) do
  begin
    LToken := Cur;
    LOp := Cur.Text;
    Inc(FPos);
    LNode := TBinaryNode.Create;
    Attach(LNode, LToken);
    LNode.Op := LOp;
    LNode.Left := Result;
    LNode.Right := ParseUnary;
    Result := LNode;
  end;
end;

function TPineParser.ParseUnary: TPineNode;
var
  LNode: TUnaryNode;
  LToken: TToken;
  LOp: string;
begin
  LToken := Cur;
  if AtKeyword('not') or AtOp('-') or AtOp('+') then
  begin
    if Cur.Kind = tkKeyword then
      LOp := 'not'
    else
      LOp := Cur.Text;
    Inc(FPos);
    LNode := TUnaryNode.Create;
    Attach(LNode, LToken);
    LNode.Op := LOp;
    LNode.Operand := ParseUnary;
    Result := LNode;
  end
  else
    Result := ParsePostfix;
end;

function TPineParser.ParsePostfix: TPineNode;
var
  LHistory: THistoryNode;
  LCall: TCallNode;
  LMethodCall: TMethodCallNode;
  LToken: TToken;
  LMethodName, LArgName: string;
begin
  Result := ParsePrimary;
  while True do
  begin
    LToken := Cur;
    if AtOp('(') then
    begin
      if not(Result is TIdentNode) then
        raise EPineSyntaxError.CreateFmt('Only named functions can be called (line %d)',
          [LToken.Line]);
      LCall := TCallNode.Create;
      Attach(LCall, LToken);
      LCall.Name := TIdentNode(Result).Name;
      Result.Free;
      Result := LCall;
      ParseCallArgs(LCall);
    end
    else if AtOp('[') then
    begin
      Inc(FPos);
      LHistory := THistoryNode.Create;
      Attach(LHistory, LToken);
      LHistory.Base := Result;
      LHistory.Offset := ParseExpression;
      ExpectOp(']');
      Result := LHistory;
    end
    else if AtOp('.') and (Peek(1).Kind in [tkIdent, tkKeyword]) and
      (Peek(2).Kind = tkOp) and (Peek(2).Text = '(') then
    begin
      // method-call syntax: base.method(args). By this point Result can
      // only be a plain variable/expression - a namespace-qualified name
      // (ta.sma, shape.labeldown, ...) was already fully consumed as one
      // identifier back in ParsePrimary, so a further '.' here always
      // means a method call, never more of a qualified name.
      LMethodName := Peek(1).Text;
      Inc(FPos, 2);
      LMethodCall := TMethodCallNode.Create;
      Attach(LMethodCall, LToken);
      LMethodCall.Base := Result;
      LMethodCall.Method := LMethodName;
      Result := LMethodCall;
      ExpectOp('(');
      if not AtOp(')') then
        repeat
          LArgName := '';
          if (Cur.Kind = tkIdent) and (Peek(1).Kind = tkOp) and (Peek(1).Text = '=') then
          begin
            LArgName := Cur.Text;
            Inc(FPos, 2);
          end;
          LMethodCall.AddArg(LArgName, ParseExpression);
        until not AcceptOp(',');
      ExpectOp(')');
    end
    else
      Break;
  end;
end;

function TPineParser.ParseCallArgs(ACall: TCallNode): Boolean;
var
  LName: string;
begin
  ExpectOp('(');
  if not AtOp(')') then
    repeat
      LName := '';
      if (Cur.Kind = tkIdent) and (Peek(1).Kind = tkOp) and (Peek(1).Text = '=') then
      begin
        LName := Cur.Text;
        Inc(FPos, 2);
      end;
      ACall.AddArg(LName, ParseExpression);
    until not AcceptOp(',');
  ExpectOp(')');
  Result := True;
end;

function TPineParser.ParsePrimary: TPineNode;
var
  LToken: TToken;
  LName: string;
  LIdent: TIdentNode;
  LArrayLit: TArrayLiteralNode;
begin
  LToken := Cur;
  case LToken.Kind of
    tkNumber:
      begin
        Inc(FPos);
        Result := TLiteralNode.Create(PineFloat(LToken.Num));
        Attach(Result, LToken);
        Exit;
      end;
    tkString:
      begin
        Inc(FPos);
        Result := TLiteralNode.Create(PineString(LToken.Text));
        Attach(Result, LToken);
        Exit;
      end;
    tkColor:
      begin
        Inc(FPos);
        Result := TLiteralNode.Create(PineColorValue(Cardinal(Trunc(LToken.Num))));
        Attach(Result, LToken);
        Exit;
      end;
    tkKeyword:
      begin
        if LToken.Text = 'true' then
        begin
          Inc(FPos);
          Result := TLiteralNode.Create(PineBool(True));
          Attach(Result, LToken);
          Exit;
        end;
        if LToken.Text = 'false' then
        begin
          Inc(FPos);
          Result := TLiteralNode.Create(PineBool(False));
          Attach(Result, LToken);
          Exit;
        end;
        if LToken.Text = 'na' then
        begin
          // na(x) is a function call (checks x for na-ness), but bare `na`
          // is the na literal - peek ahead to tell them apart.
          if (Peek(1).Kind = tkOp) and (Peek(1).Text = '(') then
          begin
            Inc(FPos);
            LIdent := TIdentNode.Create('na');
            Attach(LIdent, LToken);
            Result := LIdent;
            Exit;
          end;
          Inc(FPos);
          Result := TLiteralNode.Create(PineNA);
          Attach(Result, LToken);
          Exit;
        end;
        if LToken.Text = 'if' then
        begin
          // `if` used as an expression: x = if cond ...
          Result := ParseIf;
          Exit;
        end;
        if LToken.Text = 'switch' then
        begin
          Result := ParseSwitch;
          Exit;
        end;
      end;
    tkIdent:
      begin
        LName := LToken.Text;
        Inc(FPos);
        // Qualified names such as ta.sma or color.red become a single
        // identifier - but only when the FIRST segment is a known
        // built-in namespace. Anything else is a plain variable; a
        // trailing ".method(...)" on it is method-call syntax, handled by
        // ParsePostfix instead (see IsNamespace).
        if IsNamespace(LName) then
          while AtOp('.') and (Peek(1).Kind in [tkIdent, tkKeyword]) do
          begin
            LName := LName + '.' + Peek(1).Text;
            Inc(FPos, 2);
          end;
        LIdent := TIdentNode.Create(LName);
        Attach(LIdent, LToken);
        Result := LIdent;
        Exit;
      end;
    tkOp:
      begin
        if LToken.Text = '(' then
        begin
          Inc(FPos);
          Result := ParseExpression;
          ExpectOp(')');
          Exit;
        end;
        if LToken.Text = '[' then
        begin
          // array literal: [expr, expr, ...] - e.g. the options= argument
          // of input(). Distinct from a tuple declaration ([a, b] = expr),
          // which is only recognized at the start of a statement.
          Inc(FPos);
          LArrayLit := TArrayLiteralNode.Create;
          Attach(LArrayLit, LToken);
          try
            if not AtOp(']') then
              repeat
                LArrayLit.Items.Add(ParseExpression);
              until not AcceptOp(',');
            ExpectOp(']');
          except
            LArrayLit.Free;
            raise;
          end;
          Result := LArrayLit;
          Exit;
        end;
      end;
  end;
  raise EPineSyntaxError.CreateFmt('Unexpected token "%s" at line %d',
    [LToken.Describe, LToken.Line]);
end;

end.
