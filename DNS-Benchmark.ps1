<#
.SYNOPSIS
    DNS Benchmark & Optimizer - Tests, scores, and applies the fastest and most secure DNS for your system.

.DESCRIPTION
    Benchmarks popular DNS resolvers for latency, reliability, and security features,
    then intelligently selects and applies the best one to your active network adapter.

.PARAMETER TestCount
    Number of queries per DNS server per domain. Default: 5

.PARAMETER SkipApply
    Run benchmark only without applying changes.

.PARAMETER Restore
    Restore DNS to automatic (DHCP) settings.

.PARAMETER Report
    Export results to a CSV file.

.EXAMPLE
    .\DNS-Benchmark.ps1
    .\DNS-Benchmark.ps1 -TestCount 10 -Report
    .\DNS-Benchmark.ps1 -SkipApply
    .\DNS-Benchmark.ps1 -Restore
#>

[CmdletBinding()]
param(
    [int]$TestCount = 5,
    [switch]$SkipApply,
    [switch]$Restore,
    [switch]$Report
)

# ── Admin check ────────────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [-] This script must be run as Administrator." -ForegroundColor Red
    Write-Host "  [i] Right-click PowerShell > 'Run as Administrator', or use install.ps1" -ForegroundColor Gray
    exit 1
}

# ── Color helpers ──────────────────────────────────────────────────────────────
function Write-Header  { param($Text) Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan; Write-Host "║  $Text" -ForegroundColor Cyan -NoNewline; Write-Host (" " * (61 - $Text.Length)) -NoNewline; Write-Host "║" -ForegroundColor Cyan; Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan }
function Write-Status  { param($Text) Write-Host "  [*] $Text" -ForegroundColor Yellow }
function Write-Success { param($Text) Write-Host "  [+] $Text" -ForegroundColor Green }
function Write-Err     { param($Text) Write-Host "  [-] $Text" -ForegroundColor Red }
function Write-Info    { param($Text) Write-Host "  [i] $Text" -ForegroundColor Gray }

# ── Banner ─────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  ██████╗ ███╗   ██╗███████╗" -ForegroundColor Cyan
Write-Host "  ██╔══██╗████╗  ██║██╔════╝" -ForegroundColor Cyan
Write-Host "  ██║  ██║██╔██╗ ██║███████╗" -ForegroundColor Cyan
Write-Host "  ██║  ██║██║╚██╗██║╚════██║" -ForegroundColor DarkCyan
Write-Host "  ██████╔╝██║ ╚████║███████║" -ForegroundColor DarkCyan
Write-Host "  ╚═════╝ ╚═╝  ╚═══╝╚══════╝" -ForegroundColor DarkCyan
Write-Host "  Benchmark & Optimizer       " -ForegroundColor White
Write-Host ""

# ── DNS Server Database ────────────────────────────────────────────────────────
# Each entry: Name, Primary IPv4, Secondary IPv4, Security Score (0-100)
# Security scoring based on: DNSSEC validation, no-logging policy, malware blocking,
# DNS-over-HTTPS support, DNS-over-TLS support, open-source/audited
$DnsServers = @(
    @{ Name = "Cloudflare";              Primary = "1.1.1.1";       Secondary = "1.0.0.1";       SecurityScore = 92;  Features = "DNSSEC, DoH, DoT, no-log policy, audited privacy" }
    @{ Name = "Cloudflare (Malware)";    Primary = "1.1.1.2";       Secondary = "1.0.0.2";       SecurityScore = 95;  Features = "DNSSEC, DoH, DoT, malware blocking, no-log" }
    @{ Name = "Cloudflare (Family)";     Primary = "1.1.1.3";       Secondary = "1.0.0.3";       SecurityScore = 95;  Features = "DNSSEC, DoH, DoT, malware + adult blocking" }
    @{ Name = "Google";                  Primary = "8.8.8.8";       Secondary = "8.8.4.4";       SecurityScore = 78;  Features = "DNSSEC, DoH, DoT, logs anonymized after 48h" }
    @{ Name = "Quad9";                   Primary = "9.9.9.9";       Secondary = "149.112.112.112"; SecurityScore = 96; Features = "DNSSEC, DoH, DoT, threat blocking, non-profit, no-log" }
    @{ Name = "Quad9 (Unfiltered)";      Primary = "9.9.9.10";      Secondary = "149.112.112.10"; SecurityScore = 88;  Features = "DNSSEC, DoH, DoT, no filtering, no-log" }
    @{ Name = "OpenDNS";                 Primary = "208.67.222.222"; Secondary = "208.67.220.220"; SecurityScore = 80;  Features = "DNSSEC, DoH, phishing protection, Cisco-owned" }
    @{ Name = "OpenDNS (FamilyShield)";  Primary = "208.67.222.123"; Secondary = "208.67.220.123"; SecurityScore = 82; Features = "DNSSEC, DoH, family filter, phishing protection" }
    @{ Name = "AdGuard";                 Primary = "94.140.14.14";  Secondary = "94.140.15.15";  SecurityScore = 90;  Features = "DNSSEC, DoH, DoT, ad/tracker/malware blocking" }
    @{ Name = "AdGuard (Family)";        Primary = "94.140.14.15";  Secondary = "94.140.15.16";  SecurityScore = 91;  Features = "DNSSEC, DoH, DoT, family filter + ad blocking" }
    @{ Name = "Comodo Secure";           Primary = "8.26.56.26";    Secondary = "8.20.247.20";   SecurityScore = 72;  Features = "Malware blocking, phishing protection" }
    @{ Name = "CleanBrowsing (Security)";Primary = "185.228.168.9"; Secondary = "185.228.169.9"; SecurityScore = 88;  Features = "DNSSEC, DoH, DoT, malware/phishing blocking" }
    @{ Name = "CleanBrowsing (Family)";  Primary = "185.228.168.168"; Secondary = "185.228.169.168"; SecurityScore = 89; Features = "DNSSEC, DoH, DoT, family + security filter" }
    @{ Name = "Mullvad";                 Primary = "194.242.2.2";   Secondary = "194.242.2.3";   SecurityScore = 94;  Features = "DNSSEC, DoH, DoT, no-log, privacy-focused VPN company" }
    @{ Name = "Control D";              Primary = "76.76.2.0";     Secondary = "76.76.10.0";    SecurityScore = 86;  Features = "DNSSEC, DoH, DoT, customizable filtering" }
    @{ Name = "Neustar UltraDNS";       Primary = "64.6.64.6";     Secondary = "64.6.65.6";     SecurityScore = 70;  Features = "DNSSEC, enterprise-grade reliability" }
    @{ Name = "Level3 / CenturyLink";   Primary = "4.2.2.1";       Secondary = "4.2.2.2";       SecurityScore = 55;  Features = "Basic DNS, no encryption, no filtering" }
)

# Domains to test resolution against (mix of popular + less-cached)
$TestDomains = @(
    "google.com",
    "github.com",
    "amazon.com",
    "cloudflare.com",
    "wikipedia.org",
    "microsoft.com",
    "stackoverflow.com",
    "nytimes.com",
    "bbc.co.uk",
    "reddit.com"
)

# ── Restore mode ───────────────────────────────────────────────────────────────
if ($Restore) {
    Write-Header "Restoring DNS to Automatic (DHCP)"

    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Virtual|Loopback|Bluetooth" } | Select-Object -First 1
    if (-not $adapter) {
        Write-Err "No active network adapter found."
        exit 1
    }

    Write-Status "Adapter: $($adapter.Name)"
    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses
    Write-Success "DNS restored to automatic (DHCP) on '$($adapter.Name)'"
    Write-Info "You may need to run: ipconfig /flushdns"
    exit 0
}

# ── Detect active adapter ─────────────────────────────────────────────────────
Write-Header "System Detection"

$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Virtual|Loopback|Bluetooth" } | Select-Object -First 1
if (-not $adapter) {
    Write-Err "No active network adapter found. Are you connected to a network?"
    exit 1
}

$currentDns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses
Write-Success "Active adapter: $($adapter.Name) ($($adapter.InterfaceDescription))"
Write-Info    "Current DNS:    $($currentDns -join ', ')"
Write-Info    "Link speed:     $($adapter.LinkSpeed)"

# ── Benchmark ──────────────────────────────────────────────────────────────────
Write-Header "Benchmarking $($DnsServers.Count) DNS Servers"
Write-Info "Testing $TestCount queries x $($TestDomains.Count) domains per server..."
Write-Host ""

$results = @()
$serverIndex = 0

foreach ($dns in $DnsServers) {
    $serverIndex++
    $pct = [math]::Floor(($serverIndex / $DnsServers.Count) * 100)
    $bar = "█" * [math]::Floor($pct / 5) + "░" * (20 - [math]::Floor($pct / 5))
    Write-Host "`r  [$bar] $pct% - Testing $($dns.Name)...                    " -NoNewline -ForegroundColor White

    $latencies = @()
    $failures = 0
    $totalQueries = $TestCount * $TestDomains.Count

    foreach ($domain in $TestDomains) {
        for ($i = 0; $i -lt $TestCount; $i++) {
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $null = Resolve-DnsName -Name $domain -Server $dns.Primary -DnsOnly -Type A -ErrorAction Stop
                $sw.Stop()
                $latencies += $sw.Elapsed.TotalMilliseconds
            }
            catch {
                $failures++
            }
        }
    }

    # Calculate stats
    if ($latencies.Count -gt 0) {
        $sorted = $latencies | Sort-Object
        $avgLatency = [math]::Round(($latencies | Measure-Object -Average).Average, 2)
        $minLatency = [math]::Round(($latencies | Measure-Object -Minimum).Minimum, 2)
        $maxLatency = [math]::Round(($latencies | Measure-Object -Maximum).Maximum, 2)
        # Median
        $mid = [math]::Floor($sorted.Count / 2)
        $medianLatency = if ($sorted.Count % 2 -eq 0) {
            [math]::Round(($sorted[$mid - 1] + $sorted[$mid]) / 2, 2)
        } else {
            [math]::Round($sorted[$mid], 2)
        }
        # Jitter (standard deviation)
        $mean = ($latencies | Measure-Object -Average).Average
        $variance = ($latencies | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
        $jitter = [math]::Round([math]::Sqrt($variance), 2)
        $reliability = [math]::Round((($totalQueries - $failures) / $totalQueries) * 100, 1)
    }
    else {
        $avgLatency = 9999
        $minLatency = 9999
        $maxLatency = 9999
        $medianLatency = 9999
        $jitter = 9999
        $reliability = 0
    }

    $results += [PSCustomObject]@{
        Name          = $dns.Name
        Primary       = $dns.Primary
        Secondary     = $dns.Secondary
        AvgLatency    = $avgLatency
        MinLatency    = $minLatency
        MaxLatency    = $maxLatency
        MedianLatency = $medianLatency
        Jitter        = $jitter
        Reliability   = $reliability
        SecurityScore = $dns.SecurityScore
        Features      = $dns.Features
        Failures      = $failures
        TotalQueries  = $totalQueries
        CompositeScore = 0  # calculated next
    }
}

Write-Host "`r  [████████████████████] 100% - Done!                              " -ForegroundColor Green
Write-Host ""

# ── Composite Scoring ──────────────────────────────────────────────────────────
# Weights: Speed 40%, Reliability 25%, Security 25%, Consistency 10%
Write-Header "Calculating Composite Scores"

$maxLatency = ($results | Where-Object { $_.AvgLatency -lt 9999 } | Measure-Object -Property AvgLatency -Maximum).Maximum
$minLatencyVal = ($results | Where-Object { $_.AvgLatency -lt 9999 } | Measure-Object -Property AvgLatency -Minimum).Minimum
$maxJitter = ($results | Where-Object { $_.Jitter -lt 9999 } | Measure-Object -Property Jitter -Maximum).Maximum

foreach ($r in $results) {
    if ($r.AvgLatency -ge 9999) {
        $r.CompositeScore = 0
        continue
    }

    # Normalize speed: lower latency = higher score (0-100)
    $latencyRange = $maxLatency - $minLatencyVal
    $speedScore = if ($latencyRange -gt 0) {
        [math]::Round((1 - (($r.AvgLatency - $minLatencyVal) / $latencyRange)) * 100, 1)
    } else { 100 }

    # Normalize consistency: lower jitter = higher score (0-100)
    $consistencyScore = if ($maxJitter -gt 0) {
        [math]::Round((1 - ($r.Jitter / $maxJitter)) * 100, 1)
    } else { 100 }

    # Composite: Speed 40% + Reliability 25% + Security 25% + Consistency 10%
    $r.CompositeScore = [math]::Round(
        ($speedScore * 0.40) +
        ($r.Reliability * 0.25) +
        ($r.SecurityScore * 0.25) +
        ($consistencyScore * 0.10),
        1
    )
}

# Sort by composite score descending
$results = $results | Sort-Object -Property CompositeScore -Descending

# ── Results Table ──────────────────────────────────────────────────────────────
Write-Header "Results (Ranked by Composite Score)"
Write-Host ""
Write-Host ("  {0,-28} {1,10} {2,10} {3,10} {4,10} {5,12} {6,8} {7,8}" -f "DNS Server", "Avg (ms)", "Med (ms)", "Jitter", "Rely %", "Security", "Score", "Grade") -ForegroundColor White
Write-Host ("  " + "-" * 106) -ForegroundColor DarkGray

$rank = 0
foreach ($r in $results) {
    $rank++
    # Color coding
    $color = switch {
        ($r.CompositeScore -ge 80) { "Green" }
        ($r.CompositeScore -ge 60) { "Yellow" }
        ($r.CompositeScore -ge 40) { "DarkYellow" }
        default                     { "Red" }
    }
    # Letter grade
    $grade = switch {
        ($r.CompositeScore -ge 90) { "A+" }
        ($r.CompositeScore -ge 85) { "A"  }
        ($r.CompositeScore -ge 80) { "A-" }
        ($r.CompositeScore -ge 75) { "B+" }
        ($r.CompositeScore -ge 70) { "B"  }
        ($r.CompositeScore -ge 65) { "B-" }
        ($r.CompositeScore -ge 60) { "C+" }
        ($r.CompositeScore -ge 55) { "C"  }
        ($r.CompositeScore -ge 50) { "C-" }
        ($r.CompositeScore -ge 40) { "D"  }
        default                     { "F"  }
    }

    $prefix = if ($rank -le 3) { "★" } else { " " }
    Write-Host ("  $prefix {0,-27} {1,10} {2,10} {3,10} {4,9}% {5,11} {6,8} {7,6}" -f `
        $r.Name, $r.AvgLatency, $r.MedianLatency, $r.Jitter, $r.Reliability, "$($r.SecurityScore)/100", $r.CompositeScore, $grade) -ForegroundColor $color
}

# ── Winner Details ─────────────────────────────────────────────────────────────
$winner = $results[0]

Write-Host ""
Write-Header "Recommended: $($winner.Name)"
Write-Host ""
Write-Success "Primary DNS:      $($winner.Primary)"
Write-Success "Secondary DNS:    $($winner.Secondary)"
Write-Info    "Average latency:  $($winner.AvgLatency) ms"
Write-Info    "Median latency:   $($winner.MedianLatency) ms"
Write-Info    "Jitter:           $($winner.Jitter) ms"
Write-Info    "Reliability:      $($winner.Reliability)%"
Write-Info    "Security score:   $($winner.SecurityScore)/100"
Write-Info    "Composite score:  $($winner.CompositeScore)/100"
Write-Info    "Features:         $($winner.Features)"

# ── Export Report ──────────────────────────────────────────────────────────────
if ($Report) {
    $reportPath = Join-Path $PSScriptRoot "DNS-Benchmark-Report_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').csv"
    $results | Select-Object Name, Primary, Secondary, AvgLatency, MedianLatency, MinLatency, MaxLatency, Jitter, Reliability, SecurityScore, CompositeScore, Features |
        Export-Csv -Path $reportPath -NoTypeInformation
    Write-Host ""
    Write-Success "Report saved to: $reportPath"
}

# ── Apply DNS ──────────────────────────────────────────────────────────────────
if (-not $SkipApply) {
    Write-Host ""
    Write-Header "Apply DNS Settings"

    # Check if already using the winner
    if ($currentDns -and $currentDns[0] -eq $winner.Primary) {
        Write-Success "You're already using the best DNS ($($winner.Name)). No changes needed!"
        exit 0
    }

    Write-Status "This will change DNS on '$($adapter.Name)' to:"
    Write-Host "         Primary:   $($winner.Primary)" -ForegroundColor White
    Write-Host "         Secondary: $($winner.Secondary)" -ForegroundColor White
    Write-Host ""

    $confirm = Read-Host "  Apply these settings? (Y/n)"
    if ($confirm -match "^[Yy]?$") {
        try {
            # Backup current settings
            $backupPath = Join-Path $PSScriptRoot "dns-backup_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').txt"
            @{
                Adapter      = $adapter.Name
                InterfaceIdx = $adapter.InterfaceIndex
                PreviousDNS  = $currentDns -join ","
                Timestamp    = (Get-Date).ToString("o")
            } | ConvertTo-Json | Out-File -FilePath $backupPath -Encoding UTF8

            Write-Info "Backup saved: $backupPath"

            # Apply new DNS
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses @($winner.Primary, $winner.Secondary)

            # Flush DNS cache
            $null = Clear-DnsClientCache 2>$null

            # Verify
            $newDns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses
            if ($newDns[0] -eq $winner.Primary) {
                Write-Host ""
                Write-Success "DNS changed to $($winner.Name) ($($winner.Primary), $($winner.Secondary))"
                Write-Success "DNS cache flushed"
                Write-Info    "Previous DNS backed up to: $backupPath"
                Write-Info    "To restore: .\DNS-Benchmark.ps1 -Restore"
            }
            else {
                Write-Err "Verification failed. DNS may not have been applied correctly."
                Write-Info "Try running this script as Administrator."
            }
        }
        catch {
            Write-Err "Failed to apply DNS: $_"
            Write-Info "Make sure you're running as Administrator."
        }
    }
    else {
        Write-Info "No changes made."
    }
}
else {
    Write-Host ""
    Write-Info "Benchmark only mode. No DNS changes applied."
    Write-Info "Run without -SkipApply to apply the recommended DNS."
}

Write-Host ""
