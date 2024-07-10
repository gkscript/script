#https://github.com/LeDragoX/Win-Debloat-Tools 
    Write-Progress -Activity "Uninstalling Adware" -Status "90% Complete:" -PercentComplete 85
    $MSApps = @(
        # Default Windows 10+ apps
        "Microsoft.3DBuilder"                    # 3D Builder
        "Microsoft.549981C3F5F10"                # Cortana
        "Microsoft.Appconnector"
        "Microsoft.BingFinance"                  # Finance
        "Microsoft.BingFoodAndDrink"             # Food And Drink
        "Microsoft.BingHealthAndFitness"         # Health And Fitness
        "Microsoft.BingNews"                     # News
        "Microsoft.BingSports"                   # Sports
        "Microsoft.BingTranslator"               # Translator
        "Microsoft.BingTravel"                   # Travel
        "Microsoft.BingWeather"                  # Weather
        "Microsoft.CommsPhone"
        "Microsoft.ConnectivityStore"
        "Microsoft.GetHelp"
        "Microsoft.Getstarted"
        "Microsoft.Messaging"
        "Microsoft.Microsoft3DViewer"
        "Microsoft.MicrosoftOfficeHub"
        "Microsoft.MicrosoftPowerBIForWindows"
        #"Microsoft.MicrosoftSolitaireCollection" # MS Solitaire
        "Microsoft.MixedReality.Portal"
        "Microsoft.NetworkSpeedTest"
        "Microsoft.Office.OneNote"               # MS Office One Note
        "Microsoft.Office.Sway"
        "Microsoft.OneConnect"
        "Microsoft.People"                       # People
        #"Microsoft.MSPaint"                      # Paint 3D
        "Microsoft.Print3D"                      # Print 3D
        "Microsoft.SkypeApp"                     # Skype (Who still uses Skype? Use Discord)
        "Microsoft.Todos"                        # Microsoft To Do
        "Microsoft.Wallet"
        "Microsoft.Whiteboard"                   # Microsoft Whiteboard
        #"Microsoft.WindowsAlarms"                # Alarms
        "microsoft.windowscommunicationsapps"
        "Microsoft.WindowsFeedbackHub"           # Feedback Hub
        "Microsoft.WindowsMaps"                  # Maps
        "Microsoft.WindowsPhone"
        "Microsoft.WindowsReadingList"
        "Microsoft.WindowsSoundRecorder"         # Windows Sound Recorder
        "Microsoft.XboxApp"                      # Xbox Console Companion (Replaced by new App)
        "Microsoft.YourPhone"                    # Your Phone
        "Microsoft.ZuneMusic"                    # Groove Music / (New) Windows Media Player
        "Microsoft.ZuneVideo"                    # Movies & TV

        # Apps which other apps depend on
        #"Microsoft.Advertising.Xaml"

        # Default Windows 11 apps
        #"Clipchamp.Clipchamp"				     # Clipchamp – Video Editor
        "MicrosoftWindows.Client.WebExperience"  # Taskbar Widgets
        "MicrosoftTeams"                         # Microsoft Teams / Preview

        # <==========[ DIY ]==========> (Remove the # to Uninstall)

        # [DIY] Default apps i'll keep
        #"Microsoft.FreshPaint"             # Paint
        #"Microsoft.MicrosoftStickyNotes"   # Sticky Notes
        #"Microsoft.WindowsCalculator"      # Calculator
        #"Microsoft.WindowsCamera"          # Camera
        #"Microsoft.ScreenSketch"           # Snip and Sketch (now called Snipping tool, replaces the Win32 version in clean installs)
        "Microsoft.Windows.DevHome"        # Dev Home
        #"Microsoft.Windows.Photos"         # Photos / Video Editor

        # [DIY] Can't be reinstalled
        #"Microsoft.WindowsStore"           # Windows Store

        # Apps which cannot be removed using Remove-AppxPackage
        #"Microsoft.BioEnrollment"
        #"Microsoft.WindowsFeedback"        # Feedback Module
        #"Windows.ContactSupport"
    )

    $ThirdPartyApps = @(
        "*ACGMediaPlayer*"
        "*ActiproSoftwareLLC*"
        "*AdobePhotoshopExpress*"           # Adobe Photoshop Express
        "Amazon.com.Amazon"                 # Amazon Shop
        "*Asphalt8Airborne*"                # Asphalt 8 Airbone
        "*AutodeskSketchBook*"
        "*BubbleWitch3Saga*"                # Bubble Witch 3 Saga
        "*CaesarsSlotsFreeCasino*"
        "*CandyCrush*"                      # Candy Crush
        "*COOKINGFEVER*"
        "*CyberLinkMediaSuiteEssentials*"
        "*DisneyMagicKingdoms*"
        "*Dolby*"                           # Dolby Products (Like Atmos)
        "*DrawboardPDF*"
        "*Duolingo-LearnLanguagesforFree*"  # Duolingo
        "*EclipseManager*"
        "*FarmVille2CountryEscape*"
        "*FitbitCoach*"
        "*Flipboard*"                       # Flipboard
        "*HiddenCity*"
        "*Keeper*"
        "*LinkedInforWindows*"
        "*MarchofEmpires*"
        "*NYTCrossword*"
        "*OneCalendar*"
        "*PandoraMediaInc*"
        "*PhototasticCollage*"
        "*PicsArt-PhotoStudio*"
        "*PolarrPhotoEditorAcademicEdition*"
        "*RoyalRevolt*"                     # Royal Revolt
        "*Shazam*"
        "*Sidia.LiveWallpaper*"             # Live Wallpaper
        "*Speed Test*"
        "*Sway*"
        "*WinZipUniversal*"
        "*Wunderlist*"
        "*XING*"
    )

    $ManufacturerApps = @(
        # Dell Bloat
        "DB6EA5DB.MediaSuiteEssentialsforDell"
        "DB6EA5DB.PowerDirectorforDell"
        "DB6EA5DB.Power2GoforDell"
        "DB6EA5DB.PowerMediaPlayerforDell"
        #"DellInc.423703F9C7E0E"                # Alienware OC Controls
        #"DellInc.6066037A8FCF7"                # Alienware Control Center
        #"DellInc.AlienwareCommandCenter"       # Alienware Command Center
        #"DellInc.AlienwareFXAW*"               # Alienware FX AWxx versions
        #"DellInc.AlienwareFXAW21"              # Alienware FX AW21
        "DellInc.DellCustomerConnect"           # Dell Customer Connect
        "DellInc.DellDigitalDelivery"           # Dell Digital Delivery
        "DellInc.DellHelpSupport"
        "DellInc.DellProductRegistration"
        "DellInc.MyDell"                        # My Dell

        # HP
        ""
    )

    $SocialMediaApps = @(
        "5319275A.WhatsAppDesktop"  # WhatsApp
        "BytedancePte.Ltd.TikTok"   # TikTok
        "FACEBOOK.317180B0BB486"    # Messenger
        "FACEBOOK.FACEBOOK"         # Facebook
        "Facebook.Instagram*"       # Instagram / Beta
        "*Twitter*"                 # Twitter
        "*Viber*"
    )

    $StreamingServicesApps = @(
        "AmazonVideo.PrimeVideo"    # Amazon Prime Video
        "*Hulu*"
        "*iHeartRadio*"
        "*Netflix*"                 # Netflix
        "*Plex*"                    # Plex
        "*SlingTV*"
        "SpotifyAB.SpotifyMusic"    # Spotify
        "*TuneInRadio*"
    )

function Remove-UWPApp($AppxPackages) {

    Process {
        ForEach ($AppxPackage in $AppxPackages) {
            If (!((Get-AppxPackage -AllUsers -Name "$AppxPackage") -or (Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "$AppxPackage"))) {
                Write-Status "?", $TweakType -Status "$AppxPackage was already removed or not found..." -Warning
                Continue
            }

            Write-Status "Trying to remove $AppxPackage from ALL users..."
            Get-AppxPackage -AllUsers -Name "$AppxPackage" | Remove-AppxPackage -AllUsers
            Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "$AppxPackage" | Remove-AppxProvisionedPackage -Online -AllUsers
        }
    }
}

function Write-Status($Types) {
    
    $TypesDone = ""

    ForEach ($Type in $Types) {
        $TypesDone += "Removed $Type"
    }

    echo "$TypesDone".Trim()
}

function reg{
    reg import "src\disable_telemetry.reg"
}

function uninstallfun{

    $adware = "HP Connection Optimizer", "Microsoft Family", "Microsoft-Tipps", "Solitaire & Casual Games", "Microsoft Solitaire Collection", "Feedback-Hub", "Microsoft Kontakte", "Remotehilfe", "office", "WebAdvisor von McAfee", "Xbox", "HP Documentation", "Power Automate", "Mail und Kalender", "myHP", "Alexa", "HP Quickdrop", "HP Smart", "HP System Event Utility", "Dropbox-Sonderaktion", "skype", "Nachrichten", "Microsoft Whiteboard", "Intel(R) Management and Security Status", "HP Easy Clean", "HP Privacy Settings", "HP PC Hardware Diagnostics Windows", "optane", "officehub", "outlook for windows"

    foreach ($program in $adware) {
        winget uninstall --accept-source-agreements --source winget $program
    }
}


function chrome{
    taskkill /f /im chrome.exe
    src/AutoHotkey32.exe src/chrome.ahk
    winget uninstall "tabellen"
    winget uninstall "präsentationen"
    winget uninstall "youtube"
    winget uninstall "google drive"
    winget uninstall "gmail"
    winget uninstall "dokumente"
    taskkill /f /im autohotkey32.exe
}

Remove-UWPApp -AppxPackages $MSApps
Remove-UWPApp -AppxPackages $ThirdPartyApps
Remove-UWPApp -AppxPackages $ManufacturerApps
Remove-UWPApp -AppxPackages $SocialMediaApps
Remove-UWPApp -AppxPackages $StreamingServicesApps
uninstallfun
$null = winget list -q "gmail"
if ($?){
chrome
}

