set "params=%*"
cd /d "%~dp0" && ( if exist "%temp%\getadmin.vbs" del "%temp%\getadmin.vbs" ) && fsutil dirty query %systemdrive% 1>nul 2>nul || (  echo Set UAC = CreateObject^("Shell.Application"^) : UAC.ShellExecute "cmd.exe", "/k cd ""%~sdp0"" && %~s0 %params%", "", "runas", 1 >> "%temp%\getadmin.vbs" && "%temp%\getadmin.vbs" && exit /B )
rem gk-script.exe (NSIS) is 32-bit, so a plain "powershell" here would be the 32-bit one (registry
rem writes land in WOW6432Node). Sysnative reaches the 64-bit PowerShell from a 32-bit process.
set "ps=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "ps=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%ps%" -Command "Set-ExecutionPolicy Bypass -Scope Process -Force; Import-Module .\src\PSScriptMenuGui\PSScriptMenuGui.psm1; Show-ScriptMenuGui -csvpath .\src\gui.csv"







