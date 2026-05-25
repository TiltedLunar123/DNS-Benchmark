<#
.SYNOPSIS
    One-click installer & runner for DNS Benchmark & Optimizer.
    Downloads the latest version, self-elevates to admin, and runs the benchmark.
#>

# ── Self-elevate to Administrator if not already ──────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Requesting Administrator privileges..." -ForegroundColor Yellow

    # Hand the elevated process the exact script we are already running rather
    # than fetching install.ps1 a second time. A second download opens a window
    # where someone on the network path could serve different code to the admin
    # run than the user originally invoked.
    $selfSource = if ($PSCommandPath) {
        [System.IO.File]::ReadAllText($PSCommandPath)
    } else {
        $MyInvocation.MyCommand.Definition
    }

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("dns-benchmark-install-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
    [System.IO.File]::WriteAllText($tempScript, $selfSource, [System.Text.Encoding]::UTF8)

    Start-Process powershell -Verb RunAs -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", $tempScript
    exit
}

# ── Running as Admin from here ────────────────────────────────────────────────
Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "Stop"
$installDir = Join-Path $env:USERPROFILE "DNS-Benchmark"
$scriptPath = Join-Path $installDir "DNS-Benchmark.ps1"
$repoBase = "https://raw.githubusercontent.com/TiltedLunar123/DNS-Benchmark/master"

# SHA-256 over the script content with line endings normalized to LF, so the
# result does not change when git checks the file out as CRLF on Windows.
function Get-NormalizedScriptHash {
    param([Parameter(Mandatory)][string] $Content)
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

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

# Verify the download against the published checksum before running it.
# This catches a corrupted or tampered transfer. It does not defend against a
# full source compromise, since the checksum is fetched from the same repo.
Write-Host "  [*] Verifying integrity..." -ForegroundColor Yellow
try {
    $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $checksumFile = (New-Object System.Net.WebClient).DownloadString("$repoBase/checksums.txt?cb=$cacheBust")
}
catch {
    Write-Host "  [-] Could not download checksums.txt: $_" -ForegroundColor Red
    Write-Host "  [i] Refusing to run unverified code." -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

$expectedHash = $null
foreach ($line in ($checksumFile -split "`n")) {
    if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?DNS-Benchmark\.ps1\s*$') {
        $expectedHash = $Matches[1].ToLowerInvariant()
        break
    }
}

if (-not $expectedHash) {
    Write-Host "  [-] No DNS-Benchmark.ps1 entry found in checksums.txt." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

$actualHash = Get-NormalizedScriptHash -Content $scriptContent
if ($actualHash -ne $expectedHash) {
    Write-Host "  [-] Integrity check FAILED. The download does not match the published hash." -ForegroundColor Red
    Write-Host "      expected: $expectedHash" -ForegroundColor Gray
    Write-Host "      actual:   $actualHash" -ForegroundColor Gray
    Write-Host "  [i] Not running it. Try again, and report this if it keeps happening." -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}
Write-Host "  [+] Integrity verified (sha256: $($actualHash.Substring(0,16))...)" -ForegroundColor Green

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
