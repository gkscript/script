[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")

$dir = $args[0]
$type = $args[1]
cd "$dir"

$gpu = (Get-WmiObject Win32_VideoController).Name

$startmenupath = "$env:LOCALAPPDATA/Packages/Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy/LocalState"

if (-not (test-connection 8.8.8.8 -quiet)){
  $null=[System.Windows.Forms.Messagebox]::Show("Check your Internet connection!")
  exit 1
}


if(-not (Get-Command "winget" -errorAction SilentlyContinue)){
  Add-AppPackage "src/UI.Xaml.2.7_7.2208.15002.0.Appx"
  Add-AppPackage "src/VCLibs.140.00.UWPDesktop_14.0.32530.0_x64.Appx"
  Add-AppPackage "src/Microsoft.DesktopAppInstaller.msixbundle"

}
Start-Sleep 1
if(-not (Get-Command "winget" -errorAction SilentlyContinue)){
  $null=[System.Windows.Forms.Messagebox]::Show("Failure to install Winget. Please update the `"App-Installer`" package from the Microsoft Store manually")
  exit 1
}
if(-not (Get-Command "choco" -errorAction SilentlyContinue)){
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}
src/RefreshEnv.cmd
if(Get-Command "choco" -errorAction SilentlyContinue){
  choco feature enable -n allowGlobalConfirmation
  switch($type)
        {
            0{choco install -y --ignorechecksum vlc firefox googlechrome 7zip adobereader}              #business
            1{choco install -y --ignorechecksum vlc firefox googlechrome 7zip}                          #business_it
            2{choco install -y --ignorechecksum vlc firefox googlechrome 7zip adobereader libreoffice}  #consumer
            3{choco install -y --ignorechecksum vlc firefox googlechrome 7zip libreoffice}              #consumer_it
            default{
                write-host "Option not recognized! Stopping..."
                exit 1
            }
        }
        if (-not ($?)){                #if installation failed, try one more time
          switch($type)
        {
            0{choco install -y --ignorechecksum vlc firefox googlechrome 7zip adobereader}              #business
            1{choco install -y --ignorechecksum vlc firefox googlechrome 7zip}                          #business_it
            2{choco install -y --ignorechecksum vlc firefox googlechrome 7zip adobereader libreoffice}  #consumer
            3{choco install -y --ignorechecksum vlc firefox googlechrome 7zip libreoffice}              #consumer_it
            default{
                write-host "Option not recognized! Stopping..."
                exit 1
            }
        }
        }
}
else{
  $null=[System.Windows.Forms.Messagebox]::Show("Failed to install Chocolatey Package Manager. Exiting..")
  exit 1
}
<#
# dynamic theme
Add-AppPackage "Microsoft.NET.Native.Framework.2.2.Appx"
Add-AppPackage "Microsoft.NET.Native.Runtime.2.2.Appx"
Add-AppPackage "Microsoft.Services.Store.Engagement.Appx"
Add-AppPackage "Microsoft.UI.Xaml.2.8_8.Appx"
Add-AppPackage "Microsoft.VCLibs.140.00.Appx"
Add-AppPackage "DynamicTheme.Msixbundle"
#>

winget install --accept-package-agreements --accept-source-agreements --source msstore "dynamic theme" 
start-sleep -m 500
$TargetPath =  "shell:AppsFolder\55888ChristopheLavalle.DynamicTheme_jdggxwd41xcr0!App"
$ShortcutFile = "$Home\Desktop\Dynamic Theme.lnk"
$WScriptShell = New-Object -ComObject WScript.Shell
$Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
$Shortcut.TargetPath = $TargetPath
$Shortcut.Save()


if ($gpu -like "*Nvidia*"){
  $null=[System.Windows.Forms.Messagebox]::Show("Nvidia GPU detected, installing Geforce Experience")
  choco install -y --ignorechecksum geforce-experience geforce-game-ready-driver
}

$blinfo = Get-Bitlockervolume
if($blinfo.EncryptionPercentage -eq '100' -and $blinfo.MountPoint -eq 'C:'){
    $null=[System.Windows.Forms.Messagebox]::Show("Bitlocker is enabled! Disabling..")
    Disable-BitLocker -MountPoint "C:"
}

if (-not (Test-Path -Path 'C:\Install' -PathType Container -errorAction SilentlyContinue)) {
    mkdir "C:\Install"
}
cp "src/oemlogo.bmp" "C:\Windows\System32"
cp "src/DynamicTheme.Msixbundle" "C:\Install"
cp "src/Netixx Helpdesk.exe" "C:\Install"
New-Item -Path "C:\Users\Public\Desktop\Netixx Helpdesk" -ItemType SymbolicLink -Value "C:\Install\Netixx Helpdesk.exe"
if($type -eq 1 -or 3)
{
    cp "src/readerdc_it_xa_crd_install.exe" "C:\Install"
    start-process -FilePath "C:\Install\readerdc_it_xa_crd_install.exe" -ArgumentList "--silent"
}

rm -errorAction SilentlyContinue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Angebote.lnk"
rm -errorAction SilentlyContinue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Firefox Privater Modus.lnk"
rm -errorAction SilentlyContinue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Amazon.com.lnk"
rm -errorAction SilentlyContinue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\HP Documentation.lnk"
rm -errorAction SilentlyContinue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\HP Sure Click Pro Secure Browser.lnk"
rm -errorAction SilentlyContinue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\TCO Certified.lnk"
rm -errorAction SilentlyContinue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Booking.lnk"
rm -errorAction SilentlyContinue "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\LastPass.lnk"
#rm -errorAction SilentlyContinue "C:\Users\Public\Desktop\VLC media player.lnk"
#rm -errorAction SilentlyContinue "C:\Users\Public\Desktop\Microsoft Edge.lnk"
#rm -errorAction SilentlyContinue "C:\Users\Public\Desktop\Adobe Acrobat.lnk"

if(Test-Path "C:\Users\Public\Desktop\LibreOffice 7.5.lnk" -PathType Leaf)
{
    $libreoffice = 1
    rm "C:\Users\Public\Desktop\LibreOffice 7.5.lnk"
    cp "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\LibreOffice 7.5\LibreOffice Calc.lnk" "C:\Users\Public\Desktop"
    cp "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\LibreOffice 7.5\LibreOffice Writer.lnk" "C:\Users\Public\Desktop"
    cp "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\LibreOffice 7.5\LibreOffice Impress.lnk" "C:\Users\Public\Desktop"
}


reg import "src/Logo_Info.reg"
reg import "src/icons.reg"
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "SystemUsesLightTheme" -Value 0
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -Value 1
#remove widgets from taskbar
reg add "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /f /v TaskbarDa /t REG_DWORD /d 0
#remove chat from taskbar
reg add "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /f /v TaskbarMn /t REG_DWORD /d 0
#change to small search bar
$RegKey = "registry::HKEY_USERS\$((whoami /user /fo csv | convertfrom-csv).sid)\Software\Microsoft\Windows\CurrentVersion\Search"
if (-not(Test-Path $RegKey )) {
    $reg = New-Item $RegKey -Force | Out-Null
    try { $reg.Handle.Close() } catch {}
}
New-ItemProperty $RegKey -Name "SearchboxTaskbarMode" -Value "1" -PropertyType Dword -Force

taskkill /f /im explorer.exe
$startmenu = Get-ChildItem "$startmenupath"
$filename = $startmenu -match "^[0-9]{8}$" |Select-Object -ExpandProperty name
if (Test-Path -Path "$startmenupath/start2.bin" -PathType Leaf -errorAction SilentlyContinue)
{
  rm -force "$startmenupath/start2.bin"
  cp -force "src/start2.bin" "$startmenupath"
}
else{
  rm -force "$startmenupath/start.bin"
  cp -force "src/start2.bin" "$startmenupath/start.bin"
}
#
#rm -force "$env:LOCALAPPDATA/Packages/Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy/LocalState/88000784"
#cp -force "src/start2.bin" "$env:LOCALAPPDATA/Packages/Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy/LocalState/"
rm -force "$startmenupath/$filename"
cp -force "src/88000784" "$startmenupath/$filename"

$whiteListPath = "src/whitelist.txt"
$whiteList = Get-Content $whitelistPath
$targetFolderPath = "$Home\Desktop"
$targetFolderFileCollection = Get-ChildItem $targetFolderPath
foreach ($file in $targetFolderFileCollection)
{
    if ($file.Name -notin $whiteList)
    {
        Remove-Item $file.FullName
    }
}

if($libreoffice){
  reg import "src\desktop_libreoffice.reg"
}
else{
reg import "src/desktop.reg"
}
sleep 2
explorer.exe

net start W32Time
W32tm /resync /force
echo "Uninstalling Office..."
src\officesetup.exe /configure "src\office.xml"
src/debloat.ps1
#Danke an Joachim
src/SetUserFTA.exe "src/assoc.txt"
#ii "C:/Install"
#src\ascii.exe "src\netixx_black.jpg -C -c"
Write-Host "`nGrundkonfiguration abgeschlossen"
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")