; NSIS installer for BXP Desktop on Windows.
;
; Build with: makensis -DAPPVERSION=0.2.0 -DVERSIONTAG=v0.2.0 \
;             -DSTAGEDIR=path\to\stage bxp-desktop.nsi
;
; Outputs: bxp-desktop-<VERSIONTAG>-windows-x86_64-setup.exe in OUTDIR.
; APPVERSION is the bare SemVer string (NSIS Version property);
; VERSIONTAG is the release-tag-shaped string used in artifact filenames
; so they line up with the Linux/macOS bundles (bxp-desktop-v0.2.0-...).
;
; The installer is silent-capable via /S — UpdaterService relies on this
; to perform unattended self-updates.
;
; UI: Modern UI 2 (built-in NSIS macro pack). Branding bitmaps live in
; the same directory as this script and are regenerated from
; resources/icons/ via `build-installer-assets.ps1`.

!ifndef APPVERSION
  !define APPVERSION "0.0.0"
!endif
!ifndef VERSIONTAG
  !define VERSIONTAG "${APPVERSION}"
!endif
!ifndef STAGEDIR
  !error "STAGEDIR must be defined (path to staged Flutter Windows release)"
!endif
!ifndef OUTDIR
  !define OUTDIR "."
!endif

!define APPNAME "BXP GUI"
!define COMPANYNAME "io.github.bxp"
!define DESCRIPTION "Broker eXchange Parser — desktop config editor"
!define INSTALLDIR_DEFAULT "$PROGRAMFILES64\BXP"

Name "${APPNAME}"
OutFile "${OUTDIR}\bxp-desktop-${VERSIONTAG}-windows-x86_64-setup.exe"
InstallDir "${INSTALLDIR_DEFAULT}"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

; ── Modern UI 2 ──────────────────────────────────────────────────────────
;
; Reuses Flutter's app_icon.ico (sand-80 source via build-icons.sh) for
; both setup.exe and Uninstall.exe. Branding BMPs are 24-bit BMP3 — MUI2
; cannot render BMPv4/v5 correctly. See `build-installer-assets.ps1` for
; regeneration when the source icon changes.
!include "MUI2.nsh"

!define MUI_ICON   "..\windows\runner\resources\app_icon.ico"
!define MUI_UNICON "..\windows\runner\resources\app_icon.ico"

!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP        "header.bmp"
!define MUI_WELCOMEFINISHPAGE_BITMAP  "welcome.bmp"

; Tighten the welcome/finish page text — MUI2 defaults read like a
; generic Win 95 Setup wizard otherwise.
!define MUI_WELCOMEPAGE_TITLE   "Install ${APPNAME}"
!define MUI_WELCOMEPAGE_TEXT    "This wizard installs ${APPNAME} ${APPVERSION} on your computer.$\r$\n$\r$\n${DESCRIPTION}.$\r$\n$\r$\nClick Next to continue."
!define MUI_FINISHPAGE_TITLE    "${APPNAME} installed"
!define MUI_FINISHPAGE_TEXT     "${APPNAME} ${APPVERSION} has been installed on your computer.$\r$\n$\r$\nClick Finish to close the wizard."
!define MUI_FINISHPAGE_RUN      "$INSTDIR\bxp-gui.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Run ${APPNAME} now"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_WELCOME
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "English"

; ── Install / Uninstall sections ─────────────────────────────────────────

Section "Install"
    SetOutPath "$INSTDIR"
    File /r "${STAGEDIR}\*.*"

    ; Start menu + uninstall registry
    CreateDirectory "$SMPROGRAMS\${APPNAME}"
    CreateShortCut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" \
        "$INSTDIR\bxp-gui.exe"
    CreateShortCut "$SMPROGRAMS\${APPNAME}\Uninstall.lnk" \
        "$INSTDIR\Uninstall.exe"

    WriteUninstaller "$INSTDIR\Uninstall.exe"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "DisplayName" "${APPNAME}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "DisplayVersion" "${APPVERSION}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "Publisher" "${COMPANYNAME}"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "InstallLocation" "$INSTDIR"

    ; Silent-install relaunch hook — UpdaterService runs setup.exe with /S
    ; and exits the running app. After install we relaunch the GUI so the
    ; user sees the new version come up automatically. The MUI2 Finish
    ; page's MUI_FINISHPAGE_RUN handles the interactive case; this branch
    ; covers the silent path that skips the wizard.
    IfSilent 0 +2
        Exec '"$INSTDIR\bxp-gui.exe"'
SectionEnd

Section "Uninstall"
    Delete "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk"
    Delete "$SMPROGRAMS\${APPNAME}\Uninstall.lnk"
    RMDir "$SMPROGRAMS\${APPNAME}"

    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"

    RMDir /r "$INSTDIR"
SectionEnd
