set "params=%*"
cd /d "%~dp0" && ( if exist "%temp%\getadmin.vbs" del "%temp%\getadmin.vbs" ) && fsutil dirty query %systemdrive% 1>nul 2>nul || (  echo Set UAC = CreateObject^("Shell.Application"^) : UAC.ShellExecute "cmd.exe", "/k cd ""%~sdp0"" && %~s0 %params%", "", "runas", 1 >> "%temp%\getadmin.vbs" && "%temp%\getadmin.vbs" && exit /B )
set dir="%CD%"
powershell -Command "powershell.exe set-executionpolicy unrestricted"
powershell -Command "Import-Module .\src\PSScriptMenuGui\PSScriptMenuGui.psm1; sleep 2; Show-ScriptMenuGui -csvpath .\src\gui.csv"







