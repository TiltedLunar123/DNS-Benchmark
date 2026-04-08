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

# Download latest script
Write-Host "  [*] Downloading latest DNS-Benchmark.ps1..." -ForegroundColor Yellow
try {
    Invoke-WebRequest -Uri "$repoBase/DNS-Benchmark.ps1" -OutFile $scriptPath -UseBasicParsing
    Write-Host "  [+] Downloaded to: $scriptPath" -ForegroundColor Green
}
catch {
    Write-Host "  [-] Download failed: $_" -ForegroundColor Red
    Write-Host "  [i] Check your internet connection and try again." -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

# Verify file was downloaded
if (-not (Test-Path $scriptPath) -or (Get-Item $scriptPath).Length -lt 1000) {
    Write-Host "  [-] Download appears incomplete or corrupt." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

Write-Host "  [+] File verified ($([math]::Round((Get-Item $scriptPath).Length / 1KB, 1)) KB)" -ForegroundColor Green
Write-Host ""
Write-Host "  [*] Launching DNS Benchmark..." -ForegroundColor Yellow
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""

# Run the benchmark by loading script content as a ScriptBlock.
# This bypasses execution policy entirely since no .ps1 file is "executed" —
# we read it as text and invoke the script block in-process.
$scriptContent = Get-Content $scriptPath -Raw
$scriptBlock = [ScriptBlock]::Create($scriptContent)
& $scriptBlock

Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  [i] Script saved to: $scriptPath" -ForegroundColor Gray
Write-Host "  [i] Run again:   powershell -ExecutionPolicy Bypass -File '$scriptPath'" -ForegroundColor Gray
Write-Host "  [i] Restore DNS: powershell -ExecutionPolicy Bypass -File '$scriptPath' -Restore" -ForegroundColor Gray
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""
