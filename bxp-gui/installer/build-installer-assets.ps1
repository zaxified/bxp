#requires -Version 5.0
<#
.SYNOPSIS
Regenerate the NSIS installer's branding bitmaps from the canonical
icon source.

.DESCRIPTION
The MUI2 installer ([bxp-desktop.nsi]) needs two BMP files at fixed
dimensions:

  header.bmp   150 x 57   shown top-right on every wizard page
  welcome.bmp  164 x 314  shown left side of Welcome + Finish pages

Pass -Dark to emit the dark-theme variants instead (header-dark.bmp /
welcome-dark.bmp, dark canvas/gradient) used by the shipped -DDARK installer
build. Both sets are committed; the release script picks the -dark ones.

Both must be BMP3 (24-bit, no alpha) — MUI2 cannot render BMPv4 / BMPv5
correctly. We render them from `resources/icons/bxp-sand-80.png` (the
primary 512×512 icon source) onto a white (or dark) canvas using GDI+ via
System.Drawing — no external tooling required.

The .ico files reuse `bxp-gui/windows/runner/resources/app_icon.ico`
which Flutter generates from the same source, so a single icon swap
in `resources/icons/` propagates everywhere after a rerun of this
script + `scripts/build-icons.sh`.

.NOTES
Run from the monorepo root:

    pwsh -File bxp-gui/installer/build-installer-assets.ps1

Outputs `bxp-gui/installer/header.bmp` and `welcome.bmp`.
#>

[CmdletBinding()]
param(
    [string]$SourcePng = (Join-Path $PSScriptRoot "..\..\resources\icons\bxp-sand-80.png"),
    [string]$OutDir    = $PSScriptRoot,
    # Emit the dark-theme variants (header-dark.bmp / welcome-dark.bmp) used by
    # the -DDARK installer build. Default = light (header.bmp / welcome.bmp).
    [switch]$Dark
)

Add-Type -AssemblyName System.Drawing

# Theme palette. Dark values match the installer's MUI_BGCOLOR (#1E1E1E) so the
# bitmap edges blend seamlessly into the recolored page background.
$suffix = if ($Dark) { '-dark' } else { '' }
if ($Dark) {
    $headerBg     = [System.Drawing.Color]::FromArgb(255, 30, 30, 30)   # #1E1E1E
    $welcomeTop   = [System.Drawing.Color]::FromArgb(255, 42, 42, 42)   # #2A2A2A
    $welcomeBtm   = [System.Drawing.Color]::FromArgb(255, 30, 30, 30)   # #1E1E1E
} else {
    $headerBg     = [System.Drawing.Color]::White
    $welcomeTop   = [System.Drawing.Color]::FromArgb(255, 240, 220, 178)  # warm sand
    $welcomeBtm   = [System.Drawing.Color]::FromArgb(255, 252, 248, 240)  # near-white
}

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SourcePng)) {
    throw "Source icon not found: $SourcePng"
}

$src = [System.Drawing.Image]::FromFile((Resolve-Path $SourcePng).Path)
try {
    # ── header.bmp 150x57 ──────────────────────────────────────────────
    # Layout: white canvas, logo right-aligned at 50x50 (with 4 px pad).
    # NSIS shows this on the upper-right corner of every wizard page.
    $hw = 150; $hh = 57
    $hbmp = New-Object System.Drawing.Bitmap $hw, $hh
    $hg = [System.Drawing.Graphics]::FromImage($hbmp)
    try {
        $hg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $hg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $hg.Clear($headerBg)
        $logoSize = 49
        $padRight = 4
        $padTop   = ($hh - $logoSize) / 2
        $hg.DrawImage($src, ($hw - $logoSize - $padRight), $padTop,
                      $logoSize, $logoSize)
    } finally {
        $hg.Dispose()
    }
    $headerPath = Join-Path $OutDir "header$suffix.bmp"
    # SaveAs Bmp emits 24-bit BMP3 by default for non-alpha source — but
    # our source is RGBA, so first re-paint onto a 24bpp canvas to drop
    # the alpha channel. MUI2 renders BMP3 only.
    $h24 = New-Object System.Drawing.Bitmap $hw, $hh, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $h24g = [System.Drawing.Graphics]::FromImage($h24)
    try {
        $h24g.Clear($headerBg)
        $h24g.DrawImage($hbmp, 0, 0)
    } finally {
        $h24g.Dispose()
    }
    $h24.Save($headerPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $h24.Dispose()
    $hbmp.Dispose()
    Write-Host "  → $headerPath ($hw x $hh, 24-bit BMP)"

    # ── welcome.bmp 164x314 ────────────────────────────────────────────
    # Layout: subtle sand gradient top-to-bottom, logo centered top-third,
    # bottom area left blank for MUI2's title/subtitle text overlay.
    $ww = 164; $wh = 314
    $wbmp = New-Object System.Drawing.Bitmap $ww, $wh, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $wg = [System.Drawing.Graphics]::FromImage($wbmp)
    try {
        $wg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $wg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        # Vertical gradient (sand→near-white for light, charcoal→#1E1E1E for
        # dark). Picked to harmonise with the sand-80 icon without competing.
        $rect   = New-Object System.Drawing.Rectangle 0, 0, $ww, $wh
        $brush  = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $welcomeTop, $welcomeBtm, 90
        $wg.FillRectangle($brush, $rect)
        $brush.Dispose()
        # Logo centered horizontally, ~25% from top.
        $logoSize = 110
        $logoX = ($ww - $logoSize) / 2
        $logoY = 60
        $wg.DrawImage($src, $logoX, $logoY, $logoSize, $logoSize)
    } finally {
        $wg.Dispose()
    }
    $welcomePath = Join-Path $OutDir "welcome$suffix.bmp"
    $wbmp.Save($welcomePath, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $wbmp.Dispose()
    Write-Host "  → $welcomePath ($ww x $wh, 24-bit BMP)"
} finally {
    $src.Dispose()
}

Write-Host ""
Write-Host "Done. Bitmaps regenerated in $OutDir"
