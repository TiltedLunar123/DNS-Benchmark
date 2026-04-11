# DNS Benchmark & Optimizer

A PowerShell script that benchmarks 17+ public DNS resolvers for speed, reliability, and security — then applies the best one to your system automatically.

[![CI](https://github.com/TiltedLunar123/DNS-Benchmark/actions/workflows/ci.yml/badge.svg)](https://github.com/TiltedLunar123/DNS-Benchmark/actions/workflows/ci.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Windows](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6?logo=windows)
![License](https://img.shields.io/badge/License-MIT-green)

## What It Does

1. **Detects** your active network adapter and current DNS settings
2. **Benchmarks** 17 DNS providers across 10 test domains with multiple queries each
3. **Scores** each provider using a weighted composite:
   - **Speed** (40%) — average query latency
   - **Reliability** (25%) — successful resolution rate
   - **Security** (25%) — DNSSEC, encryption, logging policy, threat blocking
   - **Consistency** (10%) — low jitter / stable response times
4. **Recommends** the best DNS for your network
5. **Applies** the winning DNS to your system (with confirmation + backup)

## DNS Providers Tested

| Provider | Primary IP | Security Features |
|----------|-----------|-------------------|
| Cloudflare | 1.1.1.1 | DNSSEC, DoH, DoT, audited no-log |
| Cloudflare (Malware) | 1.1.1.2 | + malware blocking |
| Cloudflare (Family) | 1.1.1.3 | + malware & adult content blocking |
| Google | 8.8.8.8 | DNSSEC, DoH, DoT |
| Quad9 | 9.9.9.9 | DNSSEC, DoH, DoT, threat blocking, non-profit |
| Quad9 (Unfiltered) | 9.9.9.10 | DNSSEC, DoH, DoT, no filtering |
| OpenDNS | 208.67.222.222 | DNSSEC, DoH, phishing protection |
| OpenDNS (FamilyShield) | 208.67.222.123 | + family content filter |
| AdGuard | 94.140.14.14 | DNSSEC, DoH, DoT, ad/tracker blocking |
| AdGuard (Family) | 94.140.14.15 | + family content filter |
| Comodo Secure | 8.26.56.26 | Malware & phishing blocking |
| CleanBrowsing (Security) | 185.228.168.9 | DNSSEC, DoH, DoT, malware blocking |
| CleanBrowsing (Family) | 185.228.168.168 | + family content filter |
| Mullvad | 194.242.2.2 | DNSSEC, DoH, DoT, privacy-focused |
| Control D | 76.76.2.0 | DNSSEC, DoH, DoT, customizable |
| Neustar UltraDNS | 64.6.64.6 | DNSSEC, enterprise-grade |
| Level3 / CenturyLink | 4.2.2.1 | Basic DNS |

## One-Line Install & Run

Paste this into **any PowerShell window** — it auto-elevates to admin, downloads, benchmarks, and applies the best DNS:

```powershell
irm https://raw.githubusercontent.com/TiltedLunar123/DNS-Benchmark/master/install.ps1 | iex
```

**What happens:**
1. Requests admin privileges (UAC prompt)
2. Downloads the latest script to `%USERPROFILE%\DNS-Benchmark\`
3. Runs the full benchmark
4. Window stays open so you can see the results and confirm changes
5. Saves the script locally so you can re-run anytime

## Quick Start (Manual)

```powershell
# Run as Administrator
.\DNS-Benchmark.ps1
```

The script will benchmark all DNS servers and ask before applying any changes.

## Usage

```powershell
# Full benchmark + apply best DNS (interactive)
.\DNS-Benchmark.ps1

# Benchmark only, don't change anything
.\DNS-Benchmark.ps1 -SkipApply

# Run with more queries for higher accuracy
.\DNS-Benchmark.ps1 -TestCount 10

# Export results to CSV
.\DNS-Benchmark.ps1 -Report

# Combine flags
.\DNS-Benchmark.ps1 -TestCount 10 -Report -SkipApply

# Restore DNS back to automatic (DHCP)
.\DNS-Benchmark.ps1 -Restore
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-TestCount` | int | 5 | Queries per DNS per domain |
| `-SkipApply` | switch | false | Benchmark only, don't apply changes |
| `-Restore` | switch | false | Reset DNS to DHCP/automatic |
| `-Report` | switch | false | Export results to CSV |

## How Scoring Works

Each DNS server gets a **composite score** out of 100:

```
Score = (Speed × 0.40) + (Reliability × 0.25) + (Security × 0.25) + (Consistency × 0.10)
```

- **Speed** — Normalized average latency across all test queries (lower = better)
- **Reliability** — Percentage of queries that resolved successfully
- **Security** — Pre-assigned score based on known features: DNSSEC validation, encryption (DoH/DoT), logging policy, threat blocking, audits
- **Consistency** — Normalized jitter / standard deviation of response times

Results are displayed with letter grades (A+ through F) and the top 3 are starred.

## Safety Features

- **Asks before applying** — won't change DNS without your confirmation
- **Automatic backup** — saves your previous DNS settings to a timestamped file before changing
- **Easy restore** — run with `-Restore` to go back to DHCP defaults
- **Admin required** — script won't run without elevated privileges

## Example Output

```
  DNS Server                     Avg (ms)   Med (ms)     Jitter     Rely %     Security    Score    Grade
  ----------------------------------------------------------------------------------------------------------
★ Quad9                             12.45      11.20       3.21     100.0%       96/100     89.2       A+
★ Cloudflare                         8.33       7.50       2.10     100.0%       92/100     88.5       A+
★ Cloudflare (Malware)              10.12       9.80       2.55     100.0%       95/100     87.1       A
  Mullvad                           18.90      17.60       4.33      99.8%       94/100     82.4       A-
  ...
```

## Requirements

- Windows 10/11
- PowerShell 5.1+ (pre-installed on Windows 10/11)
- **Run as Administrator** (required to change DNS settings)

## License

MIT License — see [LICENSE](LICENSE) for details.
