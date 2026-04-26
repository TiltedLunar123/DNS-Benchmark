#Requires -Modules Pester

BeforeAll {
    # Dot-source the script functions by extracting them via AST parsing.
    # This lets us test individual functions without running the main script body.
    $scriptPath = Join-Path (Join-Path $PSScriptRoot "..") "DNS-Benchmark.ps1"
    $scriptContent = Get-Content $scriptPath -Raw

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptContent, [ref]$null, [ref]$null)
    $functions = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

    foreach ($func in $functions) {
        Invoke-Expression $func.Extent.Text
    }
}

# ---------------------------------------------------------------------------
# Get-LetterGrade
# ---------------------------------------------------------------------------
Describe "Get-LetterGrade" {
    It "Should return A+ for score >= 90" {
        Get-LetterGrade -Score 90 | Should -Be "A+"
        Get-LetterGrade -Score 100 | Should -Be "A+"
        Get-LetterGrade -Score 95.5 | Should -Be "A+"
    }

    It "Should return A for score 85-89" {
        Get-LetterGrade -Score 85 | Should -Be "A"
        Get-LetterGrade -Score 89.9 | Should -Be "A"
    }

    It "Should return A- for score 80-84" {
        Get-LetterGrade -Score 80 | Should -Be "A-"
        Get-LetterGrade -Score 84.9 | Should -Be "A-"
    }

    It "Should return B+ for score 75-79" {
        Get-LetterGrade -Score 75 | Should -Be "B+"
        Get-LetterGrade -Score 79.9 | Should -Be "B+"
    }

    It "Should return B for score 70-74" {
        Get-LetterGrade -Score 70 | Should -Be "B"
        Get-LetterGrade -Score 74.9 | Should -Be "B"
    }

    It "Should return B- for score 65-69" {
        Get-LetterGrade -Score 65 | Should -Be "B-"
        Get-LetterGrade -Score 69.9 | Should -Be "B-"
    }

    It "Should return C+ for score 60-64" {
        Get-LetterGrade -Score 60 | Should -Be "C+"
        Get-LetterGrade -Score 64.9 | Should -Be "C+"
    }

    It "Should return C for score 55-59" {
        Get-LetterGrade -Score 55 | Should -Be "C"
        Get-LetterGrade -Score 59.9 | Should -Be "C"
    }

    It "Should return C- for score 50-54" {
        Get-LetterGrade -Score 50 | Should -Be "C-"
        Get-LetterGrade -Score 54.9 | Should -Be "C-"
    }

    It "Should return D for score 40-49" {
        Get-LetterGrade -Score 40 | Should -Be "D"
        Get-LetterGrade -Score 49.9 | Should -Be "D"
    }

    It "Should return F for score < 40" {
        Get-LetterGrade -Score 39.9 | Should -Be "F"
        Get-LetterGrade -Score 0 | Should -Be "F"
        Get-LetterGrade -Score 10 | Should -Be "F"
    }
}

# ---------------------------------------------------------------------------
# Get-CompositeScore
# ---------------------------------------------------------------------------
Describe "Get-CompositeScore" {
    Context "Normal latency range" {
        It "Should return 0 for a server with AvgLatency >= 9999" {
            $result = [PSCustomObject]@{
                AvgLatency    = 9999
                Jitter        = 9999
                Reliability   = 0
                SecurityScore = 80
            }
            Get-CompositeScore -Result $result -MaxLatencyBound 100 -MinLatencyBound 10 -MaxJitterBound 50 | Should -Be 0
        }

        It "Should weight speed at 40%, reliability 25%, security 25%, consistency 10%" {
            # Best possible server: lowest latency, 100% reliable, 100 security, 0 jitter
            $result = [PSCustomObject]@{
                AvgLatency    = 10.0   # equals min = perfect speed score (100)
                Jitter        = 0.0    # zero jitter = perfect consistency (100)
                Reliability   = 100.0
                SecurityScore = 100
            }
            $score = Get-CompositeScore -Result $result -MaxLatencyBound 100 -MinLatencyBound 10 -MaxJitterBound 50
            # (100 * 0.40) + (100 * 0.25) + (100 * 0.25) + (100 * 0.10) = 100
            $score | Should -Be 100
        }

        It "Should score a mid-range server proportionally" {
            # Server at midpoint latency, some jitter, decent reliability/security
            $result = [PSCustomObject]@{
                AvgLatency    = 55.0   # mid of 10-100 range -> speed ~50
                Jitter        = 25.0   # mid of 0-50 range -> consistency ~50
                Reliability   = 80.0
                SecurityScore = 70
            }
            $score = Get-CompositeScore -Result $result -MaxLatencyBound 100 -MinLatencyBound 10 -MaxJitterBound 50
            # speed = (1 - (55-10)/(100-10)) * 100 = 50
            # consistency = (1 - 25/50) * 100 = 50
            # (50*0.40) + (80*0.25) + (70*0.25) + (50*0.10) = 20 + 20 + 17.5 + 5 = 62.5
            $score | Should -Be 62.5
        }

        It "Should give worst speed score to the slowest server" {
            $result = [PSCustomObject]@{
                AvgLatency    = 100.0  # equals max = worst speed score (0)
                Jitter        = 0.0
                Reliability   = 100.0
                SecurityScore = 100
            }
            $score = Get-CompositeScore -Result $result -MaxLatencyBound 100 -MinLatencyBound 10 -MaxJitterBound 50
            # speed = 0, consistency = 100
            # (0*0.40) + (100*0.25) + (100*0.25) + (100*0.10) = 0 + 25 + 25 + 10 = 60
            $score | Should -Be 60
        }
    }

    Context "Edge cases" {
        It "Should handle zero latency range (all servers equal speed)" {
            $result = [PSCustomObject]@{
                AvgLatency    = 50.0
                Jitter        = 5.0
                Reliability   = 100.0
                SecurityScore = 90
            }
            # When min == max latency, speed score should be 100
            $score = Get-CompositeScore -Result $result -MaxLatencyBound 50 -MinLatencyBound 50 -MaxJitterBound 10
            # (100*0.40) + (100*0.25) + (90*0.25) + (50*0.10) = 40 + 25 + 22.5 + 5 = 92.5
            $score | Should -Be 92.5
        }

        It "Should clamp to zero when jitter exceeds MaxJitterBound" {
            $result = [PSCustomObject]@{
                AvgLatency    = 10.0
                Jitter        = 80.0
                Reliability   = 100.0
                SecurityScore = 90
            }
            $score = Get-CompositeScore -Result $result -MaxLatencyBound 100 -MinLatencyBound 10 -MaxJitterBound 50
            $score | Should -BeGreaterOrEqual 0
        }

        It "Should never return a negative score" {
            $result = [PSCustomObject]@{
                AvgLatency    = 200.0
                Jitter        = 150.0
                Reliability   = 50.0
                SecurityScore = 30
            }
            $score = Get-CompositeScore -Result $result -MaxLatencyBound 100 -MinLatencyBound 10 -MaxJitterBound 50
            $score | Should -BeGreaterOrEqual 0
        }

        It "Should handle zero jitter bound" {
            $result = [PSCustomObject]@{
                AvgLatency    = 20.0
                Jitter        = 0.0
                Reliability   = 100.0
                SecurityScore = 80
            }
            $score = Get-CompositeScore -Result $result -MaxLatencyBound 100 -MinLatencyBound 10 -MaxJitterBound 0
            $score | Should -BeGreaterThan 0
        }
    }
}

# ---------------------------------------------------------------------------
# Get-DnsServerResults (mocked Resolve-DnsName)
# ---------------------------------------------------------------------------
Describe "Get-DnsServerResults" {
    BeforeAll {
        $testServer = @{
            Name          = "TestDNS"
            Primary       = "1.2.3.4"
            Secondary     = "5.6.7.8"
            SecurityScore = 85
            Features      = "Test features"
        }
    }

    Context "When all queries succeed" {
        BeforeAll {
            Mock Resolve-DnsName { }
        }

        It "Should return 100% reliability" {
            $result = Get-DnsServerResults -DnsServer $testServer -Domains @("example.com") -QueryCount 3
            $result.Reliability | Should -Be 100.0
            $result.Failures | Should -Be 0
        }

        It "Should set correct total query count" {
            $result = Get-DnsServerResults -DnsServer $testServer -Domains @("a.com", "b.com") -QueryCount 5
            $result.TotalQueries | Should -Be 10
        }

        It "Should populate all latency fields" {
            $result = Get-DnsServerResults -DnsServer $testServer -Domains @("example.com") -QueryCount 3
            $result.AvgLatency | Should -BeLessThan 9999
            $result.MinLatency | Should -BeLessThan 9999
            $result.MaxLatency | Should -BeLessThan 9999
            $result.MedianLatency | Should -BeLessThan 9999
            $result.Jitter | Should -BeLessThan 9999
        }

        It "Should carry through server metadata" {
            $result = Get-DnsServerResults -DnsServer $testServer -Domains @("example.com") -QueryCount 1
            $result.Name | Should -Be "TestDNS"
            $result.Primary | Should -Be "1.2.3.4"
            $result.Secondary | Should -Be "5.6.7.8"
            $result.SecurityScore | Should -Be 85
            $result.Features | Should -Be "Test features"
        }
    }

    Context "When all queries fail" {
        BeforeAll {
            Mock Resolve-DnsName { throw "DNS resolution failed" }
        }

        It "Should return AvgLatency of 9999" {
            $result = Get-DnsServerResults -DnsServer $testServer -Domains @("example.com") -QueryCount 2
            $result.AvgLatency | Should -Be 9999
        }

        It "Should return 0% reliability" {
            $result = Get-DnsServerResults -DnsServer $testServer -Domains @("example.com") -QueryCount 2
            $result.Reliability | Should -Be 0
        }

        It "Should count all queries as failures" {
            $result = Get-DnsServerResults -DnsServer $testServer -Domains @("a.com", "b.com") -QueryCount 3
            $result.Failures | Should -Be 6
            $result.TotalQueries | Should -Be 6
        }
    }

    Context "When some queries fail" {
        It "Should calculate partial reliability" {
            # Mock: first call succeeds, second throws
            $script:callCount = 0
            Mock Resolve-DnsName {
                $script:callCount++
                if ($script:callCount % 2 -eq 0) { throw "fail" }
            }
            $result = Get-DnsServerResults -DnsServer $testServer -Domains @("example.com") -QueryCount 4
            $result.Reliability | Should -BeLessThan 100
            $result.Reliability | Should -BeGreaterThan 0
            $result.Failures | Should -BeGreaterThan 0
        }
    }
}

# ---------------------------------------------------------------------------
# Get-ActiveNetworkAdapter (mocked Get-NetAdapter)
# ---------------------------------------------------------------------------
Describe "Get-ActiveNetworkAdapter" {
    Context "When adapters are available" {
        It "Should return the first UP, non-virtual adapter" {
            Mock Get-NetAdapter {
                @(
                    [PSCustomObject]@{ Name = "Wi-Fi"; Status = "Up"; InterfaceDescription = "Intel Wireless" }
                    [PSCustomObject]@{ Name = "Ethernet"; Status = "Up"; InterfaceDescription = "Realtek Ethernet" }
                )
            }
            $result = Get-ActiveNetworkAdapter
            $result.Name | Should -Be "Wi-Fi"
        }

        It "Should exclude virtual adapters" {
            Mock Get-NetAdapter {
                @(
                    [PSCustomObject]@{ Name = "vEthernet"; Status = "Up"; InterfaceDescription = "Hyper-V Virtual Ethernet" }
                    [PSCustomObject]@{ Name = "Ethernet"; Status = "Up"; InterfaceDescription = "Realtek Ethernet" }
                )
            }
            $result = Get-ActiveNetworkAdapter
            $result.Name | Should -Be "Ethernet"
        }

        It "Should exclude Bluetooth adapters" {
            Mock Get-NetAdapter {
                @(
                    [PSCustomObject]@{ Name = "Bluetooth"; Status = "Up"; InterfaceDescription = "Bluetooth Network" }
                    [PSCustomObject]@{ Name = "Wi-Fi"; Status = "Up"; InterfaceDescription = "Intel Wireless" }
                )
            }
            $result = Get-ActiveNetworkAdapter
            $result.Name | Should -Be "Wi-Fi"
        }

        It "Should skip adapters that are not Up" {
            Mock Get-NetAdapter {
                @(
                    [PSCustomObject]@{ Name = "Ethernet"; Status = "Disconnected"; InterfaceDescription = "Realtek Ethernet" }
                    [PSCustomObject]@{ Name = "Wi-Fi"; Status = "Up"; InterfaceDescription = "Intel Wireless" }
                )
            }
            $result = Get-ActiveNetworkAdapter
            $result.Name | Should -Be "Wi-Fi"
        }
    }

    Context "When no adapters are available" {
        It "Should return null when no adapters are up" {
            Mock Get-NetAdapter {
                @(
                    [PSCustomObject]@{ Name = "Ethernet"; Status = "Disconnected"; InterfaceDescription = "Realtek Ethernet" }
                )
            }
            $result = Get-ActiveNetworkAdapter
            $result | Should -BeNullOrEmpty
        }
    }
}

# ---------------------------------------------------------------------------
# Backup-DnsSettings
# ---------------------------------------------------------------------------
Describe "Backup-DnsSettings" {
    BeforeAll {
        $testDir = Join-Path $env:TEMP "pester-dns-backup-$(Get-Random)"
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Should create a backup file" {
        $path = Backup-DnsSettings -BackupDir $testDir -AdapterName "Wi-Fi" -InterfaceIndex 12 -CurrentDns @("8.8.8.8", "8.8.4.4")
        Test-Path $path | Should -BeTrue
    }

    It "Should create a valid JSON file" {
        $path = Backup-DnsSettings -BackupDir $testDir -AdapterName "Ethernet" -InterfaceIndex 5 -CurrentDns @("1.1.1.1")
        $content = Get-Content $path -Raw | ConvertFrom-Json
        $content.Adapter | Should -Be "Ethernet"
        $content.InterfaceIdx | Should -Be 5
        $content.PreviousDNS | Should -Be "1.1.1.1"
    }

    It "Should include an ISO 8601 timestamp" {
        $path = Backup-DnsSettings -BackupDir $testDir -AdapterName "Wi-Fi" -InterfaceIndex 1 -CurrentDns @("9.9.9.9")
        $raw = Get-Content $path -Raw
        $raw | Should -Match "\d{4}-\d{2}-\d{2}T"
    }

    It "Should create the backup directory if it does not exist" {
        $newDir = Join-Path $testDir "subdir-$(Get-Random)"
        $path = Backup-DnsSettings -BackupDir $newDir -AdapterName "Wi-Fi" -InterfaceIndex 1 -CurrentDns @("1.1.1.1")
        Test-Path $path | Should -BeTrue
    }

    It "Should use a .json extension for the backup file" {
        $path = Backup-DnsSettings -BackupDir $testDir -AdapterName "Wi-Fi" -InterfaceIndex 1 -CurrentDns @("1.1.1.1")
        $path | Should -Match "dns-backup_.+\.json$"
    }

    Context "Backup retention (#7)" {
        It "Should prune older backups beyond -MaxBackups" {
            $retentionDir = Join-Path $env:TEMP "pester-dns-retention-$(Get-Random)"
            New-Item -Path $retentionDir -ItemType Directory -Force | Out-Null

            try {
                # Seed with 8 stale backup files so we can confirm pruning order.
                for ($i = 0; $i -lt 8; $i++) {
                    $stale = Join-Path $retentionDir ("dns-backup_2025-01-{0:D2}_000000.json" -f ($i + 1))
                    "{}" | Out-File -FilePath $stale -Encoding UTF8
                    # Backdate so retention orders by LastWriteTime deterministically.
                    (Get-Item $stale).LastWriteTime = (Get-Date).AddDays(-30 + $i)
                }

                $newPath = Backup-DnsSettings -BackupDir $retentionDir -AdapterName "Wi-Fi" -InterfaceIndex 1 -CurrentDns @("1.1.1.1") -MaxBackups 5
                $remaining = @(Get-ChildItem $retentionDir -Filter "dns-backup_*.json")

                $remaining.Count | Should -Be 5
                $remaining.FullName | Should -Contain $newPath
            } finally {
                Remove-Item $retentionDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should keep all backups when count is at or below -MaxBackups" {
            $smallDir = Join-Path $env:TEMP "pester-dns-retention-small-$(Get-Random)"
            New-Item -Path $smallDir -ItemType Directory -Force | Out-Null

            try {
                $p1 = Backup-DnsSettings -BackupDir $smallDir -AdapterName "Wi-Fi" -InterfaceIndex 1 -CurrentDns @("1.1.1.1") -MaxBackups 10
                Start-Sleep -Milliseconds 1100  # ensure distinct timestamp filename
                $p2 = Backup-DnsSettings -BackupDir $smallDir -AdapterName "Wi-Fi" -InterfaceIndex 1 -CurrentDns @("1.1.1.1") -MaxBackups 10

                Test-Path $p1 | Should -BeTrue
                Test-Path $p2 | Should -BeTrue
            } finally {
                Remove-Item $smallDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Test-StaticDnsConfigured (#16 - restore mode DHCP detection)
# ---------------------------------------------------------------------------
Describe "Test-StaticDnsConfigured" {
    It "Should return `$false when adapter has no static DNS list (DHCP-only)" {
        Mock Get-CimInstance {
            [PSCustomObject]@{ DNSServerSearchOrder = @() }
        }
        Test-StaticDnsConfigured -InterfaceIndex 5 | Should -Be $false
    }

    It "Should return `$false when DNSServerSearchOrder is `$null" {
        Mock Get-CimInstance {
            [PSCustomObject]@{ DNSServerSearchOrder = $null }
        }
        Test-StaticDnsConfigured -InterfaceIndex 5 | Should -Be $false
    }

    It "Should return `$true when adapter has a static DNS list" {
        Mock Get-CimInstance {
            [PSCustomObject]@{ DNSServerSearchOrder = @("1.1.1.1", "1.0.0.1") }
        }
        Test-StaticDnsConfigured -InterfaceIndex 5 | Should -Be $true
    }

    It "Should fail-safe to `$true when CIM query throws (caller still resets)" {
        Mock Get-CimInstance { throw "WMI unavailable" }
        Test-StaticDnsConfigured -InterfaceIndex 5 | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# Set-OptimalDns
# ---------------------------------------------------------------------------
Describe "Set-OptimalDns" {
    It "Should return `$false when Set-DnsClientServerAddress throws" {
        Mock Set-DnsClientServerAddress { throw "invalid interface" }
        Mock Clear-DnsClientCache { }
        Mock Get-DnsClientServerAddress {
            [PSCustomObject]@{ ServerAddresses = @("1.1.1.1", "1.0.0.1") }
        }

        $result = Set-OptimalDns -InterfaceIndex 999 -PrimaryDns "1.1.1.1" -SecondaryDns "1.0.0.1"
        $result | Should -Be $false
    }

    It "Should return `$false when Get-DnsClientServerAddress throws" {
        Mock Set-DnsClientServerAddress { }
        Mock Clear-DnsClientCache { }
        Mock Get-DnsClientServerAddress { throw "adapter gone" }

        $result = Set-OptimalDns -InterfaceIndex 5 -PrimaryDns "1.1.1.1" -SecondaryDns "1.0.0.1"
        $result | Should -Be $false
    }

    It "Should return `$true when both DNS servers are applied correctly" {
        Mock Set-DnsClientServerAddress { }
        Mock Clear-DnsClientCache { }
        Mock Get-DnsClientServerAddress {
            [PSCustomObject]@{ ServerAddresses = @("1.1.1.1", "1.0.0.1") }
        }

        $result = Set-OptimalDns -InterfaceIndex 5 -PrimaryDns "1.1.1.1" -SecondaryDns "1.0.0.1"
        $result | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# Parameter validation
# ---------------------------------------------------------------------------
Describe "Script Parameter Validation" {
    It "Should define TestCount with ValidateRange(1, 100)" {
        $scriptPath = Join-Path (Join-Path $PSScriptRoot "..") "DNS-Benchmark.ps1"
        $scriptContent = Get-Content $scriptPath -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptContent, [ref]$null, [ref]$null)
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "TestCount" }
        $validateRange = $param.Attributes | Where-Object { $_.TypeName.Name -eq "ValidateRange" }
        $validateRange | Should -Not -BeNullOrEmpty
    }
}
