# Changelog

All notable changes to DNS Benchmark & Optimizer are documented here.

## [Unreleased]

### Fixed
- `Set-OptimalDns` now returns `$false` on error instead of throwing, matching the documented boolean contract. Both the DNS apply and verify calls are wrapped with `-ErrorAction Stop` and try/catch (#20).
- DNS backup files now use a `.json` extension instead of `.txt` so their contents match the name at a glance (#21). `.gitignore` updated to match.
- `Resolve-DnsName` calls in the benchmark loop now use `-QuickTimeout`, so an unresponsive resolver no longer stalls the whole run for minutes (#6).
- `$ScriptDir` resolution now prefers `$PSScriptRoot` when the script is run as a real `.ps1` file, then falls back to the caller-supplied `$ScriptDir`, then to the user-profile default. Backups and reports now land next to the script when run standalone (#17).
- `-Restore` mode probes `Win32_NetworkAdapterConfiguration.DNSServerSearchOrder` first and reports "already using DHCP" instead of pretending to restore a setting that was never overridden (#16).
- Progress bar lines are padded to a fixed width derived from the longest server name, so the previous server name no longer leaks through when shorter names follow (#11).

### Added
- Optional IPv6 DNS. A new `-IncludeIPv6` switch applies the winning resolver's IPv6 anycast addresses alongside IPv4, closing the gap where a dual-stack machine could keep resolving over the router's IPv6 DNS and bypass the resolver the benchmark picked (#8). Most providers in the table now carry their published IPv6 addresses; the apply only runs when the adapter has IPv6 bound and the winner has v6 on file, and `Set-OptimalDns` verifies the IPv6 family so a partial apply reports failure. The previous IPv6 servers are recorded in the backup. Off by default, so an IPv6 config is never changed unless asked for.
- Pre-flight connectivity check before benchmarking. `Test-NetworkConnectivity` probes a small set of anchor resolvers (1.1.1.1, 8.8.8.8, 9.9.9.9) and the script now exits with a clear message when none answer, instead of ranking a table of uniformly-failed servers and offering to apply a "winner" that was never reached (#14).
- `-MaxBackups` parameter on `Backup-DnsSettings` (default 10) prunes older `dns-backup_*.json` files after each new write so they no longer accumulate forever (#7).
- Pester coverage for `Set-OptimalDns` (success plus two failure paths, plus the IPv6 apply path), `Test-IPv6Available`, the IPv6 backup field, a parsed-from-source check that every IPv6 resolver entry is a real paired IPv6 literal, the backup file extension, the retention behavior, `Test-StaticDnsConfigured`, and the connectivity probe (online, offline, and partial-reachability cases).
- Optional parallel benchmarking. A new `-Parallel` switch tests the resolvers concurrently with `ForEach-Object -Parallel` instead of one at a time, so a full pass finishes much faster (#12). It stays off by default and only engages on PowerShell 7+; on Windows PowerShell 5.1 it notes that and runs sequentially. `-ThrottleLimit` (default 8) caps how many resolvers run at once. The parallel path reuses the same `Get-DnsServerResults` as the sequential one, rebuilt inside each thread since parent-scope functions are not visible in a `-Parallel` block. Because the servers share the link while being measured, latency can read slightly higher than a sequential run; the output says so and the default mode stays the precise one. Covered by tests for the version gate and the fan-out (driven offline with a stub resolver).

## [1.1.0] — 2026-04-11

### Added
- Pester test suite with 30+ tests covering scoring, grading, benchmarking, adapter detection, and backup logic
- GitHub Actions CI pipeline — PSScriptAnalyzer lint + Pester tests on Windows
- PSScriptAnalyzer configuration with project-specific rule exclusions
- CONTRIBUTING.md with dev setup, testing instructions, and PR guidelines
- SECURITY.md documenting permissions, data handling, and vulnerability reporting
- CHANGELOG.md for version history

### Changed
- Refactored benchmark logic into testable functions (Get-DnsServerResults, Get-CompositeScore, Get-LetterGrade, Get-ActiveNetworkAdapter, Backup-DnsSettings, Set-OptimalDns)
- Added `[ValidateRange(1, 100)]` to `-TestCount` parameter
- Expanded .gitignore with OS, IDE, and test artifact patterns

## [1.0.0] — 2026-04-08

### Added
- Benchmark 17 public DNS resolvers for speed, reliability, and security
- Weighted composite scoring: Speed (40%), Reliability (25%), Security (25%), Consistency (10%)
- Letter grade ranking (A+ through F) with top-3 highlighting
- One-click DNS application with confirmation prompt
- Automatic backup of previous DNS settings to timestamped JSON
- One-command restore to DHCP defaults (`-Restore`)
- CSV report export (`-Report`)
- Benchmark-only mode (`-SkipApply`)
- Configurable query count (`-TestCount`)
- One-line installer with self-elevation (`install.ps1`)
