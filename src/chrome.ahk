SetTitleMatchMode "Regex"
SetTitleMatchMode "Slow"

Loop
{
sleep 200
if Winexist("ahk_class Chrome_WidgetWin_1") && Winexist("ahk_exe chrome.exe")
{
	WinActivate
	sendinput "{Enter}"
}
}