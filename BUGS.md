# Known Bugs

## [Severity: High] Recursive download TOCTOU in install.ps1
- **File:** install.ps1:11-14
- **Issue:** Script re-downloads itself from GitHub for the elevated process, creating a MITM window between the two downloads.
- **Repro:** Run the one-liner `irm .../install.ps1 | iex` from a non-admin prompt on a hostile network; attacker serves malicious code on the second fetch.
- **Fix:** Pass already-downloaded content to the elevated process via a temp file or argument instead of re-fetching.

## [Severity: High] Unhandled exception in Set-OptimalDns violates function contract
- **File:** DNS-Benchmark.ps1:245
- **Issue:** `Set-DnsClientServerAddress` call isn't wrapped; failures throw instead of returning the documented boolean.
- **Repro:** Call `Set-OptimalDns -InterfaceIndex 999 -PrimaryDns "1.1.1.1" -SecondaryDns "1.0.0.1"` with an invalid interface — function throws rather than returning `$false`.
- **Fix:** Wrap the call: `try { Set-DnsClientServerAddress ... } catch { return $false }`.

## [Severity: Low] DNS backup file uses .txt extension for JSON content
- **File:** DNS-Benchmark.ps1:220
- **Issue:** Backup file is named `dns-backup_*.txt` but contains JSON, misleading users browsing backups.
- **Repro:** Run with `-Restore`, inspect `%USERPROFILE%\DNS-Benchmark\` — files have `.txt` extension despite JSON payload.
- **Fix:** Change extension to `.json` in the backup filename.
