@echo off
REM ===========================================================================
REM  Network Toolkit - HTML report renderer
REM
REM  No arguments: opens a window to pick a saved report JSON and render it.
REM  You can also drag a .json file onto that window.
REM
REM  To render from a command line instead, skip this launcher:
REM    powershell -NoProfile -ExecutionPolicy Bypass -File NetTool_HTML_Report.ps1 ^
REM               -JsonPath report.json -OutputPath report.html -Open
REM
REM  -STA is required for WinForms, and the failure without it is intermittent
REM  rather than obvious.
REM ===========================================================================
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0NetTool_HTML_Report.ps1" %*
if errorlevel 1 (
  echo.
  echo The renderer exited with an error. Re-run showing the console:
  echo   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0NetTool_HTML_Report.ps1"
  echo.
  pause
)
