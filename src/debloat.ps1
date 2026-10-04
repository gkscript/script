#https://github.com/Raphire/Win11Debloat

# main.ps1 runs with 'Stop'; here one non-removable app must not abort the rest
$ErrorActionPreference = 'Continue'

Write-Progress -Activity "Uninstalling Adware" -Status "90% Complete:" -PercentComplete 85

function Remove-UWPApp {
    param(
        [Parameter(Mandatory)]
        [string[]]$AppxPackages
    )

    ForEach ($AppxPackage in $AppxPackages) {
        If (!((Get-AppxPackage -AllUsers -Name "$AppxPackage") -or (Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "$AppxPackage"))) {
            Write-Output "$AppxPackage was already removed or not found."
            Continue
        }

        Write-Output "Removing $AppxPackage from all users..."
        # Separate try blocks: if the per-user removal fails, still deprovision the package
        # so it doesn't come back for accounts created later
        try {
            Get-AppxPackage -AllUsers -Name "$AppxPackage" | Remove-AppxPackage -AllUsers -ErrorAction Stop
        }
        catch {
            Write-Output "Could not remove ${AppxPackage} for existing users: $($_.Exception.Message)"
        }
        try {
            Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "$AppxPackage" | Remove-AppxProvisionedPackage -Online -AllUsers -ErrorAction Stop
        }
        catch {
            Write-Output "Could not deprovision ${AppxPackage}: $($_.Exception.Message)"
        }
    }
}

function Import-TelemetryRegistry {
    try {
        $null = & "$env:SystemRoot\System32\reg.exe" import "$PSScriptRoot\disable_telemetry.reg" 2>&1
    } catch {
        Write-Output "Telemetry registry import warning: $_"
    }
}

# Desktop (Win32) OEM promo and trial software, matched on the uninstall-registry DisplayName -
# language-independent, unlike the winget name list this replaces. Only silent uninstalls run
# (Invoke-SilentUninstall: msiexec /qn or QuietUninstallString, with a timeout); the rest is
# logged. Deliberately not here: HP System Event Utility (Fn keys), HP Smart / myHP / HP PC
# Hardware Diagnostics, Intel Optane management (kept hardware tools), and "office" (the old
# winget name also matched Microsoft OneDrive).
$win32Bloat = @(
    '^HP Connection Optimizer'
    '^HP Documentation'
    '^HP Easy Clean'
    '^HP Privacy Settings'
    '^HP QuickDrop'
    'WebAdvisor'                                         # McAfee WebAdvisor / "WebAdvisor von McAfee"
    '^Dropbox.*(Promotion|Sonderaktion|Angebot|Offerta|Offer)'
    '^Lenovo Smart Meeting'
    '^Intel\(R\) Management and Security Status'
)
# Specific uninstall keys (registry key name)
$win32BloatKeys = @(
    '{25FB0D7A-ED1B-4663-809E-A54E8A4274B0}_is1'
)

function Remove-Win32Bloat {
    $entries = @(Get-UninstallEntries | Where-Object {
        $name = $_.DisplayName
        ($win32Bloat | Where-Object { $name -match $_ }) -or ($win32BloatKeys -contains $_.PSChildName)
    })
    foreach ($entry in $entries) {
        $result = Invoke-SilentUninstall -Entry $entry -TimeoutMinutes 10
        Write-Log "  Win32 bloat '$($entry.DisplayName)': $result"
    }
    if ($entries.Count -eq 0) { Write-Log "  No Win32 OEM promo software found" }
}

# Apps kept intentionally - too useful or disruptive to remove in enterprise
$excluded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@(
    'Microsoft.WindowsStore'
    'Microsoft.OneDrive'
    'Microsoft.Edge'
    'Microsoft.Edge XPFFTQ037JWMHS'
    'XPFFTQ037JWMHS'
    'Microsoft.Copilot'
    'XP9CXNGPPJ97XX'            # Copilot's Store ID in upstream's list
    'Microsoft.WindowsCalculator'
    'Microsoft.WindowsNotepad'
    'Microsoft.MSPaint'
    'Microsoft.Paint'
    'Microsoft.WindowsCamera'
    'Microsoft.ScreenSketch'
    'Microsoft.Windows.Photos'
    'Microsoft.WindowsTerminal'
    'Microsoft.RemoteDesktop'
    'Microsoft.WindowsAlarms'
    'Microsoft.MicrosoftStickyNotes'
    'MicrosoftCorporationII.QuickAssist'
    'Clipchamp.Clipchamp'
    # Marked "unsafe" upstream: breaks troubleshooters, Store/Photos UI, Xbox sign-in
    'Microsoft.GetHelp'
    'Microsoft.Xbox.TCUI'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxSpeechToTextOverlay'
) | ForEach-Object { $null = $excluded.Add($_) }

# OEM tools that must survive: BIOS/driver/firmware updates, Fn keys, battery care, audio and
# display control. Removing them costs the customer hardware features and future updates.
@(
    'AD2F1837.HPSupportAssistant'           # HP: BIOS and driver updates
    'AD2F1837.HPPowerManager'
    'AD2F1837.HPSystemInformation'
    'AD2F1837.HPPCHardwareDiagnosticsWindows'
    'AD2F1837.HPPrinterControl'             # HP Smart (printers)
    'AD2F1837.HPQuickTouch'
    'AD2F1837.myHP'
    'E046963F.LenovoCompanion'              # Lenovo Vantage: updates, battery conservation, hotkeys
    'LenovoCompanyLimited.LenovoVantageService'
    'E0469640.LenovoSettings'
    'E0469640.LenovoSmartCommunication'
    'DellInc.DellSupportAssistforPCs'       # Dell: driver, BIOS, firmware updates
    'DellInc.DellDigitalDelivery'           # software bought with the PC
    'DellInc.MyDell'
    'DellInc.DellHelpSupport'
    'AcerIncorporated.QuickAccess'          # Acer: Bluelight Shield, battery, keyboard light
    'SAMSUNGELECTRONICSCO.LTD.SamsungSettings1.5'     # Samsung: Fn keys, battery protection, backlight
    'SAMSUNGELECTRONICSCoLtd.GalaxyBook'              # Samsung Settings on ARM (Book4 Edge)
    'SAMSUNGELECTRONICSCO.LTD.SamsungSettingsRuntime'
    'SAMSUNGELECTRONICSCO.LTD.SamsungPCCleaner'       # Samsung Device Care: BIOS and driver updates
    'SAMSUNGELECTRONICSCO.LTD.SamsungUpdate'          # BIOS/driver updates up to 24H2
    'SAMSUNGELECTRONICSCO.LTD.SamsungRecovery'
    'DolbyLaboratories.DolbyAccess'                   # Dolby Atmos tuning (audio feature)
) | ForEach-Object { $null = $excluded.Add($_) }

# Always removed in addition to upstream's default list: OEM promo/trial apps, and the Widgets
# packages (upstream removes these three by default through its DisableWidgets feature)
$oemAndExtras = @(
    "*Speed Test*"
    "*Sway*"
    "*Keeper*"
    "4E6B5B3A.HUAWEIMobileCloud"
    "HuaweiPCManager"
    "AcerIncorporated.AcerCollection*"
    "AcerIncorporated.AcerPortal"
    "AcerIncorporated.UserExperienceProgram"
    "ASUSTeK.GamingCenterService"
    "ASUSTeK.ZenUIStoreROG"
    "DB6EA5DB.MediaSuiteEssentialsforDell"
    "DB6EA5DB.Power2GoforDell"
    "DB6EA5DB.PowerDirectorforDell"
    "DB6EA5DB.PowerMediaPlayerforDell"
    "DellInc.DellCustomerConnect"
    "DellInc.DellProductRegistration"
    "E046963F.LenovoSmartCare"
    "E0469640.LenovoExperienceImprovement"
    "E0469640.LenovoID"
    "5319275A.WhatsAppDesktop"
    "BytedancePte.Ltd.TikTok"
    "FACEBOOK.317180B0BB486"
    "FACEBOOK.FACEBOOK"
    "Facebook.Instagram*"
    "SpotifyAB.SpotifyMusic"
    "Microsoft.Appconnector"
    "Microsoft.CommsPhone"
    "Microsoft.ConnectivityStore"
    "Microsoft.Wallet"
    "Microsoft.WindowsPhone"
    "Microsoft.WindowsReadingList"
    "MicrosoftWindows.Client.WebExperience"
    "Microsoft.WidgetsPlatformRuntime"
    "Microsoft.StartExperiencesApp"
    # Samsung Galaxy Book: Galaxy ecosystem and promo apps (decision: always removed). Hardware
    # tools are in the keep-list above. Names from Microsoft's Store catalog (displaycatalog).
    "SAMSUNGELECTRONICSCO*.SamsungWelcome"             # Galaxy Book Experience (app catalog)
    "SAMSUNGELECTRONICSCO*.SmartSwitchforGalaxyBook"
    "SAMSUNGELECTRONICSCO*.Bixby"
    "SAMSUNGELECTRONICSCO*.StudioPlus"
    "SAMSUNGELECTRONICSCO*.SamsungStudio"
    "SAMSUNGELECTRONICSCO*.SamsungStudioForGalleryU"
    "SAMSUNGELECTRONICSCO*.PCGallery"
    "SAMSUNGELECTRONICSCO*.SamsungNotes"
    "SAMSUNGELECTRONICSCO*.SmartSelect"
    "SAMSUNGELECTRONICSCO*.SamsungQuickSearch"
    "SAMSUNGELECTRONICSCO*.SamsungScreenRecording"
    "SAMSUNGELECTRONICSCO*.SamsungQuickShare"
    "SAMSUNGELECTRONICSCO*.SamsungContinuityService"   # Galaxy Connect
    "SAMSUNGELECTRONICSCO*.MultiControl"
    "SAMSUNGELECTRONICSCO*.SecondScreen"
    "SAMSUNGELECTRONICSCO*.16297BCCB59BC"              # Camera Share
    "SAMSUNGELECTRONICSCO*.4438638898209"              # Storage Share
    "SAMSUNGELECTRONICSCO*.1412377A9806A"              # Link Sharing
    "SAMSUNGELECTRONICSCO*.SamsungMyDevices"           # Nearby devices
    "SAMSUNGELECTRONICSCO*.SamsungFlux"                # Samsung Flow
    "SAMSUNGELECTRONICSCO*.SamsungPhone"
    "SAMSUNGELECTRONICSCO*.SamsungFind"
    "SAMSUNGELECTRONICSCO*.SamsungCloudPlatformManag"
    "SAMSUNGELECTRONICSCO*.SamsungCloudBluetoothSync"
    "SAMSUNGELECTRONICSCO*.KnoxMatrixforWindows"
    "SAMSUNGELECTRONICSCO*.SamsungIntelligenceVoiceS"
    "SAMSUNGELECTRONICSCO*.SmartThingsWindows"
    "SAMSUNGELECTRONICSCO*.GalaxyBuds"
    "SAMSUNGELECTRONICSCO*.SamsungPass"
    "SAMSUNGELECTRONICSCO*.SamsungParentalControls"
    "SAMSUNGELECTRONICSCO*.SamsungAccount"
    "SAMSUNGELECTRONICSCO*.SamsungAccountPluginforSa"
    # Previously removed through the winget name list; optional upstream
    "Microsoft.OutlookForWindows"
    "Microsoft.windowscommunicationsapps"
    "Microsoft.Whiteboard"
    "Microsoft.People"
)

# Try to fetch the latest list from Win11Debloat
$appxToRemove = $null
try {
    Write-Output "Fetching latest bloatware list from Win11Debloat..."
    $response = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Raphire/Win11Debloat/master/Config/Apps.json" `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    # The file starts with a UTF-8 BOM; ConvertFrom-Json in PowerShell 5.1 fails on it
    $data = $response.Content.TrimStart([char]0xFEFF) | ConvertFrom-Json
    $fetched = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($app in $data.Apps) {
        $id = $app.AppId.Trim()
        if ($excluded.Contains($id)) { continue }
        # Same choice as upstream's defaults: only apps it removes by default. "Optional"
        # entries include OEM utilities and apps customers use (Media Player, Phone Link).
        if (-not $app.SelectedByDefault) { continue }
        if ($app.Recommendation -eq 'unsafe') { continue }
        if ($id -match '\s') { continue }
        if ($id -notmatch '\.' -and $id -notmatch '\*') { $id = "*$id*" }
        $null = $fetched.Add($id)
    }
    foreach ($id in $oemAndExtras) { $null = $fetched.Add($id) }

    if ($fetched.Count -gt 0) {
        $appxToRemove = [string[]]$fetched
        Write-Output "Using live Win11Debloat list ($($appxToRemove.Count) entries after exclusions and OEM merge)."
    }
} catch {
    Write-Output "Could not fetch Win11Debloat list ($($_.Exception.Message)) - using built-in fallback."
}

# Built-in fallback: upstream's default-selected apps as of 2026-10-04 (minus exclusions),
# plus the OEM extras above
if (-not $appxToRemove) {
    $appxToRemove = @(
        "*ACGMediaPlayer*"
        "*ActiproSoftwareLLC*"
        "*Asphalt8Airborne*"
        "*AutodeskSketchBook*"
        "*CaesarsSlotsFreeCasino*"
        "*COOKINGFEVER*"
        "*CyberLinkMediaSuiteEssentials*"
        "*DisneyMagicKingdoms*"
        "*DrawboardPDF*"
        "*Duolingo-LearnLanguagesforFree*"
        "*EclipseManager*"
        "*FarmVille2CountryEscape*"
        "*Flipboard*"
        "*HiddenCity*"
        "*iHeartRadio*"
        "*LinkedInforWindows*"
        "*MarchofEmpires*"
        "*MicrosoftTeams*"
        "*MSTeams*"
        "*NYTCrossword*"
        "*OneCalendar*"
        "*PandoraMediaInc*"
        "*PhototasticCollage*"
        "*PicsArt-PhotoStudio*"
        "*PolarrPhotoEditorAcademicEdition*"
        "*SlingTV*"
        "*TuneInRadio*"
        "*WinZipUniversal*"
        "4DF9E0F8.Netflix"
        "AdobeSystemsIncorporated.AdobePhotoshopExpress"
        "Amazon.com.Amazon"
        "AmazonVideo.PrimeVideo"
        "BytedancePte.Ltd.TikTok"
        "Disney.37853FC22B2CE"
        "FACEBOOK.FACEBOOK"
        "Facebook.Instagram"
        "flaregamesGmbH.RoyalRevolt"
        "HULULLC.HULUPLUS"
        "king.com.BubbleWitch3Saga"
        "king.com.CandyCrushSaga"
        "king.com.CandyCrushSodaSaga"
        "Microsoft.3DBuilder"
        "Microsoft.549981C3F5F10"
        "Microsoft.BingFinance"
        "Microsoft.BingFoodAndDrink"
        "Microsoft.BingHealthAndFitness"
        "Microsoft.BingNews"
        "Microsoft.BingSports"
        "Microsoft.BingTranslator"
        "Microsoft.BingTravel"
        "Microsoft.BingWeather"
        "Microsoft.Getstarted"
        "Microsoft.Messaging"
        "Microsoft.Microsoft3DViewer"
        "Microsoft.MicrosoftJournal"
        "Microsoft.MicrosoftOfficeHub"
        "Microsoft.MicrosoftPowerBIForWindows"
        "Microsoft.MicrosoftSolitaireCollection"
        "Microsoft.MixedReality.Portal"
        "Microsoft.NetworkSpeedTest"
        "Microsoft.News"
        "Microsoft.Office.OneNote"
        "Microsoft.Office.Sway"
        "Microsoft.OneConnect"
        "Microsoft.PCManager"
        "Microsoft.PowerAutomateDesktop"
        "Microsoft.Print3D"
        "Microsoft.SkypeApp"
        "Microsoft.Todos"
        "Microsoft.Windows.AIHub"
        "Microsoft.Windows.DevHome"
        "Microsoft.WindowsFeedbackHub"
        "Microsoft.WindowsMaps"
        "Microsoft.WindowsSoundRecorder"
        "Microsoft.XboxApp"
        "Microsoft.ZuneVideo"
        "MicrosoftCorporationII.MicrosoftFamily"
        "Sidia.LiveWallpaper"
        "SpotifyAB.SpotifyMusic"
    ) + $oemAndExtras
}

# Applies to the built-in fallback too, so the exclusions hold either way
$appxToRemove = @($appxToRemove | Where-Object { -not $excluded.Contains($_) })
Remove-UWPApp -AppxPackages $appxToRemove
Remove-Win32Bloat
Import-TelemetryRegistry
