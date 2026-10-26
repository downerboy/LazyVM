@echo off
rem Install-FromRepository.cmd - double-click to analyze, test and install LazyVM
rem from this repository. The same as running, in PowerShell 7 as administrator
rem in this folder:
rem
rem     ./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out
rem
rem Nothing is installed unless the analyzer and every test pass.
setlocal

rem Not elevated: start this file again as administrator (UAC prompt) and stop.
rem The path goes through an environment variable, so no quoting can break it.
fltmc >nul 2>&1
if errorlevel 1 (
    set "LAZYVM_SELF=%~f0"
    powershell.exe -NoLogo -NoProfile -Command "try { Start-Process -FilePath $env:LAZYVM_SELF -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Administrator rights are needed to install LazyVM for all users.'; Read-Host 'Press Enter to close' }"
    exit /b
)

rem An elevated window starts in System32: run from the repository's root.
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
