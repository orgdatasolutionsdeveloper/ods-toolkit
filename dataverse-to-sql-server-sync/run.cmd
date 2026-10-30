@echo off
setlocal
rem Dataverse to SQL Server Sync - Windows launcher
rem By John Stover, Org Data Solutions. MIT License.
rem Finds PowerShell 7 (installs it with winget when it is missing), then runs
rem the sync. Anything typed after "run" is passed on:  run -Mode Refresh
cd /d "%~dp0"

set "PWSH="
where pwsh >nul 2>&1 && set "PWSH=pwsh"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined PWSH goto :run

echo PowerShell 7 is not installed. Installing it with winget ...
winget install -e --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements
if errorlevel 1 (
  echo.
  echo PowerShell 7 could not be installed automatically.
  echo Install it from https://aka.ms/powershell and run this file again.
  pause
  exit /b 1
)
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH (
  echo PowerShell 7 is installed. Close this window and run this file again.
  pause
  exit /b 1
)

:run
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-DataverseToSqlServer.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo Done.) else (echo The sync stopped with an error ^(code %RC%^).)
rem Keep the window open when this file was started by double-click.
echo %CMDCMDLINE% | find /i "%~nx0" >nul && pause
exit /b %RC%
