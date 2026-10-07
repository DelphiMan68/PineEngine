unit Pine.Ast;

{ Abstract syntax tree of a Pine script.
  Every node that needs persistent memory across bars (built-in calls,
  `var` declarations, plot outputs, history of arbitrary expressions)
  carries a unique SiteId assigned by the parser. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$modeswitch UnicodeStrings}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Generics.Collections, Pine.Types;

type
  TPineNode = class
  public
    Line: Integer;
    Col: Integer;
    SiteId: Integer;
  end;

  TPineNodeList = TObjectList<TPineNode>;

  { ---------- expressions ---------- }

  TLiteralNode = class(TPineNode)
  public
    Value: TPineValue;
    constructor Create(const AValue: TPineValue);
  end;

  TIdentNode = class(TPineNode)
  public
    Name: string; // may be qualified, e.g. "ta.sma" or "color.red"
    constructor Create(const AName: string);
  end;

  TUnaryNode = class(TPineNode)
  public
    Op: string;
    Operand: TPineNode;
    destructor Destroy; override;
  end;

  TBinaryNode = class(TPineNode)
  public
    Op: string;
    Left: TPineNode;
    Right: TPineNode;
    destructor Destroy; override;
  end;

  TTernaryNode = class(TPineNode)
  public
    Cond: TPineNode;
    ThenExpr: TPineNode;
    ElseExpr: TPineNode;
    destructor Destroy; override;
  end;

  { History access: series[offset].
    Base is usually an identifier but any expression is allowed. }
  THistoryNode = class(TPineNode)
  public
    Base: TPineNode;
    Offset: TPineNode;
    destructor Destroy; override;
  end;

  { Array literal: [expr, expr, ...] used in expression position (e.g. the
    options= argument of input()). Produces a real Pine array value. }
  TArrayLiteralNode = class(TPineNode)
  public
    Items: TPineNodeList;
    constructor Create;
    destructor Destroy; override;
  end;

  TArgument = record
    Name: string; // empty for positional arguments
    Expr: TPineNode;
  end;

  TCallNode = class(TPineNode)
  public
    Name: string;
    Args: TArray<TArgument>;
    procedure AddArg(const AName: string; AExpr: TPineNode);
    destructor Destroy; override;
  end;

  { Method-call syntax: base.method(args), equivalent to
    namespace.method(base, args) where the namespace is inferred at
    evaluation time from base's runtime type (an array, a line, a label, a
    box, a table, or a string) - Base is a plain variable/expression here,
    never a namespace name (those are folded into TCallNode.Name/TIdentNode
    at parse time - see Pine.Parser's namespace whitelist). }
  TMethodCallNode = class(TPineNode)
  public
    Base: TPineNode;
    Method: string;
    Args: TArray<TArgument>;
    procedure AddArg(const AName: string; AExpr: TPineNode);
    destructor Destroy; override;
  end;

  { ---------- statements ---------- }

  TVarKind = (vkPlain, vkVar, vkVarIp);

  TVarDeclNode = class(TPineNode)
  public
    Name: string;
    VarKind: TVarKind;
    Expr: TPineNode;
    destructor Destroy; override;
  end;

  TTupleDeclNode = class(TPineNode)
  public
    Names: TArray<string>;
    Expr: TPineNode;
    destructor Destroy; override;
  end;

  TAssignNode = class(TPineNode)
  public
    Name: string;
    Expr: TPineNode;
    destructor Destroy; override;
  end;

  TExprStmtNode = class(TPineNode)
  public
    Expr: TPineNode;
    destructor Destroy; override;
  end;

  { `if` is both a statement and an expression: it yields the value of the
    last expression of the executed branch. }
  TIfNode = class(TPineNode)
  public
    Cond: TPineNode;
    ThenBody: TPineNodeList;
    ElseBody: TPineNodeList; // may be nil
    constructor Create;
    destructor Destroy; override;
  end;

  TForNode = class(TPineNode)
  public
    VarName: string;
    FromExpr: TPineNode;
    ToExpr: TPineNode;
    StepExpr: TPineNode; // may be nil
    Body: TPineNodeList;
    constructor Create;
    destructor Destroy; override;
  end;

  TWhileNode = class(TPineNode)
  public
    Cond: TPineNode;
    Body: TPineNodeList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Func parameters may carry a default expression (nil = required, no
    default): f(a, b = 10) => ... . Defaults[I] pairs with Params[I]. }
  TFuncDeclNode = class(TPineNode)
  public
    Name: string;
    Params: TArray<string>;
    Defaults: TArray<TPineNode>; // owns non-nil entries
    Body: TPineNodeList;
    constructor Create;
    destructor Destroy; override;
  end;

  TBreakNode = class(TPineNode);
  TContinueNode = class(TPineNode);

  { switch [subject] \n pattern1 => body1 \n pattern2 => body2 \n ... \n
    [=> defaultBody]. Subject is nil for the "boolean" form, where each
    pattern is itself a condition rather than something compared against a
    subject. A case with Pattern = nil is the default (catch-all) case. }
  TSwitchCase = record
    Pattern: TPineNode; // nil = default case
    Body: TPineNodeList;
  end;

  TSwitchNode = class(TPineNode)
  public
    Subject: TPineNode; // nil for the subject-less boolean form
    Cases: TArray<TSwitchCase>;
    procedure AddCase(APattern: TPineNode; ABody: TPineNodeList);
    destructor Destroy; override;
  end;

  { Whole compiled script. }
  TPineProgram = class
  public
    Body: TPineNodeList;
    Functions: TDictionary<string, TFuncDeclNode>; // does not own the nodes
    Version: Integer;
    SiteCount: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

implementation

{ TLiteralNode }

constructor TLiteralNode.Create(const AValue: TPineValue);
begin
  inherited Create;
  Value := AValue;
end;

{ TIdentNode }

constructor TIdentNode.Create(const AName: string);
begin
  inherited Create;
  Name := AName;
end;

{ TUnaryNode }

destructor TUnaryNode.Destroy;
begin
  Operand.Free;
  inherited Destroy;
end;

{ TBinaryNode }

destructor TBinaryNode.Destroy;
begin
  Left.Free;
  Right.Free;
  inherited Destroy;
end;

{ TTernaryNode }

destructor TTernaryNode.Destroy;
begin
  Cond.Free;
  ThenExpr.Free;
  ElseExpr.Free;
  inherited Destroy;
end;

{ THistoryNode }

destructor THistoryNode.Destroy;
begin
  Base.Free;
  Offset.Free;
  inherited Destroy;
end;

{ TArrayLiteralNode }

constructor TArrayLiteralNode.Create;
begin
  inherited Create;
  Items := TPineNodeList.Create(True);
end;

destructor TArrayLiteralNode.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

{ TCallNode }

procedure TCallNode.AddArg(const AName: string; AExpr: TPineNode);
var
  N: Integer;
begin
  N := Length(Args);
  SetLength(Args, N + 1);
  Args[N].Name := AName;
  Args[N].Expr := AExpr;
end;

destructor TCallNode.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Args) do
    Args[I].Expr.Free;
  inherited Destroy;
end;

{ TMethodCallNode }

procedure TMethodCallNode.AddArg(const AName: string; AExpr: TPineNode);
var
  N: Integer;
begin
  N := Length(Args);
  SetLength(Args, N + 1);
  Args[N].Name := AName;
  Args[N].Expr := AExpr;
end;

destructor TMethodCallNode.Destroy;
var
  I: Integer;
begin
  Base.Free;
  for I := 0 to High(Args) do
    Args[I].Expr.Free;
  inherited Destroy;
end;

{ TVarDeclNode }

destructor TVarDeclNode.Destroy;
begin
  Expr.Free;
  inherited Destroy;
end;

{ TTupleDeclNode }

destructor TTupleDeclNode.Destroy;
begin
  Expr.Free;
  inherited Destroy;
end;

{ TAssignNode }

destructor TAssignNode.Destroy;
begin
  Expr.Free;
  inherited Destroy;
end;

{ TExprStmtNode }

destructor TExprStmtNode.Destroy;
begin
  Expr.Free;
  inherited Destroy;
end;

{ TIfNode }

constructor TIfNode.Create;
begin
  inherited Create;
  ThenBody := TPineNodeList.Create(True);
end;

destructor TIfNode.Destroy;
begin
  Cond.Free;
  ThenBody.Free;
  ElseBody.Free;
  inherited Destroy;
end;

{ TForNode }

constructor TForNode.Create;
begin
  inherited Create;
  Body := TPineNodeList.Create(True);
end;

destructor TForNode.Destroy;
begin
  FromExpr.Free;
  ToExpr.Free;
  StepExpr.Free;
  Body.Free;
  inherited Destroy;
end;

{ TWhileNode }

constructor TWhileNode.Create;
begin
  inherited Create;
  Body := TPineNodeList.Create(True);
end;

destructor TWhileNode.Destroy;
begin
  Cond.Free;
  Body.Free;
  inherited Destroy;
end;

{ TFuncDeclNode }

constructor TFuncDeclNode.Create;
begin
  inherited Create;
  Body := TPineNodeList.Create(True);
end;

destructor TFuncDeclNode.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Defaults) do
    Defaults[I].Free;
  Body.Free;
  inherited Destroy;
end;

{ TSwitchNode }

procedure TSwitchNode.AddCase(APattern: TPineNode; ABody: TPineNodeList);
var
  N: Integer;
begin
  N := Length(Cases);
  SetLength(Cases, N + 1);
  Cases[N].Pattern := APattern;
  Cases[N].Body := ABody;
end;

destructor TSwitchNode.Destroy;
var
  I: Integer;
begin
  Subject.Free;
  for I := 0 to High(Cases) do
  begin
    Cases[I].Pattern.Free;
    Cases[I].Body.Free;
  end;
  inherited Destroy;
end;

{ TPineProgram }

constructor TPineProgram.Create;
begin
  inherited Create;
  Body := TPineNodeList.Create(True);
  Functions := TDictionary<string, TFuncDeclNode>.Create;
  Version := 5;
end;

destructor TPineProgram.Destroy;
begin
  Functions.Free;
  Body.Free;
  inherited Destroy;
end;

end.
