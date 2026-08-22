@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start_geo_operator.ps1" %*
if errorlevel 1 (
  echo.
  echo GEO Operator failed to start.
  echo See logs\launcher.log, logs\server.stderr.log, and logs\worker.stderr.log.
  pause
  exit /b 1
)

echo.
echo GEO Operator control service and Browser Worker are running.
echo Control panel: http://127.0.0.1:8765
echo This console is the unified launcher; all operations are available in the control panel.
echo Closing this window will not stop the running services.
echo.
pause
endlocal
