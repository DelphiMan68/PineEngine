#!/bin/sh
# Build the DLL/shared-object with Free Pascal (3.2 or newer).
# Produces PineLib.dll on Windows, libPineLib.so on Linux/macOS.
fpc -Mdelphi -Sh -O2 -Fu../src -FE. PineLib.dpr
