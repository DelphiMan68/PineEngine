@echo off
rem Build the DLL with the Delphi command line compiler.
rem -$Q- disables integer overflow checking (the LCG in Pine.Runtime.pas
rem already turns it off locally for itself; this is a project-wide safety net).
dcc32 -U..\src -E. -$Q- PineLib.dpr
