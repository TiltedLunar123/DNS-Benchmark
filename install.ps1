<#
.SYNOPSIS
    One-click installer & runner for DNS Benchmark & Optimizer.
    Downloads the latest version, self-elevates to admin, and runs the benchmark.
#>

# ── Self-elevate to Administrator if not already ──────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Requesting Administrator privileges..." -ForegroundColor Yellow

    $scriptUrl = "https://raw.githubusercontent.com/TiltedLunar123/DNS-Benchmark/master/install.ps1"
    $elevatedCmd = "Set-ExecutionPolicy Bypass -Scope Process -Force; irm '$scriptUrl' | iex"

    Start-Process powershell -Verb RunAs -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $elevatedCmd
    exit
}

# ── Running as Admin from here ────────────────────────────────────────────────
Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"
$installDir = Join-Path $env:USERPROFILE "DNS-Benchmark"
$scriptPath = Join-Path $installDir "DNS-Benchmark.ps1"
$repoBase = "https://raw.githubusercontent.com/TiltedLunar123/DNS-Benchmark/master"

Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "    DNS Benchmark - Installer             " -ForegroundColor Cyan
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""

# Create install directory
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Write-Host "  [+] Created: $installDir" -ForegroundColor Green
}

# Download script content as string (avoids file encoding issues with Get-Content)
Write-Host "  [*] Downloading latest DNS-Benchmark.ps1..." -ForegroundColor Yellow
try {
    $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $scriptContent = (New-Object System.Net.WebClient).DownloadString("$repoBase/DNS-Benchmark.ps1?cb=$cacheBust")
    Write-Host "  [+] Downloaded ($([math]::Round($scriptContent.Length / 1KB, 1)) KB)" -ForegroundColor Green
}
catch {
    Write-Host "  [-] Download failed: $_" -ForegroundColor Red
    Write-Host "  [i] Check your internet connection and try again." -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

if (-not $scriptContent -or $scriptContent.Length -lt 500) {
    Write-Host "  [-] Download appears incomplete or corrupt." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

# Save to disk for future manual use
[System.IO.File]::WriteAllText($scriptPath, $scriptContent, [System.Text.Encoding]::UTF8)
Write-Host "  [+] Saved to: $scriptPath" -ForegroundColor Green
Write-Host ""
Write-Host "  [*] Launching DNS Benchmark..." -ForegroundColor Yellow
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""

# Pre-set directory variables so the script can find a valid path for backups/reports.
# When run via ScriptBlock, $PSScriptRoot is empty — this fixes that.
$ScriptDir = $installDir
$PSScriptRoot = $installDir

# Run directly from the in-memory string as a ScriptBlock.
# This bypasses execution policy entirely — no .ps1 file is "loaded".
$scriptBlock = [ScriptBlock]::Create($scriptContent)
& $scriptBlock

Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  [i] Script saved to: $scriptPath" -ForegroundColor Gray
Write-Host "  [i] Run again:   powershell -ExecutionPolicy Bypass -File '$scriptPath'" -ForegroundColor Gray
Write-Host "  [i] Restore DNS: powershell -ExecutionPolicy Bypass -File '$scriptPath' -Restore" -ForegroundColor Gray
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""
