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
        try {
            Get-AppxPackage -AllUsers -Name "$AppxPackage" | Remove-AppxPackage -AllUsers -ErrorAction Stop
            Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "$AppxPackage" | Remove-AppxProvisionedPackage -Online -AllUsers -ErrorAction Stop
        }
        catch {
            Write-Output "Could not remove ${AppxPackage}: $($_.Exception.Message)"
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

function uninstallfun {
    $adware = "HP Connection Optimizer", "Microsoft Family", "Microsoft-Tipps", "Microsoft Solitaire Collection", "Feedback-Hub", "Microsoft Kontakte", "office", "WebAdvisor von McAfee", "Xbox", "HP Documentation", "Power Automate", "Mail und Kalender", "myHP", "Alexa", "HP Quickdrop", "HP Smart", "HP System Event Utility", "Dropbox-Sonderaktion", "skype", "Nachrichten", "Microsoft Whiteboard", "Intel(R) Management and Security Status", "HP Easy Clean", "HP Privacy Settings", "HP PC Hardware Diagnostics Windows", "optane", "officehub", "outlook for windows", "Lenovo Smart Meeting", "{25FB0D7A-ED1B-4663-809E-A54E8A4274B0}_is1"

    foreach ($program in $adware) {
        winget uninstall --accept-source-agreements --source winget $program
    }
}

function Remove-ChromeWebApps {
    taskkill /f /im chrome.exe
    & "$PSScriptRoot\AutoHotkey32.exe" "$PSScriptRoot\chrome.ahk"
    winget uninstall "tabellen"
    winget uninstall "pr$([char]0xE4)sentationen"
    winget uninstall "youtube"
    winget uninstall "google drive"
    winget uninstall "gmail"
    winget uninstall "dokumente"
    taskkill /f /im autohotkey32.exe
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

# OEM bloat and older/alternate package IDs not covered by Win11Debloat
$oemAndExtras = @(
    "*Dolby*"
    "*Speed Test*"
    "*Sway*"
    "*Keeper*"
    "*AsusUpdate*"
    "4E6B5B3A.HUAWEIMobileCloud"
    "HuaweiPCManager"
    "AcerIncorporated.AcerCollection*"
    "AcerIncorporated.AcerPortal"
    "AcerIncorporated.QuickAccess"
    "AcerIncorporated.UserExperienceProgram"
    "ASUSTeK.GamingCenterService"
    "ASUSTeK.ZenUIStoreROG"
    "B9EACED6.AsusROGLiveService"
    "DB6EA5DB.MediaSuiteEssentialsforDell"
    "DB6EA5DB.Power2GoforDell"
    "DB6EA5DB.PowerDirectorforDell"
    "DB6EA5DB.PowerMediaPlayerforDell"
    "DellInc.DellCustomerConnect"
    "DellInc.DellHelpSupport"
    "DellInc.DellProductRegistration"
    "DellInc.MyDell"
    "E046963F.LenovoSmartCare"
    "E0469640.LenovoExperienceImprovement"
    "E0469640.LenovoID"
    "E0469640.LenovoSettings"
    "E0469640.LenovoSmartCommunication"
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
)

# Try to fetch the latest list from Win11Debloat
$appxToRemove = $null
try {
    Write-Output "Fetching latest bloatware list from Win11Debloat..."
    $response = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Raphire/Win11Debloat/master/Config/Apps.json" `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    $data = $response.Content | ConvertFrom-Json
    $fetched = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($app in $data.Apps) {
        $id = $app.AppId.Trim()
        if ($excluded.Contains($id)) { continue }
        # Never auto-remove what upstream flags unsafe, including entries added after this review
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

# Built-in fallback - merged from Win11Debloat + OEM extras as of 2026-05-07
if (-not $appxToRemove) {
    $appxToRemove = @(
        "*ACGMediaPlayer*"
        "*ActiproSoftwareLLC*"
        "*Asphalt8Airborne*"
        "*AsusUpdate*"
        "*AutodeskSketchBook*"
        "*CaesarsSlotsFreeCasino*"
        "*COOKINGFEVER*"
        "*CyberLinkMediaSuiteEssentials*"
        "*Disney*"
        "*DisneyMagicKingdoms*"
        "*Dolby*"
        "*DrawboardPDF*"
        "*Duolingo-LearnLanguagesforFree*"
        "*EclipseManager*"
        "*Facebook*"
        "*FarmVille2CountryEscape*"
        "*fitbit*"
        "*Flipboard*"
        "*HiddenCity*"
        "*iHeartRadio*"
        "*Instagram*"
        "*Keeper*"
        "*LinkedInforWindows*"
        "*MarchofEmpires*"
        "*MicrosoftTeams*"
        "*MSTeams*"
        "*Netflix*"
        "*NYTCrossword*"
        "*OneCalendar*"
        "*PandoraMediaInc*"
        "*PhototasticCollage*"
        "*PicsArt-PhotoStudio*"
        "*Plex*"
        "*PolarrPhotoEditorAcademicEdition*"
        "*Shazam*"
        "*SlingTV*"
        "*Speed Test*"
        "*Spotify*"
        "*Sway*"
        "*TikTok*"
        "*TuneInRadio*"
        "*Twitter*"
        "*Viber*"
        "*WinZipUniversal*"
        "*Wunderlist*"
        "*XING*"
        "4E6B5B3A.HUAWEIMobileCloud"
        "5319275A.WhatsAppDesktop"
        "AcerIncorporated.AcerCollection*"
        "AcerIncorporated.AcerPortal"
        "AcerIncorporated.QuickAccess"
        "AcerIncorporated.UserExperienceProgram"
        "AD2F1837.HPAIExperienceCenter"
        "AD2F1837.HPConnectedMusic"
        "AD2F1837.HPConnectedPhotopoweredbySnapfish"
        "AD2F1837.HPDesktopSupportUtilities"
        "AD2F1837.HPEasyClean"
        "AD2F1837.HPFileViewer"
        "AD2F1837.HPJumpStarts"
        "AD2F1837.HPPCHardwareDiagnosticsWindows"
        "AD2F1837.HPPowerManager"
        "AD2F1837.HPPrinterControl"
        "AD2F1837.HPPrivacySettings"
        "AD2F1837.HPQuickDrop"
        "AD2F1837.HPQuickTouch"
        "AD2F1837.HPRegistration"
        "AD2F1837.HPSupportAssistant"
        "AD2F1837.HPSureShieldAI"
        "AD2F1837.HPSystemInformation"
        "AD2F1837.HPWelcome"
        "AD2F1837.HPWorkWell"
        "AD2F1837.myHP"
        "AdobeSystemsIncorporated.AdobePhotoshopExpress"
        "Amazon.com.Amazon"
        "AmazonVideo.PrimeVideo"
        "ASUSTeK.GamingCenterService"
        "ASUSTeK.ZenUIStoreROG"
        "B9EACED6.AsusROGLiveService"
        "BytedancePte.Ltd.TikTok"

        "DB6EA5DB.MediaSuiteEssentialsforDell"
        "DB6EA5DB.Power2GoforDell"
        "DB6EA5DB.PowerDirectorforDell"
        "DB6EA5DB.PowerMediaPlayerforDell"
        "DellInc.DellCustomerConnect"
        "DellInc.DellDigitalDelivery"
        "DellInc.DellHelpSupport"
        "DellInc.DellMobileConnect"
        "DellInc.DellProductRegistration"
        "DellInc.DellSupportAssistforPCs"
        "DellInc.MyDell"
        "E046963F.LenovoCompanion"
        "E046963F.LenovoSmartCare"
        "E0469640.LenovoExperienceImprovement"
        "E0469640.LenovoID"
        "E0469640.LenovoSettings"
        "E0469640.LenovoSmartCommunication"
        "FACEBOOK.317180B0BB486"
        "FACEBOOK.FACEBOOK"
        "Facebook.Instagram*"
        "HuaweiPCManager"
        "HULULLC.HULUPLUS"
        "king.com.BubbleWitch3Saga"
        "king.com.CandyCrushSaga"
        "king.com.CandyCrushSodaSaga"
        "LenovoCompanyLimited.LenovoVantageService"
        "Microsoft.3DBuilder"
        "Microsoft.549981C3F5F10"
        "Microsoft.Appconnector"
        "Microsoft.BingFinance"
        "Microsoft.BingFoodAndDrink"
        "Microsoft.BingHealthAndFitness"
        "Microsoft.BingNews"
        "Microsoft.BingSearch"
        "Microsoft.BingSports"
        "Microsoft.BingTranslator"
        "Microsoft.BingTravel"
        "Microsoft.BingWeather"
        "Microsoft.CommsPhone"
        "Microsoft.ConnectivityStore"
        "Microsoft.GamingApp"
        "Microsoft.GetHelp"
        "Microsoft.Getstarted"
        "Microsoft.M365Companions"
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
        "Microsoft.OutlookForWindows"
        "Microsoft.PCManager"
        "Microsoft.People"
        "Microsoft.PowerAutomateDesktop"
        "Microsoft.Print3D"
        "Microsoft.SkypeApp"
        "Microsoft.StartExperiencesApp"
        "Microsoft.Todos"
        "Microsoft.Wallet"
        "Microsoft.Whiteboard"
        "Microsoft.WidgetsPlatformRuntime"
        "Microsoft.Windows.AIHub"
        "Microsoft.Windows.DevHome"
        "Microsoft.windowscommunicationsapps"
        "Microsoft.WindowsFeedbackHub"
        "Microsoft.WindowsMaps"
        "Microsoft.WindowsPhone"
        "Microsoft.WindowsReadingList"
        "Microsoft.WindowsSoundRecorder"
        "Microsoft.Xbox.TCUI"
        "Microsoft.XboxApp"
        "Microsoft.XboxGameOverlay"
        "Microsoft.XboxGamingOverlay"
        "Microsoft.XboxIdentityProvider"
        "Microsoft.XboxSpeechToTextOverlay"
        "Microsoft.YourPhone"
        "Microsoft.ZuneMusic"
        "Microsoft.ZuneVideo"
        "MicrosoftCorporationII.MicrosoftFamily"
        "MicrosoftWindows.Client.WebExperience"
        "MicrosoftWindows.CrossDevice"
        "Sidia.LiveWallpaper"
        "SpotifyAB.SpotifyMusic"
    )
}

# Applies to the built-in fallback too, so the exclusions hold either way
$appxToRemove = @($appxToRemove | Where-Object { -not $excluded.Contains($_) })
Remove-UWPApp -AppxPackages $appxToRemove
uninstallfun
Import-TelemetryRegistry
$gmailCheck = & winget list -q "gmail" --accept-source-agreements 2>&1
if ($gmailCheck -match "gmail") {
    Remove-ChromeWebApps
}
