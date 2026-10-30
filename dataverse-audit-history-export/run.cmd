@echo off
setlocal
rem Dataverse Audit History Export - Windows launcher
rem By John Stover, Org Data Solutions. MIT License.
rem Finds Python (installs Python 3.12 with winget when it is missing), then
rem runs the tool. Anything typed after "run" is passed on:  run export --days=90
rem With nothing after "run", the tool asks what you want to do.
cd /d "%~dp0"

set "PY="
py -3 --version >nul 2>&1 && set "PY=py -3"
if not defined PY python --version >nul 2>&1 && set "PY=python"
if not defined PY python3 --version >nul 2>&1 && set "PY=python3"
if defined PY goto :run

echo Python is not installed. Installing Python 3.12 with winget ...
winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
if errorlevel 1 (
  echo.
  echo Python could not be installed automatically.
  echo Install it from https://www.python.org/downloads/ and run this file again.
  pause
  exit /b 1
)
rem The fresh install is not on this window's PATH yet; use the launcher directly.
if exist "%LocalAppData%\Programs\Python\Launcher\py.exe" set "PY="%LocalAppData%\Programs\Python\Launcher\py.exe" -3"
if not defined PY if exist "%SystemRoot%\py.exe" set "PY="%SystemRoot%\py.exe" -3"
if not defined PY (
  echo Python is installed. Close this window and run this file again.
  pause
  exit /b 1
)

:run
%PY% "%~dp0dataverse_audit_history_export.py" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo Done.) else (echo The tool stopped with an error ^(code %RC%^).)
rem Keep the window open when this file was started by double-click.
echo %CMDCMDLINE% | find /i "%~nx0" >nul && pause
exit /b %RC%
