Unicode True

Name "Netixx Grundkonfiguration"
!ifdef OUTFILE
  OutFile "${OUTFILE}"
!else
  OutFile "gk-script.exe"
!endif

InstallDir "$TEMP\NetixxSetup"
RequestExecutionLevel admin
Icon "src\netixx.ico"

SetCompressor /SOLID lzma

ShowInstDetails nevershow
AutoCloseWindow true

Page instfiles

Section
  RMDir /r "$INSTDIR"
  SetOutPath "$INSTDIR"
  SetOverwrite try
  File "launch.bat"
  File /r "src"
  Exec '"$INSTDIR\launch.bat"'
SectionEnd
