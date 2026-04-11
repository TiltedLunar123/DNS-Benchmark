# Security Policy

DNS Benchmark & Optimizer is a local-only tool that benchmarks and configures DNS settings on your Windows machine. This document describes the script's security model and how to report vulnerabilities.

## Permissions

This script requires **Administrator privileges** because changing DNS settings on Windows uses `Set-DnsClientServerAddress`, which is a protected system operation.

| Action | Why Admin Is Needed |
|---|---|
| `Set-DnsClientServerAddress` | Modify DNS on network adapter |
| `Clear-DnsClientCache` | Flush the local DNS resolver cache |
| `Get-DnsClientServerAddress` | Read current DNS configuration |

**No other elevated operations are performed.** The script does not modify the registry, install services, change firewall rules, or create scheduled tasks.

## What This Tool Does

- Sends standard DNS queries (`Resolve-DnsName -Type A`) to the 17 public DNS providers listed in the source code
- Measures response latency and reliability
- Optionally changes the DNS servers on your active network adapter (with confirmation)
- Saves a backup of your previous DNS settings to a local JSON file
- Optionally exports benchmark results to a local CSV file

## What This Tool Does NOT Do

- **No telemetry.** No usage data, analytics, or crash reports are collected or sent anywhere.
- **No network requests** beyond DNS queries to the listed public resolvers. No HTTP calls, no API endpoints.
- **No persistent changes** beyond DNS configuration. No registry edits, no startup entries, no background services.
- **No data exfiltration.** DNS queries use standard domains (google.com, github.com, etc.) — the script never sends your data to any server.
- **No credential handling.** The script does not ask for, store, or transmit any passwords, tokens, or credentials.

## Backup Behavior

Before applying DNS changes, the script:

1. Saves your current DNS settings to `dns-backup_<timestamp>.txt` (JSON format)
2. Records the adapter name, interface index, previous DNS addresses, and ISO 8601 timestamp
3. Provides a one-command restore: `.\DNS-Benchmark.ps1 -Restore`

Backups are stored locally in `%USERPROFILE%\DNS-Benchmark\` or the script's directory.

## DNS Server Database

All 17 tested DNS servers are well-known, publicly documented resolvers (Cloudflare, Google, Quad9, OpenDNS, AdGuard, Mullvad, etc.). Security scores are assigned based on publicly available information about each provider's features: DNSSEC validation, DNS-over-HTTPS, DNS-over-TLS, logging policy, and threat blocking capabilities.

The full list with IPs and security features is visible in the source code and README.

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** open a public issue.
2. Use GitHub's [private vulnerability reporting](https://github.com/TiltedLunar123/DNS-Benchmark/security/advisories/new) feature, or email the maintainer at the address listed in the GitHub profile.
3. Include:
   - A description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

I take security issues seriously and will respond as quickly as possible.

## Supported Versions

Only the latest release is actively maintained. Please ensure you're running the most recent version before reporting.
