@echo off
rem Uninstall LazyVM.cmd - double-click to remove LazyVM and its app from this
rem computer, keeping the VMs and their data. It lists what goes and what
rem stays, and asks first. The same as running, in PowerShell 7 as
rem administrator in this folder:
rem
rem     .\Install.ps1 -Uninstall
setlocal

rem Not elevated: start this file again as administrator (UAC prompt) and stop.
rem LazyVM is in %ProgramFiles%\LazyVM, which only administrators can change (#284).
rem The path goes through an environment variable, so no quoting can break it.
fltmc >nul 2>&1
if errorlevel 1 (
    set "LAZYVM_SELF=%~f0"
    powershell.exe -NoLogo -NoProfile -Command "try { Start-Process -FilePath $env:LAZYVM_SELF -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Administrator rights are needed to remove LazyVM from Program Files.'; Read-Host 'Press Enter to close' }"
    exit /b
)

rem PowerShell 7.6 or later, where its installer puts it.
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" goto :nopwsh
"%PWSH%" -NoLogo -NoProfile -Command "exit [int]($PSVersionTable.PSVersion -lt [version]'7.6')"
if errorlevel 1 goto :nopwsh

rem -ExecutionPolicy Bypass applies to this one run only.
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" -Uninstall
set "RESULT=%ERRORLEVEL%"

echo.
if not "%RESULT%"=="0" echo Not uninstalled: see the messages above.
echo.
pause
exit /b %RESULT%

:nopwsh
echo Uninstalling LazyVM needs PowerShell 7.6 or later, installed in %ProgramFiles%\PowerShell\7.
echo A copy from the Microsoft Store is not used: it is installed elsewhere.
echo Install it with: winget install Microsoft.PowerShell
echo Then double-click Uninstall LazyVM.cmd again.
echo.
pause
exit /b 1
