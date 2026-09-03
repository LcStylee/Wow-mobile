; WoW Mobile — Windows installer (NSIS 3, stock MUI2, no extra plugins).
;
; Build (both defines are required):
;   makensis -DVERSION=v1.2.3 -DEXE=path/to/wowstreamd.exe installer/wowmobile.nsi
;
; VERSION stamps the branding text, the Add/Remove Programs entry, and the
; VIProductVersion; EXE is the release-built wowstreamd.exe to package.
; Output: WowMobile-Setup.exe next to this script.

Unicode true
SetCompressor /SOLID lzma

!ifndef VERSION
  !error "pass -DVERSION=vX.Y.Z on the makensis command line"
!endif
!ifndef EXE
  !error "pass -DEXE=path/to/wowstreamd.exe on the makensis command line"
!endif

; VIProductVersion needs a numeric X.Y.Z.W: strip the leading "v" and any
; pre-release suffix ("v0.1.0-rc1" -> "0.1.0"), then append ".0".
!searchparse /noerrors "${VERSION}" "v" VER_TRIPLET "-"
!ifndef VER_TRIPLET
  !searchparse /noerrors "${VERSION}" "v" VER_TRIPLET
!endif
!ifndef VER_TRIPLET
  !define VER_TRIPLET "0.0.0" ; unparsable VERSION: keep the build compiling
!endif

Name "WoW Mobile"
OutFile "WowMobile-Setup.exe"
InstallDir "$PROGRAMFILES64\WoW Mobile"
InstallDirRegKey HKLM "Software\WoW Mobile" "InstallDir"
RequestExecutionLevel admin
BrandingText "WoW Mobile ${VERSION}"

VIProductVersion "${VER_TRIPLET}.0"
VIAddVersionKey "ProductName" "WoW Mobile"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VER_TRIPLET}.0"
VIAddVersionKey "FileDescription" "WoW Mobile installer"
VIAddVersionKey "LegalCopyright" "MIT License — WoW Mobile project"

; ---------------------------------------------------------------- MUI2 pages
!include "MUI2.nsh"

!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\modern-uninstall.ico"
!define MUI_WELCOMEPAGE_TITLE "Welcome to WoW Mobile"
!define MUI_WELCOMEPAGE_TEXT "WoW Mobile streams World of Warcraft from this PC to your phone, with a touch interface built for playing.$\r$\n$\r$\nThis wizard installs the streaming app. On first launch it sets everything else up for you — in normal Windows dialogs — and shows a QR code to scan with your phone.$\r$\n$\r$\nClick Next to continue."
; The finish-page launch must NOT inherit this installer's elevation: an
; elevated first run would write config.json and the TLS certificate into the
; ELEVATING account's %APPDATA% (the wrong profile when a standard user typed
; an admin's credentials) and stream with admin rights. Launching through
; explorer.exe is the stock plugin-free de-elevation: explorer runs as the
; logged-on desktop user, so the app does too.
!define MUI_FINISHPAGE_RUN ""
!define MUI_FINISHPAGE_RUN_TEXT "Launch WoW Mobile"
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchAsDesktopUser

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS       ; the optional Desktop-shortcut checkbox
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function LaunchAsDesktopUser
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\wowstreamd.exe"'
FunctionEnd

; This is a per-machine install (admin, $PROGRAMFILES64, HKLM), so both sides
; run with: SetShellVarContext all — $SMPROGRAMS/$DESKTOP mean the all-users
; folders, not the elevating admin's profile; SetRegView 64 — HKLM writes land
; in the native 64-bit view instead of being redirected to WOW6432Node by
; this 32-bit installer process.
Function .onInit
  SetShellVarContext all
  SetRegView 64
  ; InstallDirRegKey is evaluated before .onInit and therefore reads the
  ; 32-bit view; re-read the remembered directory from the 64-bit view here.
  ; Only when $INSTDIR still holds the default — a /D= override on the
  ; command line, or a directory remembered through WOW6432Node redirection
  ; by an older setup, takes precedence.
  StrCmp $INSTDIR "$PROGRAMFILES64\WoW Mobile" 0 instDirDone
  ReadRegStr $0 HKLM "Software\WoW Mobile" "InstallDir"
  StrCmp $0 "" instDirDone
  StrCpy $INSTDIR $0
instDirDone:
FunctionEnd

Function un.onInit
  SetShellVarContext all
  SetRegView 64
FunctionEnd

; ------------------------------------------------------------------ install
Section "WoW Mobile (required)" SecMain
  SectionIn RO
  ; Running-instance guard (field report v0.3.2): the common upgrade path is
  ; running WowMobile-Setup.exe while the current wowstreamd.exe sits in the
  ; tray — overwriting a running exe fails the File write mid-install, and a
  ; surviving old instance then made the freshly launched new one die on the
  ; port bind. So: detect ANY running wowstreamd.exe (GUI tray or console
  ; mode alike) via tasklist, tell the user it will be closed, then close it
  ; GRACEFULLY first — taskkill WITHOUT /F sends WM_CLOSE, which reaches
  ; GUI-mode instances via the WowMobileTray window's handler as a clean quit
  ; (winui/tray_windows.go); a console-mode instance has no top-level window
  ; for taskkill to close, rides out the ~5 s wait, and is ended by the /F
  ; fallback. Declining aborts cleanly before anything is written.
  ; nsExec ships inside stock NSIS 3 (like the System plugin already used
  ; above): no extra plugins, and no console windows flashing.
  ; /SD IDOK makes silent (/S) installs close-and-continue, matching the
  ; unattended-upgrade expectation.
checkRunning:
  nsExec::ExecToStack '"$SYSDIR\cmd.exe" /c tasklist /NH /FI "IMAGENAME eq wowstreamd.exe" | "$SYSDIR\find.exe" /i "wowstreamd.exe"'
  Pop $0 ; find.exe exit code: 0 = a wowstreamd.exe process exists
  Pop $1 ; matched line (unused)
  StrCmp $0 "0" 0 notRunning
  MessageBox MB_OKCANCEL|MB_ICONEXCLAMATION \
      "WoW Mobile is running and will be closed to update.$\r$\n$\r$\nClick OK to close it and continue, or Cancel to abort the install." \
      /SD IDOK IDOK closeApp
  Abort "Install cancelled: WoW Mobile is still running."
closeApp:
  ; Graceful close: WM_CLOSE only, no /F.
  nsExec::ExecToStack '"$SYSDIR\taskkill.exe" /IM wowstreamd.exe'
  Pop $0
  Pop $1
  StrCpy $R1 0
waitClosed:
  Sleep 500
  nsExec::ExecToStack '"$SYSDIR\cmd.exe" /c tasklist /NH /FI "IMAGENAME eq wowstreamd.exe" | "$SYSDIR\find.exe" /i "wowstreamd.exe"'
  Pop $0
  Pop $1
  StrCmp $0 "0" 0 notRunning ; no longer listed: continue the install
  IntOp $R1 $R1 + 1
  IntCmp $R1 10 forceClose 0 forceClose
  Goto waitClosed
forceClose:
  ; Still alive after ~5 s of graceful waiting: force it, then give the file
  ; lock a moment to release. If even this fails, the File error check below
  ; still aborts cleanly instead of half-installing.
  nsExec::ExecToStack '"$SYSDIR\taskkill.exe" /F /IM wowstreamd.exe'
  Pop $0
  Pop $1
  Sleep 500
notRunning:
  SetOutPath "$INSTDIR"
  ; If the File write still fails (a console-mode wowstreamd.exe holds the
  ; file, or the user chose Ignore in NSIS's own retry dialog), abort rather
  ; than continue: stamping the NEW version's registry entries around the OLD
  ; binary would leave a silently inconsistent install.
  ClearErrors
  File "/oname=wowstreamd.exe" "${EXE}"
  IfErrors 0 fileWritten
  MessageBox MB_OK|MB_ICONSTOP \
      "Could not write $INSTDIR\wowstreamd.exe — it appears to be running.$\r$\nQuit WoW Mobile and run the installer again." \
      /SD IDOK
  Abort "Install failed: wowstreamd.exe is in use."
fileWritten:

  ; Start Menu shortcut (always).
  CreateDirectory "$SMPROGRAMS\WoW Mobile"
  CreateShortCut "$SMPROGRAMS\WoW Mobile\WoW Mobile.lnk" "$INSTDIR\wowstreamd.exe"

  ; Uninstaller + Add/Remove Programs entry.
  WriteRegStr HKLM "Software\WoW Mobile" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile" \
      "DisplayName" "WoW Mobile"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile" \
      "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile" \
      "Publisher" "WoW Mobile project"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile" \
      "DisplayIcon" "$INSTDIR\wowstreamd.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile" \
      "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile" \
      "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile" \
      "NoRepair" 1
  ; EstimatedSize (a REG_DWORD in KB) fills the Size column in Apps &
  ; Features. SectionGetSize yields this required section's install footprint
  ; in KB (essentially wowstreamd.exe); shortcuts and the uninstaller are
  ; rounding error next to it.
  SectionGetSize ${SecMain} $0
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile" \
      "EstimatedSize" $0
SectionEnd

Section "Desktop shortcut" SecDesktop
  CreateShortCut "$DESKTOP\WoW Mobile.lnk" "$INSTDIR\wowstreamd.exe"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "The WoW Mobile streaming app (wowstreamd.exe) and a Start Menu shortcut."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "Also put a WoW Mobile shortcut on the Desktop."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ---------------------------------------------------------------- uninstall
Section "Uninstall"
  ; A running wowstreamd.exe would make the Delete below fail silently and
  ; leave the binary and folder behind (with the registry entries already
  ; gone, Apps & Features would offer no retry). GUI-mode instances are
  ; detected by their tray window class — a hidden TOP-LEVEL window
  ; (tray_windows.go: CreateWindowExW with WS_POPUP; top-level so it receives
  ; the shell's TaskbarCreated broadcast), which plain FindWindow enumerates;
  ; older releases used a MESSAGE-ONLY window, so those are searched under
  ; HWND_MESSAGE ((HWND)-3) as well. Console-mode instances have no such
  ; window and are caught by the delete-verification below.
checkRunning:
  FindWindow $0 "WowMobileTray"
  StrCmp $0 0 0 stillRunning
  System::Call 'user32::FindWindowExW(p -3, p 0, w "WowMobileTray", p 0) p .r0'
  StrCmp $0 0 notRunning
stillRunning:
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION \
      "WoW Mobile is still running.$\r$\n$\r$\nQuit it (tray icon > Quit WoW Mobile), then click Retry." \
      /SD IDCANCEL IDRETRY checkRunning
  Abort "Uninstall cancelled: WoW Mobile is still running."
notRunning:

  ClearErrors
  Delete "$INSTDIR\wowstreamd.exe"
  IfErrors 0 deleted
  MessageBox MB_OK|MB_ICONSTOP \
      "Could not remove $INSTDIR\wowstreamd.exe — it appears to be running.$\r$\nQuit WoW Mobile and run the uninstaller again." \
      /SD IDOK
  Abort "Uninstall failed: wowstreamd.exe is in use."
deleted:
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  ; Shortcuts: current installs use the all-users context (un.onInit), but
  ; clean up the per-user context too for installs made by older setups.
  Delete "$SMPROGRAMS\WoW Mobile\WoW Mobile.lnk"
  RMDir "$SMPROGRAMS\WoW Mobile"
  Delete "$DESKTOP\WoW Mobile.lnk"
  SetShellVarContext current
  Delete "$SMPROGRAMS\WoW Mobile\WoW Mobile.lnk"
  RMDir "$SMPROGRAMS\WoW Mobile"
  Delete "$DESKTOP\WoW Mobile.lnk"
  SetShellVarContext all
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile"
  DeleteRegKey HKLM "Software\WoW Mobile"
  ; Older setups wrote through WOW6432Node redirection; drop that copy too.
  SetRegView 32
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\WoWMobile"
  DeleteRegKey HKLM "Software\WoW Mobile"
  SetRegView 64
  ; Deliberately kept: %APPDATA%\wowstreamd (remembered WoW/FFmpeg paths and
  ; the TLS certificate your phone already trusts). Delete it by hand for a
  ; truly clean slate.
  ; Literal %APPDATA% text on purpose: under SetShellVarContext all, NSIS's
  ; $APPDATA expands to C:\ProgramData, but wowstreamd stores per-user config
  ; in the Roaming profile (os.UserConfigDir).
  DetailPrint "Kept your settings and certificate in %APPDATA%\wowstreamd (delete manually if unwanted)."
SectionEnd
