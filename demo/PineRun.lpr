{ Lazarus/FPC-native project entry point for the PineRun console runner.

  This is the file Lazarus IDE users (and `fpc PineRun.lpr` on the command
  line) build - paired with PineRun.lpi, the Lazarus project file. It is
  not a second copy of the program: it includes PineRun.dpr verbatim, so
  there is exactly one copy of the actual source to maintain, and the
  Delphi build (PineRun.dpr via dcc32/dcc64, or build.bat) and this one
  compile from identical code. See demo/build.sh for a command-line FPC
  build of this project; see README.md section 2 for both. }

{$I PineRun.dpr}
