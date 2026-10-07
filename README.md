![PineEngine — Run Pine Script Anywhere](assets/pineengine-banner.png)

# PineEngine — a Pine Script interpreter written in Delphi

A self contained interpreter for a practical subset of TradingView's Pine Script
(v3 through v6 style), written in plain Object Pascal with no third-party
dependencies. It compiles with Delphi (XE2 and newer) and with Free Pascal
3.2+ in Delphi mode, as a console program (`PineRun`) or as a DLL/shared
object (`PineLib`) callable from any language with a C FFI — see section 5.

The script is executed **bar by bar**, exactly like Pine does on a chart, so
`close[1]`, `var`, `ta.ema()` and friends behave the way you expect.

**The Pine Script code, the candle data and the settings are always three
separate inputs.** The code is plain text (a `.pine` file, never wrapped in
JSON); the candles travel as a plain JSON array; everything else —
`input()` overrides, synthetic-data settings, the pretty-print flag —
travels as a small JSON object. The library gives back exactly one JSON
response: the plotted series, logs and alerts, or an `"error"` object if
something went wrong. Nothing else is ever printed or returned.

---

## 1. Project layout

```
PineEngine/
├── src/
│   ├── Pine.Types.pas        values, series, rolling buffers, call state
│   ├── Pine.Lexer.pas        indentation aware tokenizer
│   ├── Pine.Ast.pas          AST node classes
│   ├── Pine.Parser.pas       recursive descent parser
│   ├── Pine.Runtime.pas      bar data, plot output, execution context
│   ├── Pine.Builtins.pas     built-in constants and function library
│   ├── Pine.Interpreter.pas  tree walking evaluator
│   ├── Pine.Json.pas         dependency-free JSON value/parser/serializer
│   ├── Pine.JsonApi.pas      the library's public surface: RunPine()
│   └── Pine.DllApi.pas       the DLL's public surface: PineRunJson() (see section 5)
├── demo/
│   ├── PineRun.dpr           thin console wrapper around RunPine() (Delphi project)
│   ├── PineRun.lpr/.lpi      the same program as a Lazarus/FPC project (includes PineRun.dpr)
│   ├── build.bat             Delphi command line build (PineRun)
│   ├── build.sh              Free Pascal command line build (PineRun)
│   ├── PineLib.dpr           library project exporting PineRunJson/PineFreeString/PineVersion (Delphi project)
│   ├── PineLib.lpr/.lpi      the same library as a Lazarus/FPC project (includes PineLib.dpr)
│   ├── build_dll.bat         Delphi command line build (PineLib.dll)
│   └── build_dll.sh          Free Pascal command line build (PineLib.dll / libPineLib.so)
├── samples/
│   ├── *.pine, candles_*.json, settings_*.json   example scripts and their data
│   └── dll-clients/          calling PineLib from Delphi/FPC, C++, C#, and Python
├── assets/
│   └── pineengine-banner.png the banner image at the top of this README
└── README.md
```

## 2. Building

**Delphi (command line)**

```
cd demo
build.bat
```

which is simply:

```
dcc32 -U..\src -E. -$Q- PineRun.dpr
```

(`-$Q-` turns off integer overflow checking for the build; one internal
routine relies on intentional `Cardinal` wraparound. The unit that needs it
also carries a local `{$Q-}` directive, so the switch is only a safety net.)

**Delphi (IDE)** — open `demo\PineRun.dpr`, then add `..\src` to
*Project ▸ Options ▸ Building ▸ Delphi Compiler ▸ Search path*.

**Free Pascal (command line)**

```
cd demo
./build.sh          # fpc -Mdelphi -Fu../src PineRun.dpr
```

**Free Pascal / Lazarus (IDE)** — open `demo/PineRun.lpi` in Lazarus and
build (Run ▸ Build, or Ctrl+F9). `PineRun.lpi` is a normal Lazarus
project; its source file, `PineRun.lpr`, is a one-line `{$I PineRun.dpr}`
rather than a second copy of the program, so the Delphi build and the
Lazarus build always compile from the exact same code - there's nothing
to keep in sync by hand. The `.lpi` already points its unit search path
at `../src`.

## 3. Running

The compiled `PineRun` takes the Pine Script code, the candles, the
settings, and an optional output path as **four separate arguments**, and
always prints **one JSON response** to standard output — nothing else,
ever (no usage banner, no progress messages, no plain-text errors; even
the "wrong usage" case prints a JSON `error` object).

```
PineRun <script.pine> [candles.json] [settings.json] [output.json]
```

* `<script.pine>` — path to a plain text file with the Pine Script source.
  This is always plain code, never JSON.
* `[candles.json]` — optional. Either a path to a JSON file, or the JSON
  text itself typed directly on the command line. A plain JSON **array**
  of candles — nothing else lives in this argument. Omit it (or pass `[]`)
  to run on synthetic data instead.
* `[settings.json]` — optional. Either a path to a JSON file, or the JSON
  text itself. A JSON **object** with `input()` overrides, the
  synthetic-data settings (used only when no candles were given) and the
  pretty-print flag.
* `[output.json]` — optional. A file path to also save the result to. The
  result is still printed to standard output either way; this just saves a
  copy alongside it. If the file can't be written (bad path, no
  permission...), a message goes to standard **error** — standard output
  stays pure JSON no matter what.

```
PineRun samples\sma_cross.pine "[]" samples\settings_sma_cross.json
PineRun samples\macd.pine samples\candles_macd.json > result.json
PineRun samples\rsi.pine "[]" "{\"syntheticBars\": 500}"
PineRun samples\state.pine                              :: all-synthetic run
PineRun samples\macd.pine samples\candles_macd.json "{}" result.json
```

### Candles argument

```jsonc
[
  {"time": "2024-01-01", "open": 100, "high": 101, "low": 99, "close": 100.5, "volume": 1000},
  {"time": "2024-01-02", "open": 100.5, "high": 102, "low": 100.1, "close": 101.7, "volume": 980}
]
```

* A plain array, one object per bar — not wrapped in `{"bars": [...]}`.
* `time` may be a JSON number (unix seconds) or a string (`"2024-01-31"` or
  a numeric timestamp as text); if omitted, the bar's index in the array is
  used.
* `''`, `'[]'`, or leaving the argument out entirely all mean "no candles —
  generate synthetic data instead" (see `syntheticBars` below).

### Settings argument

```jsonc
{
  "syntheticBars": 200,        // only used when no candles were given
  "seed": 12345,               // seeds the synthetic random walk
  "startPrice": 100,
  "inputs": { "Fast Length": 8, "Use EMA": true, "Mode": "fast" },
  "pretty": false              // pretty-print the response (default: compact)
}
```

Every field is optional — `{}`, an empty string, or leaving the third
argument out entirely all mean "all defaults".

* `inputs` keys match the `title=` of the corresponding `input()` call in the
  script (or `"input" + <call index>` if the script gives no title). Values
  keep their JSON type — a JSON bool reaches `input.bool()` as a bool, a JSON
  number reaches `input.int()` / `input.float()` typed accordingly, etc.

### Response — success

```jsonc
{
  "title": "SMA Cross", "shortTitle": "SMA Cross",
  "overlay": true, "isStrategy": false, "barCount": 120,
  "plots": [
    { "title": "Fast MA", "kind": "plot", "color": "#FF2196F3",
      "values": [null, null, 101.2, 101.4, ...] }
  ],
  "logs": ["bar 45 [info]: ..."],
  "alerts": ["bar 80: Golden cross"]
}
```

`values` has exactly one entry per bar; `null` stands for Pine's `na`.
`kind` is `"plot"`, `"hline"` or `"bgcolor"` (a `bgcolor` plot's `values`
are hex color strings instead of numbers).

### Response — error

```json
{ "error": { "type": "syntax", "message": "Expected \")\" but found ... at line 7" } }
```

`type` is one of `"input"` (malformed candles/settings JSON, or a usage
error such as a missing script file), `"syntax"` (script doesn't parse),
`"runtime"` (script parsed but failed while running), or `"internal"`
(anything unexpected).

## 4. Embedding the library in your own application

The whole contract is one function that keeps code, candles and settings
separate:

```pascal
uses
  Pine.JsonApi;

var
  LResponseJson: string;
begin
  LResponseJson := RunPine(
    'indicator("t")' + sLineBreak + 'plot(close)',   // plain Pine Script text
    '[]',                                            // no candles -> synthetic
    '{"syntheticBars": 50}');                        // settings only
  Memo1.Lines.Add(LResponseJson);  // always valid JSON, never raises
end;
```

`RunPine` never raises: parse the result with your own JSON layer (or
`Pine.Json.ParseJson`) and branch on whether it has an `"error"` member.
Both the candles and the settings arguments default to `''` (treated the
same as `'[]'` / `'{}'`), so `RunPine(AScript)` alone runs on 200 synthetic
bars with default settings.

If you are already inside Delphi/Pascal code and don't need the JSON
round-trip, the lower level API (`Pine.Runtime`, `Pine.Interpreter`) is
still available and works exactly as before:

```pascal
uses
  Pine.Types, Pine.Runtime, Pine.Interpreter;

var
  LBars: TPineBarSet;
  LCtx: TPineContext;
  I: Integer;
begin
  LBars := TPineBarSet.Create;
  try
    LBars.LoadFromCSV('prices.csv');
    LCtx := RunPineScript(Memo1.Lines.Text, LBars); // inputs param optional
    try
      for I := 0 to LCtx.Output.PlotCount - 1 do
        Memo2.Lines.Add(LCtx.Output.Plots[I].Title + ' = ' +
          FormatNumber(LCtx.Output.Plots[I].ValueAt(LBars.Count - 1)));
    finally
      LCtx.Free;
    end;
  finally
    LBars.Free;
  end;
end;
```

`RunPineScript`'s third parameter is now a typed
`TDictionary<string, TPineValue>` of input overrides (matching what
`Pine.JsonApi` builds from the request's `"inputs"` object) instead of a
plain string list, so both entry points share exactly the same typing all
the way down to `input.*()`.

All errors are raised as `EPineSyntaxError` / `EPineRuntimeError`
(both descend from `EPineError`) and carry the line number in `.Message`.

## 5. Using it as a DLL from other languages

`demo/PineLib.dpr` builds the same interpreter as a DLL (Windows) or
shared object (Linux/macOS via Free Pascal), exporting three plain
`cdecl` C functions — the whole thing is also `RunPine` underneath, just
exposed across a C ABI instead of linked into a Pascal program:

```
char* PineRunJson(const char* script, const char* candlesJson, const char* settingsJson);
void  PineFreeString(char* str);
char* PineVersion(void);
```

Build it:

```
cd demo
build_dll.bat          :: Delphi -> PineLib.dll
./build_dll.sh          # Free Pascal, command line -> PineLib.dll (Windows) or libPineLib.so (Linux/macOS)
```

or open `demo/PineLib.lpi` in Lazarus and build (Run ▸ Build). Like
`PineRun.lpr`, `PineLib.lpr` is a one-line `{$I PineLib.dpr}` rather than
a second copy of the library, so the Delphi and Lazarus builds always
compile from the exact same source.

The contract, documented in full in `src/Pine.DllApi.pas`:

* Every string crossing the boundary, in or out, is a **UTF-8,
  null-terminated C string** — the one format every language already
  knows how to produce and consume, with no COM/WideString/language-
  specific marshaling helper needed anywhere.
* The calling convention is **`cdecl`** throughout, the default for C/C++
  and what every FFI layer below (ctypes, P/Invoke, ...) targets without
  extra ceremony.
* `PineRunJson` and `PineVersion` **allocate** the string they return —
  call `PineFreeString` on that exact pointer exactly once when done with
  it, never your own language's `free`/`delete`/GC. Strings you pass in
  are only read, never owned by the library; manage them however you
  normally would.
* `PineRunJson` never raises/throws and never returns null — a bad
  script, bad candles/settings JSON, or a runtime error all come back as
  a normal `{"error": {...}}` JSON string, exactly like the console
  program.

`samples/dll-clients/` has a complete, runnable example in each of these
languages, all doing the same thing (print the library version, run a
small script, print the JSON result), so you can compare their output
directly:

| Language | File |
| --- | --- |
| Delphi or Free Pascal | `pascal_client_example.dpr` (one file, builds with either compiler) |
| C++ | `cpp_client_example.cpp` (dynamic loading via `LoadLibrary`/`dlopen` — no import library needed) |
| C# | `CSharpClientExample.cs` (P/Invoke) |
| Python | `python_client_example.py` (`ctypes`, standard library only) |

See `samples/dll-clients/README.md` for exact build/run commands for
each. The pattern is always the same: declare the three functions with
`cdecl` and UTF-8/C-string types, call `PineRunJson`, read the JSON, call
`PineFreeString` on the pointer you got back — and the identical
`PineLib.dll`/`libPineLib.so` works no matter which compiler built it,
since nothing about the calling side needs to know that.

## 6. Supported language features

* comments `//`, the `//@version=N` annotation
* literals: numbers, strings, `true`, `false`, `na`, colors (`#FF9800`),
  array literals `[a, b, c]` in expression position (e.g. `input()`'s
  `options=`)
* declarations `x = expr`, `var x = expr`, `varip`, optional type prefixes
  (`float x = 1.0`), reassignment `x := expr`
* tuple declarations: `[macdLine, signalLine, hist] = ta.macd(close, 12, 26, 9)`
* chained simple statements on one line with commas:
  `a = f(x), b = g(y), c = a - b`
* operators `+ - * / %`, comparisons, `and` / `or` / `not`, ternary `? :`,
  including ternaries and calls wrapped across several lines
* history access `close[1]`, `myVar[3]`, `ta.sma(close, 10)[2]`, and history
  of a function parameter/local bound from a series (`f(src) => src[1]`),
  which resolves back to whatever global or bar-data field was passed in
* `if / else if / else` as statement **and** as expression
* `for ... to ... by ...`, `while`, `break`, `continue`
* user defined functions: `f(a, b) => expr` and multi line bodies
* named call arguments: `plot(x, title="MA", color=color.red)`
* Pine arrays: `array.new_<type>()`, `array.get/set/push/pop/shift/unshift/
  size/clear/fill/includes/indexof/remove/insert` - a real, mutable,
  by-reference array type (mutating it through one variable is visible
  through every other variable/parameter holding the same array)
* `line`, `label`, `box`, and `table` objects (`line.new`, `box.new`,
  `table.new`, `table.cell`, ... and their setters/`delete`) - tracked as
  real objects (so scripts that create/move/delete them run correctly) and
  reported in the JSON response; there is no chart to draw them on, so
  nothing is rendered, but a table's cells and a box's/line's coordinates
  are all there for the caller to render itself
* method-call syntax: `myArray.push(x)`, `myTable.cell(...)`,
  `myLine.set_y1(v)` - exactly equivalent to `array.push(myArray, x)` etc.
  The namespace is inferred at evaluation time from the value's runtime
  type (array/line/label/box/table/string), since there's no static type
  system to know it ahead of time
* `switch`, both forms: `switch subject \n pattern1 => result1 \n ... \n
  => defaultResult` and the subject-less boolean form
  (`switch \n cond1 => r1 \n cond2 => r2`); each branch can be a single
  expression or a multi-line block like an `if`/function body
* function parameter default values: `f(a, b = 10, c = na) => ...`
* compound assignment `x += e`, `-=`, `*=`, `/=`, `%=` (sugar for
  `x := x <op> e`)

### Built-in variables

`open`, `high`, `low`, `close`, `volume`, `time`, `hl2`, `hlc3`, `ohlc4`,
`bar_index`, `last_bar_index`, `na`, `obv`, `dayofweek`, `barstate.isfirst`,
`barstate.islast`, `barstate.isnew`, `barstate.isconfirmed`, `math.pi`,
`math.e`, `math.phi`, `color.*` (16 named colors), `line.style_*`,
`label.style_*`, `shape.*`, `location.*`, `dayofweek.sunday`...`.saturday`,
`text.align_*`, `format.*`, `xloc.*`, `extend.*`, `display.*`, `size.*`,
`position.*`, `syminfo.ticker`, `syminfo.timezone`, `syminfo.mintick`,
`timeframe.period`.

### Built-in functions

| Group | Functions |
| --- | --- |
| Moving averages | `ta.sma`, `ta.ema`, `ta.rma`, `ta.wma`, `ta.vwma` |
| Oscillators | `ta.rsi`, `ta.macd`, `ta.stoch`, `ta.bb`, `ta.cci`, `ta.mfi` |
| Statistics | `ta.stdev`, `ta.variance`, `ta.highest`, `ta.lowest`, `ta.sum`, `ta.cum` |
| Change / timing | `ta.change`, `ta.mom`, `ta.roc`, `ta.barssince`, `ta.valuewhen`, `ta.rising`, `ta.falling` |
| Pivots | `ta.pivothigh`, `ta.pivotlow` |
| Crosses | `ta.crossover`, `ta.crossunder`, `ta.cross` |
| Volatility | `ta.tr`, `ta.atr` |
| Sessions | `time(timeframe, session, timezone)` - returns the bar's own time when it falls in the given session ("1300-2200", optionally ":1234567" day codes), else na; handles overnight-crossing sessions and a `"UTC±H[:MM]"`-style timezone |
| Math | `math.abs`, `max`, `min`, `pow`, `sqrt`, `round`, `floor`, `ceil`, `log`, `log10`, `exp`, `sign`, `avg`, `sin`, `cos`, `tan` |
| Strings | `str.tostring`/`tostring` (including `format.volume`, e.g. "1.23M"), `str.tonumber`, `str.length`, `str.upper`, `str.lower`, `str.contains`, `str.format`, `len` (see note below) |
| Arrays | `array.new_<type>`, `array.get/set/push/pop/shift/unshift/size/clear/fill/includes/indexof/remove/insert` |
| Drawing | `line.new/delete/set_x1/set_y1/set_x2/set_y2/set_xy1/set_xy2/set_color/set_width/set_style`, `label.new/delete/set_text/set_xy`, `box.new/delete/set_top/set_bottom/set_left/set_right/set_lefttop/set_rightbottom/set_bgcolor/set_border_color`, `table.new/delete/cell/cell_set_text/merge_cells` |
| Output | `plot`, `plotshape`, `plotchar`, `hline`, `bgcolor`, `alert`, `alertcondition`, `log.info/warning/error` |
| Misc | `na`/`na(x)`, `nz`, `fixnan`, `int`, `float`, `bool`, `string`, `color.new`, `color.rgb`, `input.*` (including `input.session`), `indicator`, `study`, `strategy` |

The `ta.` / `math.` prefix is optional, so both `ta.sma(close, 10)` and
`sma(close, 10)` work; `study(...)` is accepted as a v3/v4 alias of
`indicator(...)`.

> **`len(x)` is not part of real Pine Script.** It has been added here as a
> plain string-length convenience (equivalent to `str.length(x)`) because
> scripts sometimes assume it exists. If you actually meant array length, use
> `array.size(x)`.

## 7. Known limitations

These are deliberate, so that the code base stays small and readable:

* no strategy engine (`strategy.entry`, orders, backtest report) — `strategy()`
  is accepted but only stores the title
* no `request.security()`, no multi timeframe access
* no matrices, maps, polylines, or user-defined types (arrays, lines,
  labels, boxes, and tables are supported - see above); method-call syntax
  (`x.method(...)`) only works when `x` is one of those or a string
* `fill()` is parsed and ignored; `line`/`label`/`box`/`table` objects are
  tracked and reported in the JSON response, but never actually drawn on
  anything
* `time(timeframe, session, timezone)` only understands a `"UTC±H[:MM]"`
  (or bare `"UTC"`/`"GMT"`) timezone string - a named zone
  (`"America/New_York"`) or `syminfo.timezone` (which this interpreter
  always reports as `"UTC"`, having no real symbol data) is treated as
  UTC, with no daylight-saving adjustment or exchange-holiday awareness
* a local's history (`x[1]`) only resolves when `x`'s value traces directly
  back to a global variable or a bar-data field (e.g. a function parameter
  the caller passed a series into, like `f(src) => src[1]` called as
  `f(close)` or `f(someGlobal)`); history of a genuinely computed local
  (`y = a + b`, then `y[1]`) still raises, since that value has no series to
  go back to
* `varip` behaves like `var` because there is no intra-bar (realtime) tick data
* a stateful `ta.*` call placed inside an `if` branch only updates on the bars
  where the branch runs — TradingView warns about the same thing; the same
  caveat applies to a ternary's unchosen branch, which is still evaluated
  every bar (so a stateful call inside it keeps its state moving even when
  its result is discarded)

## 8. How it works

1. `TPineLexer` turns the source into tokens and emits virtual
   `INDENT` / `DEDENT` / `NEWLINE` tokens, because Pine blocks are defined by
   indentation. A logical line continues while a bracket is open, while a
   ternary's `?` is still waiting for its matching `:` (tracked as its own
   counter, independently of bracket depth - this is what lets a multi-line
   ternary keep going even when its "then" branch is itself a multi-line
   call that fully closes its own parens before the ternary's `:` shows up),
   or while the line ends with an operator that demands more (`and`/`or`/
   `not`, or any operator except the ones that always finish their own
   line: `)`, `]`, `=>`).
2. `TPineParser` builds the AST and gives every node a unique `SiteId`. A
   dotted identifier chain (`ta.sma`, `shape.labeldown`) is only folded into
   one qualified name when its first segment is a known built-in namespace
   (see `CNamespaces`); otherwise it's a plain variable, and a further
   `.method(...)` on it parses as a `TMethodCallNode` instead, resolved at
   evaluation time from the value's runtime type (array/line/label/box/
   table/string) - this is what makes `myArray.push(x)` work the same as
   `array.push(myArray, x)`.
3. `TPineInterpreter` runs the whole AST once per bar. Global variables live in
   `TPineSeries` objects that keep the full history, so `x[5]` is a direct
   lookup. Stateful built-ins store their rolling buffers and previous values in
   the `TCallState` bound to their `SiteId`, which is why two `ta.ema()` calls
   never mix their state. Every `TPineValue` also carries a `SeriesTag`: the
   name of the global/bar-data field it was last read from, copied along
   through local reads, ternaries, and function-parameter passing (but
   cleared by any arithmetic) - this is what lets a function parameter such
   as `src` in `f(src) => src[1]` resolve its own history correctly no
   matter how many layers of calls it passed through.
4. `plot()` writes into a `TPinePlot` that is also bound to the call site, so the
   result is one output series per `plot()` statement; `line.new()`/
   `label.new()`/`box.new()`/`table.new()` similarly register a
   `TPineLineObj`/`TPineLabelObj`/`TPineBoxObj`/`TPineTableObj` with
   `TPineOutput`, reported in the JSON response.
5. `Pine.JsonApi.RunPine` is a thin façade on top of all of this: it takes
   the script text and the data JSON as two separate parameters, parses the
   data (via the dependency-free `Pine.Json` unit), builds a `TPineBarSet`
   and a typed input-override map from it, calls `RunPineScript`, and
   serializes `TPineContext.Output` back to JSON. Any exception raised
   anywhere in that pipeline is caught here and turned into an
   `{"error": ...}` response instead of propagating out.

### Adding your own built-in function

Open `Pine.Builtins.pas` and add a branch to `CallBuiltin`:

```pascal
if LFunc = 'zscore' then
begin
  B := SmaStep(LSt, 0, LBar, A, LLen);
  C := StdevStep(LSt, 1, LBar, A, LLen);
  if IsNan(B) or IsNan(C) or (C = 0) then
    Exit(PineNA);
  Exit(PineFloat((A - B) / C));
end;
```

Use a different buffer index per rolling calculation inside one function, and a
different `Nums`/`Flags` slot per recursive value — that is the whole contract.
It automatically becomes usable from JSON requests too, with no changes
needed anywhere else.
