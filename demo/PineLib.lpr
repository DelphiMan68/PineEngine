{ Lazarus/FPC-native project entry point for the PineLib DLL/shared
  object.

  This is the file Lazarus IDE users (and `fpc PineLib.lpr` on the
  command line) build - paired with PineLib.lpi, the Lazarus project
  file. It is not a second copy of the library: it includes PineLib.dpr
  verbatim, so there is exactly one copy of the actual source to
  maintain, and the Delphi build (PineLib.dpr via dcc32/dcc64, or
  build_dll.bat) and this one compile from identical code. See
  demo/build_dll.sh for a command-line FPC build of this project; see
  README.md section 5 for both. }

{$I PineLib.dpr}
