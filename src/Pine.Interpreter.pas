unit Pine.Interpreter;

{ Tree walking interpreter.

  The script is executed once per bar, exactly like Pine does on the chart.
  Global variables keep a full history (TPineSeries) so that x[1] works,
  built-in indicators keep their state in the call site bound TCallState. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Math, Generics.Collections,
  Pine.Types, Pine.Runtime, Pine.Ast, Pine.Parser, Pine.Builtins;

type
  EPineBreak = class(EPineError);
  EPineContinue = class(EPineError);

  { One lexical scope. Function bodies and loops push a frame. }
  TPineFrame = class
  public
    Vars: TDictionary<string, TPineValue>;
    IsFunction: Boolean;
    constructor Create(AIsFunction: Boolean);
    destructor Destroy; override;
  end;

  TPineInterpreter = class
  private
    FProgram: TPineProgram;
    FContext: TPineContext;
    FFrames: TObjectList<TPineFrame>;
    FCallDepth: Integer;
    function InFunction: Boolean;
    function TryReadLocal(const AName: string; out AValue: TPineValue): Boolean;
    function TryWriteLocal(const AName: string; const AValue: TPineValue): Boolean;
    procedure DeclareVariable(const AName: string; const AValue: TPineValue;
      ASiteId: Integer);
    function EvalBinary(ANode: TBinaryNode): TPineValue;
    function EvalCall(ANode: TCallNode): TPineValue;
    function EvalHistory(ANode: THistoryNode): TPineValue;
    function EvalArrayLiteral(ANode: TArrayLiteralNode): TPineValue;
    function EvalMethodCall(ANode: TMethodCallNode): TPineValue;
    function EvalSwitch(ANode: TSwitchNode): TPineValue;
    function CallUserFunction(AFunc: TFuncDeclNode; AArgs: TPineArgs): TPineValue;
    function ExecStatementCore(ANode: TPineNode): TPineValue;
    function ExecFor(ANode: TForNode): TPineValue;
    function ExecWhile(ANode: TWhileNode): TPineValue;
  public
    constructor Create(AProgram: TPineProgram; AContext: TPineContext);
    destructor Destroy; override;
    function Eval(ANode: TPineNode): TPineValue;
    function ExecStatement(ANode: TPineNode): TPineValue;
    function ExecBlock(ABlock: TPineNodeList): TPineValue;
    { Runs the whole script over every bar of the data set. }
    procedure Run;
    property Context: TPineContext read FContext;
  end;

{ Convenience: compile and run a script, the caller owns the returned context.
  AInputOverrides, if given, is a title -> value map applied via
  TPineContext.SetInputOverride before the script runs; the caller keeps
  ownership of the dictionary. }
function RunPineScript(const ASource: string; ABars: TPineBarSet;
  AInputOverrides: TDictionary<string, TPineValue> = nil): TPineContext;

implementation

{ Records on an error which script line it came from, unless something deeper
  in the call stack already did (the innermost line is the useful one).
  break/continue are control flow riding on the same exception class, not
  errors, so they are left alone. }
procedure StampLine(E: EPineError; ALine: Integer);
begin
  if (E.Line = 0) and not ((E is EPineBreak) or (E is EPineContinue)) then
    E.Line := ALine;
end;

{ Turns any foreign exception (a Delphi/RTL one such as EConvertError or
  EInvalidOp, i.e. a bug or an unforeseen input rather than a deliberate
  interpreter error) into a runtime error that carries the script line. }
function WrapException(E: Exception; ALine: Integer): EPineRuntimeError;
begin
  Result := EPineRuntimeError.CreateFmt('%s: %s', [E.ClassName, E.Message]);
  Result.Line := ALine;
end;

const
  CMaxLoopIterations = 1000000;
  CMaxCallDepth = 64;

function RunPineScript(const ASource: string; ABars: TPineBarSet;
  AInputOverrides: TDictionary<string, TPineValue>): TPineContext;
var
  LProgram: TPineProgram;
  LInterp: TPineInterpreter;
  LPair: TPair<string, TPineValue>;
begin
  Result := TPineContext.Create(ABars);
  try
    if AInputOverrides <> nil then
      for LPair in AInputOverrides do
        Result.SetInputOverride(LPair.Key, LPair.Value);
    LProgram := CompilePine(ASource);
    try
      LInterp := TPineInterpreter.Create(LProgram, Result);
      try
        LInterp.Run;
      finally
        LInterp.Free;
      end;
    finally
      LProgram.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ TPineFrame }

constructor TPineFrame.Create(AIsFunction: Boolean);
begin
  inherited Create;
  Vars := TDictionary<string, TPineValue>.Create;
  IsFunction := AIsFunction;
end;

destructor TPineFrame.Destroy;
begin
  Vars.Free;
  inherited Destroy;
end;

{ TPineInterpreter }

constructor TPineInterpreter.Create(AProgram: TPineProgram; AContext: TPineContext);
begin
  inherited Create;
  FProgram := AProgram;
  FContext := AContext;
  FFrames := TObjectList<TPineFrame>.Create(True);
end;

destructor TPineInterpreter.Destroy;
begin
  FFrames.Free;
  inherited Destroy;
end;

function TPineInterpreter.InFunction: Boolean;
var
  I: Integer;
begin
  for I := 0 to FFrames.Count - 1 do
    if FFrames[I].IsFunction then
      Exit(True);
  Result := False;
end;

function TPineInterpreter.TryReadLocal(const AName: string; out AValue: TPineValue): Boolean;
var
  I: Integer;
begin
  for I := FFrames.Count - 1 downto 0 do
    if FFrames[I].Vars.TryGetValue(AName, AValue) then
      Exit(True);
  Result := False;
end;

function TPineInterpreter.TryWriteLocal(const AName: string;
  const AValue: TPineValue): Boolean;
var
  I: Integer;
begin
  for I := FFrames.Count - 1 downto 0 do
    if FFrames[I].Vars.ContainsKey(AName) then
    begin
      FFrames[I].Vars[AName] := AValue;
      Exit(True);
    end;
  Result := False;
end;

procedure TPineInterpreter.DeclareVariable(const AName: string;
  const AValue: TPineValue; ASiteId: Integer);
begin
  if InFunction then
    FFrames[FFrames.Count - 1].Vars.AddOrSetValue(AName, AValue)
  else
    FContext.Series(AName).SetAt(FContext.BarIndex, AValue);
end;

procedure TPineInterpreter.Run;
var
  I: Integer;
begin
  for I := 0 to FContext.Bars.Count - 1 do
  begin
    FContext.BarIndex := I;
    FFrames.Clear;
    ExecBlock(FProgram.Body);
  end;
end;

function TPineInterpreter.ExecBlock(ABlock: TPineNodeList): TPineValue;
var
  I: Integer;
begin
  Result := PineNA;
  for I := 0 to ABlock.Count - 1 do
    Result := ExecStatement(ABlock[I]);
end;

function TPineInterpreter.ExecStatement(ANode: TPineNode): TPineValue;
begin
  try
    Result := ExecStatementCore(ANode);
  except
    on E: EPineError do
    begin
      StampLine(E, ANode.Line);
      raise;
    end;
    on E: Exception do
      raise WrapException(E, ANode.Line);
  end;
end;

function TPineInterpreter.ExecStatementCore(ANode: TPineNode): TPineValue;
var
  LDecl: TVarDeclNode;
  LTuple: TTupleDeclNode;
  LAssign: TAssignNode;
  LValue: TPineValue;
  LSeries: TPineSeries;
  LState: TCallState;
  I: Integer;
begin
  Result := PineNA;
  if ANode is TFuncDeclNode then
    Exit; // function declarations are handled at parse time

  if ANode is TVarDeclNode then
  begin
    LDecl := TVarDeclNode(ANode);
    if LDecl.VarKind in [vkVar, vkVarIp] then
    begin
      LState := FContext.State(LDecl.SiteId);
      LValue := PineNA;
      if not LState.Flags[0] then
      begin
        LState.Flags[0] := True;
        LValue := Eval(LDecl.Expr);
      end
      else if InFunction then
        TryReadLocal(LDecl.Name, LValue)
      else
        LValue := FContext.Series(LDecl.Name).History(FContext.BarIndex, 1);
      DeclareVariable(LDecl.Name, LValue, LDecl.SiteId);
      Exit(LValue);
    end;
    LValue := Eval(LDecl.Expr);
    DeclareVariable(LDecl.Name, LValue, LDecl.SiteId);
    Exit(LValue);
  end;

  if ANode is TTupleDeclNode then
  begin
    LTuple := TTupleDeclNode(ANode);
    LValue := Eval(LTuple.Expr);
    for I := 0 to High(LTuple.Names) do
    begin
      if (LValue.Kind = pvkTuple) and (I <= High(LValue.Items)) then
        DeclareVariable(LTuple.Names[I], LValue.Items[I], LTuple.SiteId)
      else
        DeclareVariable(LTuple.Names[I], PineNA, LTuple.SiteId);
    end;
    Exit(LValue);
  end;

  if ANode is TAssignNode then
  begin
    LAssign := TAssignNode(ANode);
    LValue := Eval(LAssign.Expr);
    if not TryWriteLocal(LAssign.Name, LValue) then
    begin
      if not FContext.HasSeries(LAssign.Name) then
        raise EPineRuntimeError.CreateFmt(
          'Undeclared identifier "%s" at line %d', [LAssign.Name, LAssign.Line]);
      LSeries := FContext.Series(LAssign.Name);
      LSeries.SetAt(FContext.BarIndex, LValue);
    end;
    Exit(LValue);
  end;

  if ANode is TExprStmtNode then
    Exit(Eval(TExprStmtNode(ANode).Expr));

  if ANode is TIfNode then
    Exit(Eval(ANode));

  if ANode is TForNode then
    Exit(ExecFor(TForNode(ANode)));

  if ANode is TWhileNode then
    Exit(ExecWhile(TWhileNode(ANode)));

  if ANode is TBreakNode then
    raise EPineBreak.Create('break');

  if ANode is TContinueNode then
    raise EPineContinue.Create('continue');

  // any other node is an expression used as a statement
  Result := Eval(ANode);
end;

function TPineInterpreter.ExecFor(ANode: TForNode): TPineValue;
var
  LFrom, LTo, LStep, LIndex: Double;
  LFrame: TPineFrame;
  LCount: Integer;
  LStop: Boolean;
begin
  Result := PineNA;
  LFrom := Eval(ANode.FromExpr).AsFloat;
  LTo := Eval(ANode.ToExpr).AsFloat;
  if ANode.StepExpr <> nil then
    LStep := Abs(Eval(ANode.StepExpr).AsFloat)
  else
    LStep := 1;
  if (LStep = 0) or IsNan(LFrom) or IsNan(LTo) or IsNan(LStep) then
    Exit;
  if LTo < LFrom then
    LStep := -LStep;
  LFrame := TPineFrame.Create(False);
  FFrames.Add(LFrame);
  try
    LIndex := LFrom;
    LCount := 0;
    LStop := False;
    while ((LStep > 0) and (LIndex <= LTo)) or ((LStep < 0) and (LIndex >= LTo)) do
    begin
      LFrame.Vars.AddOrSetValue(ANode.VarName, PineFloat(LIndex));
      try
        Result := ExecBlock(ANode.Body);
      except
        on EPineBreak do
          LStop := True;
        on EPineContinue do
          ; // continue with the next iteration
      end;
      if LStop then
        Break;
      LIndex := LIndex + LStep;
      Inc(LCount);
      if LCount > CMaxLoopIterations then
        raise EPineRuntimeError.CreateFmt('Loop limit exceeded at line %d', [ANode.Line]);
    end;
  finally
    FFrames.Remove(LFrame);
  end;
end;

function TPineInterpreter.ExecWhile(ANode: TWhileNode): TPineValue;
var
  LFrame: TPineFrame;
  LCount: Integer;
  LStop: Boolean;
begin
  Result := PineNA;
  LFrame := TPineFrame.Create(False);
  FFrames.Add(LFrame);
  try
    LCount := 0;
    LStop := False;
    while Eval(ANode.Cond).AsBool do
    begin
      try
        Result := ExecBlock(ANode.Body);
      except
        on EPineBreak do
          LStop := True;
        on EPineContinue do
          ;
      end;
      if LStop then
        Break;
      Inc(LCount);
      if LCount > CMaxLoopIterations then
        raise EPineRuntimeError.CreateFmt('Loop limit exceeded at line %d', [ANode.Line]);
    end;
  finally
    FFrames.Remove(LFrame);
  end;
end;

function TPineInterpreter.Eval(ANode: TPineNode): TPineValue;
var
  LIdent: TIdentNode;
  LUnary: TUnaryNode;
  LTernary: TTernaryNode;
  LIf: TIfNode;
  LThen, LElse: TPineValue;
  LFrame: TPineFrame;
begin
  if ANode = nil then
    Exit(PineNA);

  if ANode is TLiteralNode then
    Exit(TLiteralNode(ANode).Value);

  if ANode is TIdentNode then
  begin
    LIdent := TIdentNode(ANode);
    if TryReadLocal(LIdent.Name, Result) then
      Exit; // whatever SeriesTag the stored value carries rides along as-is
    if FContext.HasSeries(LIdent.Name) then
    begin
      Result := FContext.Series(LIdent.Name).GetAt(FContext.BarIndex);
      Result.SeriesTag := LIdent.Name;
      Exit;
    end;
    if TryBuiltinValue(FContext, LIdent.Name, Result) then
    begin
      Result.SeriesTag := LIdent.Name;
      Exit;
    end;
    raise EPineRuntimeError.CreateFmt('Undeclared identifier "%s" at line %d',
      [LIdent.Name, LIdent.Line]);
  end;

  if ANode is TUnaryNode then
  begin
    LUnary := TUnaryNode(ANode);
    Result := Eval(LUnary.Operand);
    if LUnary.Op = 'not' then
      Exit(PineBool(not Result.AsBool));
    if LUnary.Op = '-' then
    begin
      if Result.IsNA then
        Exit(PineNA);
      Exit(PineFloat(-Result.AsFloat));
    end;
    Exit(Result);
  end;

  if ANode is TBinaryNode then
    Exit(EvalBinary(TBinaryNode(ANode)));

  if ANode is TTernaryNode then
  begin
    LTernary := TTernaryNode(ANode);
    Result := Eval(LTernary.Cond);
    // both branches are evaluated so that stateful ta.* calls inside a
    // ternary keep receiving one value per bar, like in Pine
    LThen := Eval(LTernary.ThenExpr);
    LElse := Eval(LTernary.ElseExpr);
    if Result.AsBool then
      Exit(LThen)
    else
      Exit(LElse);
  end;

  if ANode is THistoryNode then
    Exit(EvalHistory(THistoryNode(ANode)));

  if ANode is TArrayLiteralNode then
    Exit(EvalArrayLiteral(TArrayLiteralNode(ANode)));

  if ANode is TMethodCallNode then
    Exit(EvalMethodCall(TMethodCallNode(ANode)));

  if ANode is TSwitchNode then
    Exit(EvalSwitch(TSwitchNode(ANode)));

  if ANode is TCallNode then
    Exit(EvalCall(TCallNode(ANode)));

  if ANode is TIfNode then
  begin
    LIf := TIfNode(ANode);
    LFrame := TPineFrame.Create(False);
    FFrames.Add(LFrame);
    try
      if Eval(LIf.Cond).AsBool then
        Result := ExecBlock(LIf.ThenBody)
      else if LIf.ElseBody <> nil then
        Result := ExecBlock(LIf.ElseBody)
      else
        Result := PineNA;
    finally
      FFrames.Remove(LFrame);
    end;
    Exit;
  end;

  if (ANode is TVarDeclNode) or (ANode is TAssignNode) or
    (ANode is TExprStmtNode) or (ANode is TTupleDeclNode) or
    (ANode is TForNode) or (ANode is TWhileNode) then
    Exit(ExecStatement(ANode));
  raise EPineRuntimeError.CreateFmt('Unsupported expression at line %d', [ANode.Line]);
end;

function TPineInterpreter.EvalBinary(ANode: TBinaryNode): TPineValue;
var
  L, R: TPineValue;
  A, B: Double;
begin
  L := Eval(ANode.Left);
  // logical operators keep the short circuit behaviour
  if ANode.Op = 'and' then
  begin
    if not L.AsBool then
      Exit(PineBool(False));
    Exit(PineBool(Eval(ANode.Right).AsBool));
  end;
  if ANode.Op = 'or' then
  begin
    if L.AsBool then
      Exit(PineBool(True));
    Exit(PineBool(Eval(ANode.Right).AsBool));
  end;
  R := Eval(ANode.Right);
  // string concatenation
  if (ANode.Op = '+') and ((L.Kind = pvkString) or (R.Kind = pvkString)) then
    Exit(PineString(L.AsString + R.AsString));
  if ANode.Op = '==' then
  begin
    if (L.Kind = pvkString) or (R.Kind = pvkString) then
      Exit(PineBool(L.AsString = R.AsString));
    if L.IsNA or R.IsNA then
      Exit(PineBool(L.IsNA and R.IsNA));
    Exit(PineBool(SameValue(L.AsFloat, R.AsFloat)));
  end;
  if ANode.Op = '!=' then
  begin
    if (L.Kind = pvkString) or (R.Kind = pvkString) then
      Exit(PineBool(L.AsString <> R.AsString));
    if L.IsNA or R.IsNA then
      Exit(PineBool(not(L.IsNA and R.IsNA)));
    Exit(PineBool(not SameValue(L.AsFloat, R.AsFloat)));
  end;
  A := L.AsFloat;
  B := R.AsFloat;
  // comparisons against na are false, arithmetic with na yields na
  if IsNan(A) or IsNan(B) then
  begin
    if (ANode.Op = '<') or (ANode.Op = '<=') or (ANode.Op = '>') or (ANode.Op = '>=') then
      Exit(PineBool(False));
    Exit(PineNA);
  end;
  if ANode.Op = '+' then
    Exit(PineFloat(A + B));
  if ANode.Op = '-' then
    Exit(PineFloat(A - B));
  if ANode.Op = '*' then
    Exit(PineFloat(A * B));
  if ANode.Op = '/' then
  begin
    if B = 0 then
      Exit(PineNA);
    Exit(PineFloat(A / B));
  end;
  if ANode.Op = '%' then
  begin
    if B = 0 then
      Exit(PineNA);
    Exit(PineFloat(A - B * Int(A / B)));
  end;
  if ANode.Op = '<' then
    Exit(PineBool(A < B));
  if ANode.Op = '<=' then
    Exit(PineBool(A <= B));
  if ANode.Op = '>' then
    Exit(PineBool(A > B));
  if ANode.Op = '>=' then
    Exit(PineBool(A >= B));
  raise EPineRuntimeError.CreateFmt('Unknown operator "%s" at line %d',
    [ANode.Op, ANode.Line]);
end;

function TPineInterpreter.EvalArrayLiteral(ANode: TArrayLiteralNode): TPineValue;
var
  LArr: TPineArrayObj;
  I: Integer;
begin
  LArr := TPineArrayObj.Create;
  FContext.TrackRef(LArr);
  for I := 0 to ANode.Items.Count - 1 do
    LArr.Items.Add(Eval(ANode.Items[I]));
  Result := PineRef(LArr);
end;

function TPineInterpreter.EvalHistory(ANode: THistoryNode): TPineValue;
var
  LOffset: Integer;
  LName: string;
  LBuffer: TPineBuffer;
  LValue: TPineValue;
begin
  LOffset := Eval(ANode.Offset).AsInt;
  if ANode.Base is TIdentNode then
  begin
    LName := TIdentNode(ANode.Base).Name;
    if TryReadLocal(LName, LValue) then
    begin
      if LOffset = 0 then
        Exit(LValue);
      { A local (typically a function parameter) bound from a global series
        or a built-in bar-data field - e.g. `f(src) => ... src[1] ...`
        called as f(rsi) - carries the name of that origin in SeriesTag
        (set when the value was first read as a plain identifier, and
        copied along through every local read and parameter pass since).
        Re-consult the ORIGINAL series/field for the lookback instead of
        the single value this local happened to capture. }
      if LValue.SeriesTag <> '' then
      begin
        if FContext.HasSeries(LValue.SeriesTag) then
          Exit(FContext.Series(LValue.SeriesTag).History(FContext.BarIndex, LOffset));
        if TryBuiltinHistory(FContext, LValue.SeriesTag, LOffset, Result) then
          Exit;
      end;
      raise EPineRuntimeError.CreateFmt(
        'History of the local variable "%s" is not available (line %d)',
        [LName, ANode.Line]);
    end;
    if FContext.HasSeries(LName) then
      Exit(FContext.Series(LName).History(FContext.BarIndex, LOffset));
    if TryBuiltinHistory(FContext, LName, LOffset, Result) then
      Exit;
    raise EPineRuntimeError.CreateFmt('Undeclared identifier "%s" at line %d',
      [LName, ANode.Line]);
  end;
  // history of an arbitrary expression: the value is recorded on every bar
  LBuffer := FContext.State(ANode.SiteId).Buffer(0);
  LBuffer.Push(FContext.BarIndex, Eval(ANode.Base).AsFloat);
  Result := PineFloat(LBuffer.Get(LOffset));
end;

function TPineInterpreter.EvalCall(ANode: TCallNode): TPineValue;
var
  LArgs: TPineArgs;
  LHandled: Boolean;
  LFunc: TFuncDeclNode;
  I: Integer;
begin
  LArgs := TPineArgs.Create;
  try
    try
      for I := 0 to High(ANode.Args) do
        LArgs.Add(ANode.Args[I].Name, Eval(ANode.Args[I].Expr));
      // user defined functions take precedence over built-ins
      if FProgram.Functions.TryGetValue(ANode.Name, LFunc) then
        Exit(CallUserFunction(LFunc, LArgs));
      Result := CallBuiltin(FContext, ANode.Name, ANode.SiteId, LArgs, LHandled);
      if not LHandled then
        raise EPineRuntimeError.CreateFmt('Unknown function "%s" at line %d',
          [ANode.Name, ANode.Line]);
    except
      // stamp the line of THIS call - more precise than the start of the
      // (possibly multi-line) statement around it
      on E: EPineError do
      begin
        StampLine(E, ANode.Line);
        raise;
      end;
      on E: Exception do
        raise WrapException(E, ANode.Line);
    end;
  finally
    LArgs.Free;
  end;
end;

function TPineInterpreter.EvalMethodCall(ANode: TMethodCallNode): TPineValue;
var
  LBaseValue: TPineValue;
  LNamespace: string;
  LArgs: TPineArgs;
  LHandled: Boolean;
  I: Integer;
begin
  LBaseValue := Eval(ANode.Base);
  // base.method(args) == namespace.method(base, args); the namespace is
  // inferred from the runtime type of the value base evaluated to, since
  // this interpreter has no static type system to know it ahead of time.
  if LBaseValue.Kind = pvkRef then
  begin
    if LBaseValue.Ref is TPineArrayObj then
      LNamespace := 'array'
    else if LBaseValue.Ref is TPineLineObj then
      LNamespace := 'line'
    else if LBaseValue.Ref is TPineLabelObj then
      LNamespace := 'label'
    else if LBaseValue.Ref is TPineBoxObj then
      LNamespace := 'box'
    else if LBaseValue.Ref is TPineTableObj then
      LNamespace := 'table'
    else
      LNamespace := '';
  end
  else if LBaseValue.Kind = pvkString then
    LNamespace := 'str'
  else
    LNamespace := '';
  if LNamespace = '' then
    raise EPineRuntimeError.CreateFmt(
      'Cannot call method "%s" on a value of type %s (line %d)',
      [ANode.Method, LBaseValue.KindName, ANode.Line]);
  LArgs := TPineArgs.Create;
  try
    try
      LArgs.Add('', LBaseValue); // the object itself is always the first argument
      for I := 0 to High(ANode.Args) do
        LArgs.Add(ANode.Args[I].Name, Eval(ANode.Args[I].Expr));
      Result := CallBuiltin(FContext, LNamespace + '.' + ANode.Method, ANode.SiteId,
        LArgs, LHandled);
      if not LHandled then
        raise EPineRuntimeError.CreateFmt('Unknown method "%s.%s" at line %d',
          [LNamespace, ANode.Method, ANode.Line]);
    except
      on E: EPineError do
      begin
        StampLine(E, ANode.Line);
        raise;
      end;
      on E: Exception do
        raise WrapException(E, ANode.Line);
    end;
  finally
    LArgs.Free;
  end;
end;

function TPineInterpreter.EvalSwitch(ANode: TSwitchNode): TPineValue;
var
  LSubjectValue, LPatternValue: TPineValue;
  LHasSubject, LMatched: Boolean;
  I: Integer;
  LFrame: TPineFrame;

  function ValuesMatch(const X, Y: TPineValue): Boolean;
  begin
    if X.IsNA or Y.IsNA then
      Exit(X.IsNA and Y.IsNA);
    if (X.Kind = pvkString) or (Y.Kind = pvkString) then
      Exit(X.AsString = Y.AsString);
    Result := SameValue(X.AsFloat, Y.AsFloat);
  end;

begin
  Result := PineNA;
  LHasSubject := ANode.Subject <> nil;
  if LHasSubject then
    LSubjectValue := Eval(ANode.Subject);
  for I := 0 to High(ANode.Cases) do
  begin
    if ANode.Cases[I].Pattern = nil then
      LMatched := True // the default/catch-all case
    else if LHasSubject then
    begin
      LPatternValue := Eval(ANode.Cases[I].Pattern);
      LMatched := ValuesMatch(LSubjectValue, LPatternValue);
    end
    else
      // subject-less form: each pattern is its own boolean condition
      LMatched := Eval(ANode.Cases[I].Pattern).AsBool;
    if LMatched then
    begin
      LFrame := TPineFrame.Create(False);
      FFrames.Add(LFrame);
      try
        Result := ExecBlock(ANode.Cases[I].Body);
      finally
        FFrames.Remove(LFrame);
      end;
      Exit;
    end;
  end;
end;

function TPineInterpreter.CallUserFunction(AFunc: TFuncDeclNode;
  AArgs: TPineArgs): TPineValue;
var
  LFrame: TPineFrame;
  I: Integer;
begin
  if FCallDepth >= CMaxCallDepth then
    raise EPineRuntimeError.CreateFmt('Call stack overflow in "%s"', [AFunc.Name]);
  Inc(FCallDepth);
  LFrame := TPineFrame.Create(True);
  FFrames.Add(LFrame);
  try
    for I := 0 to High(AFunc.Params) do
    begin
      if (not AArgs.Has(I, AFunc.Params[I])) and (I <= High(AFunc.Defaults)) and
        (AFunc.Defaults[I] <> nil) then
        // the default expression is evaluated inside the callee's own new
        // frame, which is already on the stack at this point
        LFrame.Vars.AddOrSetValue(AFunc.Params[I], Eval(AFunc.Defaults[I]))
      else
        LFrame.Vars.AddOrSetValue(AFunc.Params[I], AArgs.Get(I, AFunc.Params[I]));
    end;
    Result := ExecBlock(AFunc.Body);
  finally
    FFrames.Remove(LFrame);
    Dec(FCallDepth);
  end;
end;

end.
