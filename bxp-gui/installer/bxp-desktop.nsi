; NSIS installer for BXP Desktop on Windows.
;
; Build with: makensis -DAPPVERSION=0.2.0 -DSTAGEDIR=path\to\stage bxp-desktop.nsi
;
; Outputs: bxp-desktop-<version>-windows-x86_64-setup.exe in the OUTDIR
; environment variable (defaulted to the script directory).
;
; The installer is silent-capable via /S — UpdaterService relies on this
; to perform unattended self-updates.

!ifndef APPVERSION
  !define APPVERSION "0.0.0"
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
OutFile "${OUTDIR}\bxp-desktop-${APPVERSION}-windows-x86_64-setup.exe"
InstallDir "${INSTALLDIR_DEFAULT}"
RequestExecutionLevel admin
SetCompressor /SOLID lzma

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

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
    ; user sees the new version come up automatically.
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
