@echo off
REM ------------------------------------------------------------------
REM  Launcher for boot-crash-report.ps1
REM
REM  Kept pure ASCII on purpose: cmd.exe reads .cmd/.bat in the active
REM  codepage, so non-ASCII bytes here would corrupt parsing. All
REM  Chinese strings live in the .ps1, which is UTF-8 with a BOM.
REM ------------------------------------------------------------------

chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0boot-crash-report.ps1"
