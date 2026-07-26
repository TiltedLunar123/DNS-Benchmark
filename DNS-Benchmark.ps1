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
    Put back the DNS this tool replaced, reading the newest backup written for
    the adapter. When that backup shows the adapter was on DHCP, or there is no
    backup to read, it resets to automatic (DHCP) as before.

.PARAMETER ResetDhcp
    Used with -Restore. Skip the backup and reset the adapter to automatic
    (DHCP) no matter what was there before.

.PARAMETER Report
    Export results to a CSV file.

.PARAMETER IncludeIPv6
    Also apply the winning resolver's IPv6 DNS addresses alongside IPv4, when the
    adapter has IPv6 bound and the resolver publishes IPv6. Off by default so an
    IPv6 config is never changed unless asked for. Without it, a dual-stack box
    can still resolve over whatever IPv6 DNS the router handed out.

.PARAMETER Parallel
    Benchmark the resolvers concurrently instead of one at a time. Needs
    PowerShell 7+ (ForEach-Object -Parallel); on Windows PowerShell 5.1 it falls
    back to a sequential run. Finishes much faster, at the cost of a little
    latency precision since the servers now share the link while being measured.
    Off by default.

.PARAMETER ThrottleLimit
    How many resolvers to benchmark at once when -Parallel is set. Default: 8.

.EXAMPLE
    .\DNS-Benchmark.ps1
    .\DNS-Benchmark.ps1 -TestCount 10 -Report
    .\DNS-Benchmark.ps1 -SkipApply
    .\DNS-Benchmark.ps1 -IncludeIPv6
    .\DNS-Benchmark.ps1 -Parallel
    .\DNS-Benchmark.ps1 -Parallel -ThrottleLimit 16 -SkipApply
    .\DNS-Benchmark.ps1 -Restore
    .\DNS-Benchmark.ps1 -Restore -ResetDhcp
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$TestCount = 5,
    [switch]$SkipApply,
    [switch]$Restore,
    [switch]$ResetDhcp,
    [switch]$Report,
    [switch]$IncludeIPv6,
    [switch]$Parallel,
    [ValidateRange(1, 64)]
    [int]$ThrottleLimit = 8
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

function Select-PreferredAdapter {
    <#
    .SYNOPSIS
        Picks the best candidate out of a set of adapters and a default-route
        table. Pure, so the choice can be tested without a network.
    .DESCRIPTION
        Filtering to Up and non-virtual then taking the first result leaves the
        answer up to whatever order Get-NetAdapter happened to return, and that
        order is not documented anywhere. On a laptop with Ethernet and Wi-Fi
        both up it is a coin flip, and benchmarking one NIC then writing DNS to
        the other is a silent no-op from the user's side.

        The adapter carrying the default route is the one traffic actually
        leaves by, so that wins, cheapest total metric first. Ties go to the
        earlier adapter, and anything unresolvable falls back to the old
        first-match behaviour rather than failing.
    .PARAMETER DefaultRoutes
        Rows from Get-NetRoute for 0.0.0.0/0. Only InterfaceIndex, RouteMetric
        and InterfaceMetric are read.
    #>
    param(
        [AllowEmptyCollection()]
        [array]$Adapters = @(),
        [AllowEmptyCollection()]
        [array]$DefaultRoutes = @()
    )

    $candidates = @($Adapters | Where-Object {
        $_ -and $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Virtual|Loopback|Bluetooth"
    })

    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    # Cheapest default route per interface index.
    $metrics = @{}
    foreach ($route in @($DefaultRoutes)) {
        if (-not $route) { continue }
        $idx = $route.InterfaceIndex
        if ($null -eq $idx) { continue }
        $cost = [int]$route.RouteMetric + [int]$route.InterfaceMetric
        if (-not $metrics.ContainsKey($idx) -or $cost -lt $metrics[$idx]) { $metrics[$idx] = $cost }
    }

    $best = $null
    $bestCost = [int]::MaxValue
    foreach ($candidate in $candidates) {
        $idx = $candidate.InterfaceIndex
        if ($null -eq $idx -or -not $metrics.ContainsKey($idx)) { continue }
        # Strictly less than, so an earlier adapter keeps a tie.
        if ($metrics[$idx] -lt $bestCost) {
            $bestCost = $metrics[$idx]
            $best = $candidate
        }
    }

    if ($best) { return $best }
    $candidates[0]
}

function Get-ActiveNetworkAdapter {
    <#
    .SYNOPSIS
        Returns the active, non-virtual, non-Bluetooth adapter that carries the
        default route, falling back to the first match when no route is readable.
    #>
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)

    $routes = @()
    try {
        $routes = @(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop)
    }
    catch {
        # No route table to read, so fall back to the first usable adapter.
        Write-Verbose "Could not read the default route table: $_"
    }

    Select-PreferredAdapter -Adapters $adapters -DefaultRoutes $routes
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
        [AllowEmptyCollection()]
        [string[]]$CurrentDnsV6 = @(),
        [ValidateRange(1, 1000)]
        [int]$MaxBackups = 10
    )

    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

    $backupPath = Join-Path $BackupDir "dns-backup_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').json"
    @{
        Adapter       = $AdapterName
        InterfaceIdx  = $InterfaceIndex
        PreviousDNS   = $CurrentDns -join ","
        PreviousDNSv6 = $CurrentDnsV6 -join ","
        Timestamp     = (Get-Date).ToString("o")
    } | ConvertTo-Json | Out-File -FilePath $backupPath -Encoding UTF8

    $existing = @(Get-ChildItem -Path $BackupDir -Filter "dns-backup_*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($existing.Count -gt $MaxBackups) {
        $existing | Select-Object -Skip $MaxBackups | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $backupPath
}

function Get-LatestDnsBackup {
    <#
    .SYNOPSIS
        Returns the newest backup recorded for an adapter, or $null when there
        is nothing usable on disk.
    .DESCRIPTION
        Backup-DnsSettings has been writing dns-backup_*.json since the first
        release and nothing ever read one back, so -Restore could only ever drop
        the machine to DHCP. This is the read side. Files are walked newest
        first, and anything truncated, malformed, or belonging to a different
        adapter is skipped rather than thrown, because a bad file in the
        directory should not cost the user their restore.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BackupDir,
        [Parameter(Mandatory)]
        [string]$AdapterName
    )

    if (-not (Test-Path $BackupDir)) { return $null }

    $files = @(Get-ChildItem -Path $BackupDir -Filter "dns-backup_*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)

    foreach ($file in $files) {
        try {
            $data = Get-Content -Path $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Verbose "Skipping unreadable backup $($file.Name): $_"
            continue
        }

        if (-not $data -or $data.Adapter -ne $AdapterName) { continue }

        $v4 = @(("$($data.PreviousDNS)" -split ",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $v6 = @(("$($data.PreviousDNSv6)" -split ",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        return [PSCustomObject]@{
            Path          = $file.FullName
            Adapter       = $data.Adapter
            InterfaceIdx  = $data.InterfaceIdx
            PreviousDNS   = $v4
            PreviousDNSv6 = $v6
            Timestamp     = $data.Timestamp
        }
    }

    $null
}

function Get-DnsRestorePlan {
    <#
    .SYNOPSIS
        Decides what -Restore should actually do, given the newest backup.
    .DESCRIPTION
        Resetting to DHCP is only right for people who were on DHCP when they
        ran the benchmark. Someone pointed at a Pi-hole, a work resolver, or a
        filtered public resolver had that written to the backup file and then
        silently lost it, because the reset was unconditional. This maps a
        backup onto one of two outcomes and hands back a sentence explaining the
        choice, so the script can say why it did what it did.

        A static restore always resets the adapter before writing the recorded
        servers. Set-DnsClientServerAddress takes no address family of its own,
        it infers one per address, so without the reset an IPv6 pair applied by
        an earlier -IncludeIPv6 run would survive a restore of an IPv4-only
        backup.
    #>
    param(
        [AllowNull()]
        [PSCustomObject]$Backup
    )

    if (-not $Backup) {
        return [PSCustomObject]@{
            Mode      = "Dhcp"
            Servers   = @()
            ServersV4 = @()
            ServersV6 = @()
            Reason    = "no backup on file for this adapter"
        }
    }

    $v4 = @($Backup.PreviousDNS)
    $v6 = @($Backup.PreviousDNSv6)

    if ($v4.Count -eq 0 -and $v6.Count -eq 0) {
        return [PSCustomObject]@{
            Mode      = "Dhcp"
            Servers   = @()
            ServersV4 = @()
            ServersV6 = @()
            Reason    = "the backup shows this adapter was on DHCP-supplied DNS"
        }
    }

    [PSCustomObject]@{
        Mode      = "Static"
        Servers   = @($v4 + $v6)
        ServersV4 = $v4
        ServersV6 = $v6
        Reason    = "restoring the DNS recorded in $(Split-Path $Backup.Path -Leaf)"
    }
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
    .DESCRIPTION
        Always sets the IPv4 pair. When both IPv6 addresses are supplied they are
        sent in the same Set-DnsClientServerAddress call (Windows routes each
        address to its own family) and the IPv6 family is verified too, so a
        partial apply is reported as a failure (#8).
    #>
    param(
        [Parameter(Mandatory)]
        [int]$InterfaceIndex,
        [Parameter(Mandatory)]
        [string]$PrimaryDns,
        [Parameter(Mandatory)]
        [string]$SecondaryDns,
        [string]$PrimaryDnsV6 = "",
        [string]$SecondaryDnsV6 = ""
    )

    $applyV6 = -not [string]::IsNullOrWhiteSpace($PrimaryDnsV6) -and
               -not [string]::IsNullOrWhiteSpace($SecondaryDnsV6)

    $addresses = @($PrimaryDns, $SecondaryDns)
    if ($applyV6) { $addresses += @($PrimaryDnsV6, $SecondaryDnsV6) }

    try {
        Set-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -ServerAddresses $addresses -ErrorAction Stop
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
    $ipv4Ok = ($newDns[0] -eq $PrimaryDns) -and ($newDns.Count -ge 2 -and $newDns[1] -eq $SecondaryDns)

    if (-not $applyV6) { return $ipv4Ok }

    try {
        $newDns6 = (Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv6 -ErrorAction Stop).ServerAddresses
    } catch {
        return $false
    }
    if (-not $newDns6 -or $newDns6.Count -eq 0) { return $false }
    $ipv6Ok = ($newDns6[0] -eq $PrimaryDnsV6) -and ($newDns6.Count -ge 2 -and $newDns6[1] -eq $SecondaryDnsV6)

    $ipv4Ok -and $ipv6Ok
}

function Test-DnsAlreadyOptimal {
    <#
    .SYNOPSIS
        Returns $true when the adapter is already pointed at exactly the DNS the
        benchmark wants to apply, so the run can stop without touching anything.
    .DESCRIPTION
        The old inline check compared $currentDns[0] against the winner's primary
        and nothing else. That predates IPv6 support, so a machine already on the
        winning IPv4 pair with the router's IPv6 DNS still bound counted as
        optimal and -IncludeIPv6 could never apply. That is the exact leak the
        switch exists to close. A mismatched secondary slipped through the same
        way.

        Both addresses of a family have to match, and the list has to be exactly
        that pair: an adapter carrying a third server is not what an apply would
        leave behind, so it is not already optimal. IPv6 is only weighed when
        -IncludeV6 is set, since without it the IPv6 config is never touched.
    #>
    param(
        [AllowEmptyCollection()]
        [string[]]$CurrentDns = @(),
        [AllowEmptyCollection()]
        [string[]]$CurrentDnsV6 = @(),
        [Parameter(Mandatory)]
        [string]$PrimaryDns,
        [Parameter(Mandatory)]
        [string]$SecondaryDns,
        [string]$PrimaryDnsV6 = "",
        [string]$SecondaryDnsV6 = "",
        [switch]$IncludeV6
    )

    $current = @($CurrentDns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $v4Ok = ($current.Count -eq 2) -and ($current[0] -eq $PrimaryDns) -and ($current[1] -eq $SecondaryDns)

    if (-not $IncludeV6) { return $v4Ok }

    $current6 = @($CurrentDnsV6 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $v6Ok = ($current6.Count -eq 2) -and ($current6[0] -eq $PrimaryDnsV6) -and ($current6[1] -eq $SecondaryDnsV6)

    $v4Ok -and $v6Ok
}

function Test-NetworkConnectivity {
    <#
    .SYNOPSIS
        Pre-flight check that confirms DNS can actually leave this machine
        before a full benchmark is attempted (#14).
    .DESCRIPTION
        With no network, every server in the table fails identically, the tool
        still crowns a "winner" from those uniformly-broken results, and it then
        offers to apply DNS that was never really reached. This probes a small
        set of well-known anchor resolvers and reports whether at least one
        answered, so the caller can bail out with a clear message instead.
    .PARAMETER AnchorServers
        IPv4 addresses of reliable public resolvers to probe.
    .PARAMETER ProbeDomain
        Domain to resolve during the probe.
    #>
    param(
        [string[]]$AnchorServers = @("1.1.1.1", "8.8.8.8", "9.9.9.9"),
        [string]$ProbeDomain = "google.com"
    )

    $reachable = @()
    foreach ($server in $AnchorServers) {
        try {
            # -QuickTimeout keeps a fully offline probe from stalling on each
            # anchor; one answer is enough to prove DNS egress works.
            $null = Resolve-DnsName -Name $ProbeDomain -Server $server -DnsOnly -Type A -QuickTimeout -ErrorAction Stop
            $reachable += $server
        }
        catch {
            # A throw here is expected when offline; keep probing the rest.
            Write-Verbose "Connectivity probe to $server failed: $_"
        }
    }

    [PSCustomObject]@{
        Online           = ($reachable.Count -gt 0)
        ReachableServers = $reachable
        ProbedServers    = $AnchorServers
    }
}

function Test-IPv6Available {
    <#
    .SYNOPSIS
        Returns $true when the adapter has the IPv6 stack bound, $false otherwise.
    .DESCRIPTION
        Setting IPv6 DNS on an adapter whose IPv6 (ms_tcpip6) binding is disabled
        throws. This checks the binding first so the caller can fall back to an
        IPv4-only apply cleanly. Fail-safe to $false: if the binding cannot be
        read, IPv6 is treated as unavailable and only IPv4 is applied (#8).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$AdapterName
    )

    try {
        $binding = Get-NetAdapterBinding -Name $AdapterName -ComponentID 'ms_tcpip6' -ErrorAction Stop
    } catch {
        return $false
    }
    [bool]($binding -and $binding.Enabled)
}

function Test-ParallelSupported {
    <#
    .SYNOPSIS
        Returns $true when the running PowerShell can run the benchmark in parallel (#12).
    .DESCRIPTION
        Parallel benchmarking relies on the thread-based ForEach-Object -Parallel that
        arrived in PowerShell 7.0. Windows PowerShell 5.1 has no such thing, so -Parallel
        falls back to the sequential loop there. The version is passed in rather than read
        from $PSVersionTable so this stays a pure, testable check.
    #>
    param(
        [Parameter(Mandatory)]
        [version]$PSVersion
    )
    $PSVersion.Major -ge 7
}

function Invoke-ParallelBenchmark {
    <#
    .SYNOPSIS
        Benchmarks every resolver concurrently and returns their result objects (#12).
    .DESCRIPTION
        Fans the per-server work out across threads with ForEach-Object -Parallel and
        reuses the same Get-DnsServerResults that the sequential path uses, so a server's
        score is computed identically either way. Functions defined in the parent scope
        are not visible inside a -Parallel block, so Get-DnsServerResults is rebuilt inside
        each thread from its source text (passed as -GetResultsDef). Results arrive in
        completion order, which is fine because the caller re-sorts by composite score.
        Requires PowerShell 7+; Test-ParallelSupported gates the call.
    .PARAMETER GetResultsDef
        The source text of Get-DnsServerResults, e.g.
        ${function:Get-DnsServerResults}.ToString().
    #>
    param(
        [Parameter(Mandatory)]
        [array]$DnsServers,
        [Parameter(Mandatory)]
        [string[]]$Domains,
        [Parameter(Mandatory)]
        [int]$QueryCount,
        [Parameter(Mandatory)]
        [string]$GetResultsDef,
        [ValidateRange(1, 64)]
        [int]$ThrottleLimit = 8
    )

    $DnsServers | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        # Rebuild the benchmarking function in this thread's runspace, then run it.
        ${function:Get-DnsServerResults} = $using:GetResultsDef
        Get-DnsServerResults -DnsServer $_ -Domains $using:Domains -QueryCount $using:QueryCount
    }
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
# Each entry: Name, Primary IPv4, Secondary IPv4, Security Score (0-100), Features,
# and optional PrimaryV6/SecondaryV6 anycast addresses for providers that publish
# them. IPv6 is only applied when -IncludeIPv6 is set (see Set-OptimalDns). Entries
# without published, stable IPv6 anycast are intentionally left IPv4-only.
# Security scoring based on: DNSSEC validation, no-logging policy, malware blocking,
# DNS-over-HTTPS support, DNS-over-TLS support, open-source/audited
$DnsServers = @(
    @{ Name = "Cloudflare";              Primary = "1.1.1.1";       Secondary = "1.0.0.1";       PrimaryV6 = "2606:4700:4700::1111"; SecondaryV6 = "2606:4700:4700::1001"; SecurityScore = 92;  Features = "DNSSEC, DoH, DoT, no-log policy, audited privacy" }
    @{ Name = "Cloudflare (Malware)";    Primary = "1.1.1.2";       Secondary = "1.0.0.2";       PrimaryV6 = "2606:4700:4700::1112"; SecondaryV6 = "2606:4700:4700::1002"; SecurityScore = 95;  Features = "DNSSEC, DoH, DoT, malware blocking, no-log" }
    @{ Name = "Cloudflare (Family)";     Primary = "1.1.1.3";       Secondary = "1.0.0.3";       PrimaryV6 = "2606:4700:4700::1113"; SecondaryV6 = "2606:4700:4700::1003"; SecurityScore = 95;  Features = "DNSSEC, DoH, DoT, malware + adult blocking" }
    @{ Name = "Google";                  Primary = "8.8.8.8";       Secondary = "8.8.4.4";       PrimaryV6 = "2001:4860:4860::8888"; SecondaryV6 = "2001:4860:4860::8844"; SecurityScore = 78;  Features = "DNSSEC, DoH, DoT, logs anonymized after 48h" }
    @{ Name = "Quad9";                   Primary = "9.9.9.9";       Secondary = "149.112.112.112"; PrimaryV6 = "2620:fe::fe"; SecondaryV6 = "2620:fe::9"; SecurityScore = 96; Features = "DNSSEC, DoH, DoT, threat blocking, non-profit, no-log" }
    @{ Name = "Quad9 (Unfiltered)";      Primary = "9.9.9.10";      Secondary = "149.112.112.10"; PrimaryV6 = "2620:fe::10"; SecondaryV6 = "2620:fe::fe:10"; SecurityScore = 88;  Features = "DNSSEC, DoH, DoT, no filtering, no-log" }
    @{ Name = "OpenDNS";                 Primary = "208.67.222.222"; Secondary = "208.67.220.220"; PrimaryV6 = "2620:119:35::35"; SecondaryV6 = "2620:119:53::53"; SecurityScore = 80;  Features = "DNSSEC, DoH, phishing protection, Cisco-owned" }
    @{ Name = "OpenDNS (FamilyShield)";  Primary = "208.67.222.123"; Secondary = "208.67.220.123"; SecurityScore = 82; Features = "DNSSEC, DoH, family filter, phishing protection" }
    @{ Name = "AdGuard";                 Primary = "94.140.14.14";  Secondary = "94.140.15.15";  PrimaryV6 = "2a10:50c0::ad1:ff"; SecondaryV6 = "2a10:50c0::ad2:ff"; SecurityScore = 90;  Features = "DNSSEC, DoH, DoT, ad/tracker/malware blocking" }
    @{ Name = "AdGuard (Family)";        Primary = "94.140.14.15";  Secondary = "94.140.15.16";  PrimaryV6 = "2a10:50c0::bad1:ff"; SecondaryV6 = "2a10:50c0::bad2:ff"; SecurityScore = 91;  Features = "DNSSEC, DoH, DoT, family filter + ad blocking" }
    @{ Name = "Comodo Secure";           Primary = "8.26.56.26";    Secondary = "8.20.247.20";   SecurityScore = 72;  Features = "Malware blocking, phishing protection" }
    @{ Name = "CleanBrowsing (Security)";Primary = "185.228.168.9"; Secondary = "185.228.169.9"; PrimaryV6 = "2a0d:2a00:1::"; SecondaryV6 = "2a0d:2a00:2::"; SecurityScore = 88;  Features = "DNSSEC, DoH, DoT, malware/phishing blocking" }
    @{ Name = "CleanBrowsing (Family)";  Primary = "185.228.168.168"; Secondary = "185.228.169.168"; PrimaryV6 = "2a0d:2a00:1::1"; SecondaryV6 = "2a0d:2a00:2::1"; SecurityScore = 89; Features = "DNSSEC, DoH, DoT, family + security filter" }
    @{ Name = "Mullvad";                 Primary = "194.242.2.2";   Secondary = "194.242.2.3";   PrimaryV6 = "2a07:e340::2"; SecondaryV6 = "2a07:e340::3"; SecurityScore = 94;  Features = "DNSSEC, DoH, DoT, no-log, privacy-focused VPN company" }
    @{ Name = "Control D";              Primary = "76.76.2.0";     Secondary = "76.76.10.0";    PrimaryV6 = "2606:1a40::"; SecondaryV6 = "2606:1a40:1::"; SecurityScore = 86;  Features = "DNSSEC, DoH, DoT, customizable filtering" }
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
    Write-Header "Restoring Previous DNS Settings"

    $adapter = Get-ActiveNetworkAdapter
    if (-not $adapter) {
        Write-Err "No active network adapter found."
        exit 1
    }

    Write-Status "Adapter: $($adapter.Name)"

    # -ResetDhcp is the old unconditional behaviour, kept for anyone who wants
    # DHCP regardless of what the backup says.
    $plan = if ($ResetDhcp) {
        [PSCustomObject]@{ Mode = "Dhcp"; Servers = @(); ServersV4 = @(); ServersV6 = @(); Reason = "-ResetDhcp was passed" }
    } else {
        Get-DnsRestorePlan -Backup (Get-LatestDnsBackup -BackupDir $ScriptDir -AdapterName $adapter.Name)
    }

    if ($plan.Mode -eq "Static") {
        Write-Info "Source: $($plan.Reason)"
        try {
            # Reset first so a family the backup does not mention goes back to
            # DHCP instead of keeping whatever this tool last applied to it.
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $plan.Servers -ErrorAction Stop
        }
        catch {
            Write-Err "Failed to restore DNS: $_"
            Write-Info "Run '.\DNS-Benchmark.ps1 -Restore -ResetDhcp' to fall back to automatic DNS."
            exit 1
        }
        $null = Clear-DnsClientCache 2>$null
        Write-Success "DNS restored on '$($adapter.Name)': $($plan.ServersV4 -join ', ')"
        if ($plan.ServersV6.Count -gt 0) { Write-Success "IPv6 DNS restored: $($plan.ServersV6 -join ', ')" }
        Write-Info "DNS cache flushed"
        exit 0
    }

    if (-not (Test-StaticDnsConfigured -InterfaceIndex $adapter.InterfaceIndex)) {
        Write-Info "'$($adapter.Name)' is already using DHCP-supplied DNS. Nothing to restore."
        exit 0
    }

    Write-Info "Falling back to automatic DNS: $($plan.Reason)."
    Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ResetServerAddresses
    $null = Clear-DnsClientCache 2>$null
    Write-Success "DNS restored to automatic (DHCP) on '$($adapter.Name)'"
    Write-Info "DNS cache flushed"
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

# -- Pre-flight connectivity check ---------------------------------------------
# Bail out before the benchmark if DNS cannot leave the machine. Otherwise every
# server fails the same way and the tool crowns a meaningless "winner" (#14).
Write-Status "Checking DNS connectivity..."
$connectivity = Test-NetworkConnectivity
if (-not $connectivity.Online) {
    Write-Err "No DNS connectivity. Probed $($connectivity.ProbedServers -join ', ') and none answered."
    Write-Info "Check your network connection and try again."
    exit 1
}
Write-Success "Connectivity OK (reached $($connectivity.ReachableServers -join ', '))"

# -- Benchmark ------------------------------------------------------------------
Write-Header "Benchmarking $($DnsServers.Count) DNS Servers"
Write-Info "Testing $TestCount queries x $($TestDomains.Count) domains per server..."

# -Parallel only works on PowerShell 7+, where ForEach-Object -Parallel exists.
# On 5.1 we say so and run sequentially rather than failing.
$useParallel = $Parallel -and (Test-ParallelSupported -PSVersion $PSVersionTable.PSVersion)
if ($Parallel -and -not $useParallel) {
    Write-Info "-Parallel needs PowerShell 7 or newer. Running sequentially instead."
}
Write-Host ""

if ($useParallel) {
    Write-Info "Running benchmarks in parallel (up to $ThrottleLimit at once)."
    Write-Info "Latency can read a touch higher than a sequential run since the servers share the link; drop -Parallel when you want the most precise numbers."
    Write-Host ""

    $results = @(Invoke-ParallelBenchmark -DnsServers $DnsServers -Domains $TestDomains -QueryCount $TestCount `
        -GetResultsDef (${function:Get-DnsServerResults}.ToString()) -ThrottleLimit $ThrottleLimit)

    Write-Success "Benchmarked $($results.Count) servers."
    Write-Host ""
}
else {
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
}

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

    # Decide whether IPv6 is in play: the opt-in switch is set, the winning
    # resolver publishes IPv6 anycast, and the adapter actually has IPv6 bound.
    # Any of those missing and we apply IPv4 only, exactly as before (#8).
    $winnerV6Primary   = if ($winner.PrimaryV6)   { [string]$winner.PrimaryV6 }   else { "" }
    $winnerV6Secondary = if ($winner.SecondaryV6) { [string]$winner.SecondaryV6 } else { "" }
    $applyV6 = $IncludeIPv6 -and
               -not [string]::IsNullOrWhiteSpace($winnerV6Primary) -and
               -not [string]::IsNullOrWhiteSpace($winnerV6Secondary) -and
               (Test-IPv6Available -AdapterName $adapter.Name)

    if ($IncludeIPv6 -and -not $applyV6) {
        if ([string]::IsNullOrWhiteSpace($winnerV6Primary)) {
            Write-Info "-IncludeIPv6 set, but $($winner.Name) has no IPv6 address on file. Applying IPv4 only."
        } else {
            Write-Info "-IncludeIPv6 set, but this adapter has no IPv6 bound. Applying IPv4 only."
        }
    }

    # Read the current IPv6 servers before deciding whether anything needs to
    # change. With -IncludeIPv6 an adapter can already hold the winning IPv4 pair
    # while still resolving over whatever IPv6 DNS the router handed out, and
    # that is precisely the case the switch is for.
    $currentDnsV6 = @()
    if ($applyV6) {
        try {
            $currentDnsV6 = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv6 -ErrorAction Stop).ServerAddresses)
        } catch {
            $currentDnsV6 = @()
        }
    }

    # Check if already using the winner
    $optimalCheck = @{
        CurrentDns     = @($currentDns)
        CurrentDnsV6   = $currentDnsV6
        PrimaryDns     = $winner.Primary
        SecondaryDns   = $winner.Secondary
        PrimaryDnsV6   = $winnerV6Primary
        SecondaryDnsV6 = $winnerV6Secondary
        IncludeV6      = $applyV6
    }
    if (Test-DnsAlreadyOptimal @optimalCheck) {
        Write-Success "You're already using the best DNS ($($winner.Name)). No changes needed!"
        exit 0
    }

    Write-Status "This will change DNS on '$($adapter.Name)' to:"
    Write-Host "         Primary:   $($winner.Primary)" -ForegroundColor White
    Write-Host "         Secondary: $($winner.Secondary)" -ForegroundColor White
    if ($applyV6) {
        Write-Host "         IPv6 Pri:  $winnerV6Primary" -ForegroundColor White
        Write-Host "         IPv6 Sec:  $winnerV6Secondary" -ForegroundColor White
    }
    Write-Host ""

    $confirm = Read-Host "  Apply these settings? (Y/n)"
    if ($confirm -match "^[Yy]?$") {
        try {
            $backupPath = Backup-DnsSettings -BackupDir $ScriptDir -AdapterName $adapter.Name -InterfaceIndex $adapter.InterfaceIndex -CurrentDns $currentDns -CurrentDnsV6 $currentDnsV6
            Write-Info "Backup saved: $backupPath"

            $applied = if ($applyV6) {
                Set-OptimalDns -InterfaceIndex $adapter.InterfaceIndex -PrimaryDns $winner.Primary -SecondaryDns $winner.Secondary -PrimaryDnsV6 $winnerV6Primary -SecondaryDnsV6 $winnerV6Secondary
            } else {
                Set-OptimalDns -InterfaceIndex $adapter.InterfaceIndex -PrimaryDns $winner.Primary -SecondaryDns $winner.Secondary
            }

            if ($applied) {
                Write-Host ""
                Write-Success "DNS changed to $($winner.Name) ($($winner.Primary), $($winner.Secondary))"
                if ($applyV6) { Write-Success "IPv6 DNS set ($winnerV6Primary, $winnerV6Secondary)" }
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
