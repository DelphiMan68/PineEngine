#!/bin/sh
# Build the console runner with Free Pascal (3.2 or newer).
fpc -Mdelphi -Sh -O2 -Fu../src -FE. PineRun.dpr
