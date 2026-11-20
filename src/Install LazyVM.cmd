@echo off
rem Install LazyVM.cmd - double-click to install LazyVM and its app from this
rem release download, for the current Windows user. The same as running, in
rem PowerShell 7 as administrator in this folder:
rem
rem     .\Install.ps1
rem
rem Install-FromRepository.cmd, in the repository, is the developer's shortcut.
setlocal

rem Not elevated: start this file again as administrator (UAC prompt) and stop.
rem LazyVM goes in %ProgramFiles%\LazyVM, which only administrators can change (#284).
rem The path goes through an environment variable, so no quoting can break it.
fltmc >nul 2>&1
if errorlevel 1 (
    set "LAZYVM_SELF=%~f0"
    powershell.exe -NoLogo -NoProfile -Command "try { Start-Process -FilePath $env:LAZYVM_SELF -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Administrator rights are needed to install LazyVM in Program Files.'; Read-Host 'Press Enter to close' }"
    exit /b
)

rem PowerShell 7.6 or later, where its installer puts it.
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" goto :nopwsh
"%PWSH%" -NoLogo -NoProfile -Command "exit [int]($PSVersionTable.PSVersion -lt [version]'7.6')"
if errorlevel 1 goto :nopwsh

rem -ExecutionPolicy Bypass applies to this one run only.
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
set "RESULT=%ERRORLEVEL%"

echo.
if "%RESULT%"=="0" echo Installed. Start LazyVM from the Start menu, or open a new PowerShell 7 window as administrator to use its commands.
if not "%RESULT%"=="0" echo Not installed: see the messages above.
echo.
pause
exit /b %RESULT%

:nopwsh
echo LazyVM needs PowerShell 7.6 or later, installed in %ProgramFiles%\PowerShell\7.
echo A copy from the Microsoft Store is not used: it is installed elsewhere.
echo Install it with: winget install Microsoft.PowerShell
echo Then double-click Install LazyVM.cmd again.
echo.
pause
exit /b 1
