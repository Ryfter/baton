@echo off
setlocal
REM Windows cmd/PATH entry — forward to the PowerShell dispatcher.
set "BATON_SHIM_DIR=%~dp0"
pwsh -NoProfile -File "%BATON_SHIM_DIR%scripts\baton.ps1" %*
exit /b %ERRORLEVEL%
