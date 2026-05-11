<#
.SYNOPSIS
    Checks and installs prerequisites for provision-image.ps1.

.DESCRIPTION
    Verifies that Raspberry Pi Imager is installed (required for full mode).
    Installs it via winget if not found and winget is available. Also checks
    for the fleet deploy key and admin SSH public key.

.EXAMPLE
    .\setup.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Inventory Pi - Setup Check" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

$allOk = $true

# ── Raspberry Pi Imager ────────────────────────────────────────────────────────

Step "Checking for Raspberry Pi Imager..."

$imager = Find-RpiImager
if ($imager) {
    Ok "Raspberry Pi Imager found: $imager"
} else {
    Warn "Raspberry Pi Imager not found."

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $answer = Read-Host "  Install via winget? [y/N]"
        if ($answer -match "^[Yy]$") {
            Step "Installing via winget..."
            try {
                winget install --id RaspberryPiFoundation.RaspberryPiImager `
                    --silent --accept-package-agreements --accept-source-agreements
                $imager = Find-RpiImager
                if ($imager) {
                    Ok "Raspberry Pi Imager installed: $imager"
                } else {
                    Warn "winget finished but imager not found at expected path."
                    Warn "You may need to restart your terminal or log out and back in."
                    $allOk = $false
                }
            } catch {
                Warn "winget install failed: $($_.Exception.Message)"
                Write-Host "  Install manually from: https://www.raspberrypi.com/software/" -ForegroundColor Gray
                $allOk = $false
            }
        } else {
            Write-Host "  Install manually from: https://www.raspberrypi.com/software/" -ForegroundColor Gray
            $allOk = $false
        }
    } else {
        Write-Host "  winget not available." -ForegroundColor Gray
        Write-Host "  Install manually from: https://www.raspberrypi.com/software/" -ForegroundColor Gray
        $allOk = $false
    }
}

# ── Deploy key ────────────────────────────────────────────────────────────────

Write-Host ""
Step "Checking for fleet deploy key..."

$deployKeyPath = "$env:USERPROFILE\.ssh\inventory_deploy"
if (Test-Path $deployKeyPath) {
    $header = Get-Content $deployKeyPath -TotalCount 1 -ErrorAction SilentlyContinue
    if ($header -match "BEGIN.*KEY") {
        Ok "Deploy key found: $deployKeyPath"
    } else {
        Warn "File found but does not look like an SSH private key: $deployKeyPath"
        $allOk = $false
    }
} else {
    Warn "Deploy key not found at $deployKeyPath"
    Write-Host "  Place the fleet deploy private key at $deployKeyPath" -ForegroundColor Gray
    Write-Host "  or pass -DeployKeyPath when running provision-image.ps1" -ForegroundColor Gray
    $allOk = $false
}

# ── Admin SSH public key ───────────────────────────────────────────────────────

Write-Host ""
Step "Checking for admin SSH public key (optional)..."

$adminKeyPath = "$env:USERPROFILE\.ssh\id_ed25519.pub"
if (Test-Path $adminKeyPath) {
    $content = Get-Content $adminKeyPath -Raw -ErrorAction SilentlyContinue
    if ($content -match "^ssh-") {
        Ok "Admin SSH public key found: $adminKeyPath"
    } else {
        Warn "File found but does not look like an SSH public key: $adminKeyPath"
    }
} else {
    Warn "Admin SSH public key not found at $adminKeyPath (optional)"
    Write-Host "  Pass -AdminSshKeyPath to provision-image.ps1 to use a different key," -ForegroundColor Gray
    Write-Host "  or pass -AdminSshKeyPath '' to skip passwordless SSH setup." -ForegroundColor Gray
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
$color = if ($allOk) { "Green" } else { "Yellow" }
Write-Host "================================================" -ForegroundColor $color
if ($allOk) {
    Write-Host "  Ready. Run .\provision-image.ps1 to prepare an SD card." -ForegroundColor Green
} else {
    Write-Host "  Some prerequisites are missing. See warnings above." -ForegroundColor Yellow
    Write-Host "  provision-image.ps1 will prompt for anything not found automatically." -ForegroundColor Gray
}
Write-Host "================================================" -ForegroundColor $color
Write-Host ""
