; NSIS installer for BXP Desktop on Windows.
;
; Build with: makensis -DAPPVERSION=0.2.0 -DVERSIONTAG=v0.2.0 \
;             -DSTAGEDIR=path\to\stage bxp-desktop.nsi
;
; Outputs: bxp-desktop-windows-x86_64.exe in OUTDIR. The artifact name is
; version-less so the README can link to a stable GitHub release URL
; (releases/latest/download/bxp-desktop-windows-x86_64.exe); the version
; lives in the release tag and in the NSIS Version property.
; APPVERSION is the bare SemVer string (NSIS Version property);
; VERSIONTAG is the release-tag-shaped string used in install metadata.
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

!define APPNAME "BXP"
!define COMPANYNAME "io.github.bxp"
; Plain ASCII hyphen, not em-dash. NSIS processes this script in ANSI
; mode (codepage interpretation depends on the build host) and a UTF-8
; em-dash here renders as three garbage bytes on the Welcome page.
!define DESCRIPTION "Broker eXchange Parser - desktop config editor"
; Per-user install (mirrors the Linux AppImage / macOS ~/Applications model):
; LOCALAPPDATA needs no admin rights, so the silent self-updater's
; non-elevated Process.start can launch setup.exe without hitting
; ERROR_ELEVATION_REQUIRED (the old $PROGRAMFILES64 + RequestExecutionLevel
; admin combo could not elevate via CreateProcess and silently failed).
!define INSTALLDIR_DEFAULT "$LOCALAPPDATA\Programs\bxp-gui"

Name "${APPNAME}"
OutFile "${OUTDIR}\bxp-desktop-windows-x86_64.exe"
InstallDir "${INSTALLDIR_DEFAULT}"
RequestExecutionLevel user
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

    ; Self-heal for a same-directory update (per-user 0.2.5 → 0.2.6+): the
    ; silent updater launches us while the old bxp-gui.exe + its loaded DLLs
    ; are still running, and Windows forbids OVERWRITING a running exe / loaded
    ; DLL. It does, however, permit RENAMING one — the old process keeps running
    ; from the renamed handle. So move the locked binaries aside before File /r
    ; writes fresh copies into the vacated slots. (No-op on a fresh install:
    ; nothing to rename.) Clean any stale *.old from a prior update first.
    Delete "$INSTDIR\bxp-gui.exe.old"
    IfFileExists "$INSTDIR\bxp-gui.exe" 0 +2
        Rename "$INSTDIR\bxp-gui.exe" "$INSTDIR\bxp-gui.exe.old"
    Delete "$INSTDIR\flutter_windows.dll.old"
    IfFileExists "$INSTDIR\flutter_windows.dll" 0 +2
        Rename "$INSTDIR\flutter_windows.dll" "$INSTDIR\flutter_windows.dll.old"
    Delete "$INSTDIR\bxp-gui-bridge.dll.old"
    IfFileExists "$INSTDIR\bxp-gui-bridge.dll" 0 +2
        Rename "$INSTDIR\bxp-gui-bridge.dll" "$INSTDIR\bxp-gui-bridge.dll.old"

    File /r "${STAGEDIR}\*.*"

    ; Best-effort removal of the swapped-aside binaries. They are still locked
    ; by the exiting old process now, so /REBOOTOK schedules removal at reboot;
    ; the relaunched new app also deletes leftover *.old on startup.
    Delete /REBOOTOK "$INSTDIR\bxp-gui.exe.old"
    Delete /REBOOTOK "$INSTDIR\flutter_windows.dll.old"
    Delete /REBOOTOK "$INSTDIR\bxp-gui-bridge.dll.old"

    ; Start menu + uninstall registry
    CreateDirectory "$SMPROGRAMS\${APPNAME}"
    CreateShortCut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" \
        "$INSTDIR\bxp-gui.exe"
    CreateShortCut "$SMPROGRAMS\${APPNAME}\Uninstall.lnk" \
        "$INSTDIR\Uninstall.exe"

    WriteUninstaller "$INSTDIR\Uninstall.exe"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "DisplayName" "${APPNAME}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "DisplayVersion" "${APPVERSION}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "Publisher" "${COMPANYNAME}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" \
        "InstallLocation" "$INSTDIR"

    ; Migration note (admin → per-user). A user upgrading from a pre-0.2.5
    ; admin install in $PROGRAMFILES64\bxp-gui can't have that copy removed
    ; from here: this installer runs non-elevated, so it cannot touch Program
    ; Files or the HKLM uninstall key. The new per-user install supersedes it
    ; (shortcut + HKCU entry point here); the old copy is left orphaned. That
    ; is acceptable for now (user base ~0); full cleanup would need a one-time
    ; elevation and is deferred. The current-user Start-Menu shortcut above is
    ; written to the same $SMPROGRAMS\${APPNAME} path the old installer used,
    ; so it is overwritten to point at the new location.

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

    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"

    RMDir /r "$INSTDIR"
SectionEnd
