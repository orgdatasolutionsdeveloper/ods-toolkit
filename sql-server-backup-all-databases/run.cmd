@echo off
setlocal
rem SQL Server Backup All Databases - Windows launcher
rem By John Stover, Org Data Solutions. MIT License.
rem Runs the backup script with PowerShell 7 when it is installed, otherwise
rem with Windows PowerShell. Anything typed after "run" is passed on:
rem   run -RetentionDays 30
cd /d "%~dp0"

set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Backup-AllSqlServerDatabases.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo Done.) else (echo The backup stopped with an error ^(code %RC%^).)
rem Keep the window open when this file was started by double-click.
echo %CMDCMDLINE% | find /i "%~nx0" >nul && pause
exit /b %RC%
