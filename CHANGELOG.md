# Changelog

All notable changes to DNS Benchmark & Optimizer are documented here.

## [Unreleased]

### Fixed
- `Set-OptimalDns` now returns `$false` on error instead of throwing, matching the documented boolean contract. Both the DNS apply and verify calls are wrapped with `-ErrorAction Stop` and try/catch (#20).
- DNS backup files now use a `.json` extension instead of `.txt` so their contents match the name at a glance (#21). `.gitignore` updated to match.

### Added
- Pester coverage for `Set-OptimalDns` (success plus two failure paths) and the backup file extension.

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
