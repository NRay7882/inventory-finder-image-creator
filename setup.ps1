<#
.SYNOPSIS
    One-time setup for inventory-finder-image-creator.

.DESCRIPTION
    Installs Raspberry Pi Imager and downloads the SSH keys needed to create
    station images. Run this once before using create-image.ps1.

    Keys are fetched automatically and saved to %USERPROFILE%\.ssh\.
    Re-run with -Refresh at any time to pick up rotated keys.

.PARAMETER Refresh
    Re-download keys even if they are already present locally.

.EXAMPLE
    .\setup.ps1
    First-time setup - installs Imager and fetches keys.

.EXAMPLE
    .\setup.ps1 -Refresh
    Re-downloads keys (use after key rotation).
#>
[CmdletBinding()]
param(
    [switch]$Refresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Key distribution ──────────────────────────────────────────────────────────
# GitHub username and secret gist ID containing the fleet keys.
# The gist must have two files:
#   inventory_deploy    - fleet deploy private key
#   id_ed25519.pub      - admin SSH public key
#
# Raw URL format (no commit hash = always returns latest version):
#   https://gist.githubusercontent.com/{GistUser}/{GistId}/raw/{filename}
$GistUser = "NRay7882"
$GistId   = ""   # fill in your gist ID

# ── Helpers ───────────────────────────────────────────────────────────────────

function Step { param([string]$m) Write-Host "  -> $m" -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host "  OK $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "  ** $m" -ForegroundColor Yellow }

function Find-RpiImager {
    @(
        "$env:ProgramFiles\Raspberry Pi Ltd\Imager\rpi-imager.exe",
        "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager.exe",
        "${env:ProgramFiles(x86)}\Raspberry Pi Imager\rpi-imager.exe",
        "$env:LOCALAPPDATA\Programs\Raspberry Pi Imager\rpi-imager.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Get-GistFile {
    param([string]$Filename)
    $url = "https://gist.githubusercontent.com/$GistUser/$GistId/raw/$Filename"
    try {
        return Invoke-RestMethod -Uri $url -TimeoutSec 15
    } catch {
        return $null
    }
}

# ── Header ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Inventory Image Creator - Setup" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

$allOk       = $true
$fetchEnabled = $GistId -ne ""

# ── Step 1: Raspberry Pi Imager ───────────────────────────────────────────────

Step "Checking for Raspberry Pi Imager..."

$imager = Find-RpiImager
if ($imager) {
    Ok "Raspberry Pi Imager found"
} else {
    Warn "Raspberry Pi Imager not found."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $answer = Read-Host "  Install via winget? [y/N]"
        if ($answer -match "^[Yy]$") {
            Step "Installing..."
            try {
                winget install --id RaspberryPiFoundation.RaspberryPiImager `
                    --silent --accept-package-agreements --accept-source-agreements
                $imager = Find-RpiImager
                if ($imager) {
                    Ok "Raspberry Pi Imager installed"
                } else {
                    Warn "Install may need a terminal restart to be detected."
                    $allOk = $false
                }
            } catch {
                Warn "Install failed. Download from: https://www.raspberrypi.com/software/"
                $allOk = $false
            }
        } else {
            Warn "Skipped. Download from: https://www.raspberrypi.com/software/"
            $allOk = $false
        }
    } else {
        Warn "Download from: https://www.raspberrypi.com/software/"
        $allOk = $false
    }
}

# ── Step 2: Fleet deploy key ──────────────────────────────────────────────────

Write-Host ""
$sshDir    = "$env:USERPROFILE\.ssh"
$deployKey = "$sshDir\inventory_deploy"
$adminKey  = "$sshDir\id_ed25519.pub"

Step "Checking for fleet deploy key..."

if ((Test-Path $deployKey) -and -not $Refresh) {
    Ok "Fleet deploy key present"
} elseif ($fetchEnabled) {
    Step "Fetching fleet deploy key..."
    $content = Get-GistFile "inventory_deploy"
    if ($content -and ($content -match "BEGIN.*KEY")) {
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        [IO.File]::WriteAllText($deployKey, $content.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
        icacls $deployKey /inheritance:r /grant:r "${env:USERNAME}:(R,W)" 2>$null | Out-Null
        Ok "Fleet deploy key saved to $deployKey"
    } else {
        Warn "Could not fetch fleet deploy key. Contact your system administrator."
        $allOk = $false
    }
} else {
    Warn "Fleet deploy key not found at $deployKey"
    if (-not $fetchEnabled) {
        Write-Host "  GistId is not configured in setup.ps1." -ForegroundColor Gray
        Write-Host "  Contact your system administrator for setup assistance." -ForegroundColor Gray
    }
    $allOk = $false
}

# ── Step 3: Admin SSH key ─────────────────────────────────────────────────────

Write-Host ""
Step "Checking for admin SSH key..."

if ((Test-Path $adminKey) -and -not $Refresh) {
    Ok "Admin SSH key present"
} elseif ($fetchEnabled) {
    Step "Fetching admin SSH key..."
    $content = Get-GistFile "id_ed25519.pub"
    if ($content -and ($content -match "^ssh-")) {
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        [IO.File]::WriteAllText($adminKey, $content.TrimEnd() + "`n", [Text.UTF8Encoding]::new($false))
        Ok "Admin SSH key saved to $adminKey"
    } else {
        Warn "Could not fetch admin SSH key. Contact your system administrator."
        $allOk = $false
    }
} else {
    Warn "Admin SSH key not found at $adminKey"
    if (-not $fetchEnabled) {
        Write-Host "  Contact your system administrator for setup assistance." -ForegroundColor Gray
    }
    $allOk = $false
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
$color = if ($allOk) { "Green" } else { "Yellow" }
Write-Host "================================================" -ForegroundColor $color
if ($allOk) {
    Write-Host "  Ready. Run .\create-image.ps1 to create an SD card image." -ForegroundColor Green
} else {
    Write-Host "  Setup incomplete. See warnings above." -ForegroundColor Yellow
    Write-Host "  You can still run create-image.ps1 and supply keys manually when prompted." -ForegroundColor Gray
}
Write-Host "================================================" -ForegroundColor $color
Write-Host ""
