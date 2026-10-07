@echo off
rem Build the console runner with the Delphi command line compiler.
rem -$Q- disables integer overflow checking project-wide (the LCG in
rem Pine.Runtime.pas already turns it off locally, this is a safety net).
dcc32 -U..\src -E. -$Q- PineRun.dpr
