@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start_geo_operator.ps1" %*
if errorlevel 1 (
  echo.
  echo GEO Operator failed to start.
  echo See logs\launcher.log, logs\server.stderr.log, and logs\worker.stderr.log.
  pause
)

endlocal
