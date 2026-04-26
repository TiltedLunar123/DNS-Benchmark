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
    [ValidateRange(1, 100)]
    [int]$TestCount = 5,
    [switch]$SkipApply,
    [switch]$Restore,
    [switch]$Report
)

# -- Admin check --------------------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [-] This script must be run as Administrator." -ForegroundColor Red
    Write-Host "  [i] Right-click PowerShell > 'Run as Administrator', or use install.ps1" -ForegroundColor Gray
    exit 1
}

# -- Script directory ----------------------------------------------------------
# Order: $PSScriptRoot (set when run as a real .ps1 file), then a caller-supplied
# $ScriptDir (set by install.ps1 before invoking via ScriptBlock), then a default
# user-profile path for ad-hoc `iex` runs where neither is available.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($ScriptDir) { $ScriptDir }
             else { Join-Path $env:USERPROFILE "DNS-Benchmark" }
if (-not (Test-Path $ScriptDir)) { New-Item -ItemType Directory -Path $ScriptDir -Force | Out-Null }

# -- Color helpers --------------------------------------------------------------
function Write-Header  { param($Text) Write-Host ("`n  +{0}+" -f ("-" * 62)) -ForegroundColor Cyan; Write-Host ("  |  $Text{0}|" -f (" " * (59 - $Text.Length))) -ForegroundColor Cyan; Write-Host ("  +{0}+" -f ("-" * 62)) -ForegroundColor Cyan }
function Write-Status  { param($Text) Write-Host "  [*] $Text" -ForegroundColor Yellow }
function Write-Success { param($Text) Write-Host "  [+] $Text" -ForegroundColor Green }
function Write-Err     { param($Text) Write-Host "  [-] $Text" -ForegroundColor Red }
function Write-Info    { param($Text) Write-Host "  [i] $Text" -ForegroundColor Gray }

# -- Testable Functions ---------------------------------------------------------

function Get-ActiveNetworkAdapter {
    <#
    .SYNOPSIS
        Returns the first active, non-virtual, non-Bluetooth network adapter.
    #>
    Get-NetAdapter | Where-Object {
        $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Virtual|Loopback|Bluetooth"
    } | Select-Object -First 1
}

function Get-DnsServerResults {
    <#
    .SYNOPSIS
        Benchmarks a single DNS server across multiple domains and returns statistics.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$DnsServer,
        [Parameter(Mandatory)]
        [string[]]$Domains,
        [Parameter(Mandatory)]
        [int]$QueryCount
    )

    $latencies = @()
    $failures = 0
    $totalQueries = $QueryCount * $Domains.Count

    foreach ($domain in $Domains) {
        for ($i = 0; $i -lt $QueryCount; $i++) {
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                # -QuickTimeout shortens the per-query timeout so a single unresponsive
                # server cannot stall the whole benchmark for minutes (#6).
                $null = Resolve-DnsName -Name $domain -Server $DnsServer.Primary -DnsOnly -Type A -QuickTimeout -ErrorAction Stop
                $sw.Stop()
                $latencies += $sw.Elapsed.TotalMilliseconds
            }
            catch {
                $failures++
            }
        }
    }

    if ($latencies.Count -gt 0) {
        $sorted = $latencies | Sort-Object
        $avgLatency = [math]::Round(($latencies | Measure-Object -Average).Average, 2)
        $minLatency = [math]::Round(($latencies | Measure-Object -Minimum).Minimum, 2)
        $maxLatency = [math]::Round(($latencies | Measure-Object -Maximum).Maximum, 2)
        $mid = [math]::Floor($sorted.Count / 2)
        $medianLatency = if ($sorted.Count % 2 -eq 0) {
            [math]::Round(($sorted[$mid - 1] + $sorted[$mid]) / 2, 2)
        } else {
            [math]::Round($sorted[$mid], 2)
        }
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

    [PSCustomObject]@{
        Name          = $DnsServer.Name
        Primary       = $DnsServer.Primary
        Secondary     = $DnsServer.Secondary
        AvgLatency    = $avgLatency
        MinLatency    = $minLatency
        MaxLatency    = $maxLatency
        MedianLatency = $medianLatency
        Jitter        = $jitter
        Reliability   = $reliability
        SecurityScore = $DnsServer.SecurityScore
        Features      = $DnsServer.Features
        Failures      = $failures
        TotalQueries  = $totalQueries
        CompositeScore = 0
    }
}

function Get-CompositeScore {
    <#
    .SYNOPSIS
        Calculates a weighted composite score for a DNS benchmark result.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Result,
        [Parameter(Mandatory)]
        [double]$MaxLatencyBound,
        [Parameter(Mandatory)]
        [double]$MinLatencyBound,
        [Parameter(Mandatory)]
        [double]$MaxJitterBound
    )

    if ($Result.AvgLatency -ge 9999) { return 0 }

    $latencyRange = $MaxLatencyBound - $MinLatencyBound
    $speedScore = if ($latencyRange -gt 0) {
        [math]::Max(0, [math]::Round((1 - (($Result.AvgLatency - $MinLatencyBound) / $latencyRange)) * 100, 1))
    } else { 100 }

    $consistencyScore = if ($MaxJitterBound -gt 0) {
        [math]::Max(0, [math]::Round((1 - ($Result.Jitter / $MaxJitterBound)) * 100, 1))
    } else { 100 }

    [math]::Round(
        ($speedScore * 0.40) +
        ($Result.Reliability * 0.25) +
        ($Result.SecurityScore * 0.25) +
        ($consistencyScore * 0.10),
        1
    )
}

function Get-LetterGrade {
    <#
    .SYNOPSIS
        Maps a composite score (0-100) to a letter grade.
    #>
    param(
        [Parameter(Mandatory)]
        [double]$Score
    )

    if     ($Score -ge 90) { "A+" }
    elseif ($Score -ge 85) { "A"  }
    elseif ($Score -ge 80) { "A-" }
    elseif ($Score -ge 75) { "B+" }
    elseif ($Score -ge 70) { "B"  }
    elseif ($Score -ge 65) { "B-" }
    elseif ($Score -ge 60) { "C+" }
    elseif ($Score -ge 55) { "C"  }
    elseif ($Score -ge 50) { "C-" }
    elseif ($Score -ge 40) { "D"  }
    else                   { "F"  }
}

function Backup-DnsSettings {
    <#
    .SYNOPSIS
        Saves current DNS settings to a timestamped JSON backup file and prunes
        older backups beyond -MaxBackups so they do not accumulate forever (#7).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BackupDir,
        [Parameter(Mandatory)]
        [string]$AdapterName,
        [Parameter(Mandatory)]
        [int]$InterfaceIndex,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$CurrentDns,
        [ValidateRange(1, 1000)]
        [int]$MaxBackups = 10
    )

    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

    $backupPath = Join-Path $BackupDir "dns-backup_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').json"
    @{
        Adapter      = $AdapterName
        InterfaceIdx = $InterfaceIndex
        PreviousDNS  = $CurrentDns -join ","
        Timestamp    = (Get-Date).ToString("o")
    } | ConvertTo-Json | Out-File -FilePath $backupPath -Encoding UTF8

    $existing = @(Get-ChildItem -Path $BackupDir -Filter "dns-backup_*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($existing.Count -gt $MaxBackups) {
        $existing | Select-Object -Skip $MaxBackups | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $backupPath
}

function Test-StaticDnsConfigured {
    <#
    .SYNOPSIS
        Returns $true when the adapter has a static DNS server list configured,
        $false when the adapter is using DHCP-supplied DNS only.
    .DESCRIPTION
        Win32_NetworkAdapterConfiguration.DNSServerSearchOrder reflects the static
        override list. It is empty/null when the adapter is using DHCP-supplied DNS.
    #>
    param(
        [Parameter(Mandatory)]
        [int]$InterfaceIndex
    )

    try {
        $cfg = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$InterfaceIndex" -ErrorAction Stop
    } catch {
        return $true
    }
    if (-not $cfg) { return $true }
    $static = $cfg.DNSServerSearchOrder
    [bool]($static -and $static.Count -gt 0)
}

function Set-OptimalDns {
    <#
    .SYNOPSIS
        Applies DNS servers to a network adapter and flushes the DNS cache.
    #>
    param(
        [Parameter(Mandatory)]
        [int]$InterfaceIndex,
        [Parameter(Mandatory)]
        [string]$PrimaryDns,
        [Parameter(Mandatory)]
        [string]$SecondaryDns
    )

    try {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses @($PrimaryDns, $SecondaryDns) -ErrorAction Stop
    } catch {
        return $false
    }
    $null = Clear-DnsClientCache 2>$null

    try {
        $newDns = (Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
    } catch {
        return $false
    }
    if (-not $newDns -or $newDns.Count -eq 0) { return $false }
    ($newDns[0] -eq $PrimaryDns) -and ($newDns.Count -ge 2 -and $newDns[1] -eq $SecondaryDns)
}

# -- Banner ---------------------------------------------------------------------
Write-Host ""
Write-Host "   ____  _   _ ____  " -ForegroundColor Cyan
Write-Host "  |  _ \| \ | / ___| " -ForegroundColor Cyan
Write-Host "  | | | |  \| \___ \ " -ForegroundColor Cyan
Write-Host "  | |_| | |\  |___) |" -ForegroundColor DarkCyan
Write-Host "  |____/|_| \_|____/ " -ForegroundColor DarkCyan
Write-Host "  Benchmark and Optimizer" -ForegroundColor White
Write-Host ""

# -- DNS Server Database --------------------------------------------------------
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

# -- Restore mode ---------------------------------------------------------------
if ($Restore) {
    Write-Header "Restoring DNS to Automatic (DHCP)"

    $adapter = Get-ActiveNetworkAdapter
    if (-not $adapter) {
        Write-Err "No active network adapter found."
        exit 1
    }

    Write-Status "Adapter: $($adapter.Name)"

    if (-not (Test-StaticDnsConfigured -InterfaceIndex $adapter.InterfaceIndex)) {
        Write-Info "'$($adapter.Name)' is already using DHCP-supplied DNS. Nothing to restore."
        exit 0
    }

    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses
    Write-Success "DNS restored to automatic (DHCP) on '$($adapter.Name)'"
    Write-Info "You may need to run: ipconfig /flushdns"
    exit 0
}

# -- Detect active adapter -----------------------------------------------------
Write-Header "System Detection"

$adapter = Get-ActiveNetworkAdapter
if (-not $adapter) {
    Write-Err "No active network adapter found. Are you connected to a network?"
    exit 1
}

$currentDns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses
Write-Success "Active adapter: $($adapter.Name) ($($adapter.InterfaceDescription))"
Write-Info    "Current DNS:    $($currentDns -join ', ')"
Write-Info    "Link speed:     $($adapter.LinkSpeed)"

# -- Benchmark ------------------------------------------------------------------
Write-Header "Benchmarking $($DnsServers.Count) DNS Servers"
Write-Info "Testing $TestCount queries x $($TestDomains.Count) domains per server..."
Write-Host ""

$results = @()
$serverIndex = 0
$maxNameLen = ($DnsServers | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
$progressWidth = 32 + $maxNameLen

foreach ($dns in $DnsServers) {
    $serverIndex++
    $pct = [math]::Floor(($serverIndex / $DnsServers.Count) * 100)
    $bar = "#" * [math]::Floor($pct / 5) + "-" * (20 - [math]::Floor($pct / 5))
    $line = "  [$bar] $pct% - Testing $($dns.Name)..."
    Write-Host "`r$($line.PadRight($progressWidth))" -NoNewline -ForegroundColor White

    $results += Get-DnsServerResults -DnsServer $dns -Domains $TestDomains -QueryCount $TestCount
}

$doneLine = "  [####################] 100% - Done!"
Write-Host "`r$($doneLine.PadRight($progressWidth))" -ForegroundColor Green
Write-Host ""

# -- Composite Scoring ----------------------------------------------------------
# Weights: Speed 40%, Reliability 25%, Security 25%, Consistency 10%
Write-Header "Calculating Composite Scores"

$maxLatencyBound = ($results | Where-Object { $_.AvgLatency -lt 9999 } | Measure-Object -Property AvgLatency -Maximum).Maximum
$minLatencyBound = ($results | Where-Object { $_.AvgLatency -lt 9999 } | Measure-Object -Property AvgLatency -Minimum).Minimum
$maxJitterBound  = ($results | Where-Object { $_.Jitter -lt 9999 } | Measure-Object -Property Jitter -Maximum).Maximum

foreach ($r in $results) {
    $r.CompositeScore = Get-CompositeScore -Result $r -MaxLatencyBound $maxLatencyBound -MinLatencyBound $minLatencyBound -MaxJitterBound $maxJitterBound
}

# Sort by composite score descending
$results = $results | Sort-Object -Property CompositeScore -Descending

# -- Results Table --------------------------------------------------------------
Write-Header "Results (Ranked by Composite Score)"
Write-Host ""
Write-Host ("  {0,-28} {1,10} {2,10} {3,10} {4,10} {5,12} {6,8} {7,8}" -f "DNS Server", "Avg (ms)", "Med (ms)", "Jitter", "Rely %", "Security", "Score", "Grade") -ForegroundColor White
Write-Host ("  " + "-" * 106) -ForegroundColor DarkGray

$rank = 0
foreach ($r in $results) {
    $rank++
    $color = if     ($r.CompositeScore -ge 80) { "Green" }
             elseif ($r.CompositeScore -ge 60) { "Yellow" }
             elseif ($r.CompositeScore -ge 40) { "DarkYellow" }
             else                               { "Red" }
    $grade = Get-LetterGrade -Score $r.CompositeScore

    $prefix = if ($rank -le 3) { "*" } else { " " }
    $line = "  $prefix {0,-27} {1,10} {2,10} {3,10} {4,9}% {5,11} {6,8} {7,6}" -f $r.Name, $r.AvgLatency, $r.MedianLatency, $r.Jitter, $r.Reliability, "$($r.SecurityScore)/100", $r.CompositeScore, $grade
    Write-Host $line -ForegroundColor $color
}

# -- Winner Details -------------------------------------------------------------
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

# -- Export Report --------------------------------------------------------------
if ($Report) {
    $reportPath = Join-Path $ScriptDir "DNS-Benchmark-Report_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').csv"
    $rank = 0
    $results | ForEach-Object {
        $rank++
        $_ | Add-Member -NotePropertyName "Rank" -NotePropertyValue $rank -Force
        $_ | Add-Member -NotePropertyName "Grade" -NotePropertyValue (Get-LetterGrade -Score $_.CompositeScore) -Force
        $_
    } | Select-Object Rank, Name, Primary, Secondary, AvgLatency, MedianLatency, MinLatency, MaxLatency, Jitter, Reliability, SecurityScore, CompositeScore, Grade, Features |
        Export-Csv -Path $reportPath -NoTypeInformation
    Write-Host ""
    Write-Success "Report saved to: $reportPath"
}

# -- Apply DNS ------------------------------------------------------------------
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
            $backupPath = Backup-DnsSettings -BackupDir $ScriptDir -AdapterName $adapter.Name -InterfaceIndex $adapter.InterfaceIndex -CurrentDns $currentDns
            Write-Info "Backup saved: $backupPath"

            $applied = Set-OptimalDns -InterfaceIndex $adapter.InterfaceIndex -PrimaryDns $winner.Primary -SecondaryDns $winner.Secondary

            if ($applied) {
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
