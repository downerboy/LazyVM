@echo off
rem Install-FromRepository.cmd - double-click to analyze, test and install LazyVM
rem from this repository, for the current Windows user. The same as running, in
rem PowerShell 7 in this folder:
rem
rem     ./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out
rem
rem Nothing is installed unless the analyzer and every test pass.
setlocal

rem Not elevated: LazyVM is installed per user, in this user's Documents (#284).
rem Run from the repository's root, wherever the file was started from.
cd /d "%~dp0"

where pwsh >nul 2>&1
if errorlevel 1 (
    echo PowerShell 7 is not installed. Install it with: winget install Microsoft.PowerShell
    echo.
    pause
    exit /b 1
)

rem -ExecutionPolicy Bypass applies to this one run only.
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "git pull --ff-only"

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out"
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" echo Installed. Open a new PowerShell 7 window as administrator to use LazyVM.
if not "%RESULT%"=="0" echo Not installed: see the messages above.
echo.
pause
exit /b %RESULT%
