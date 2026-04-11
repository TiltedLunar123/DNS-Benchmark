# Contributing to DNS Benchmark & Optimizer

Thanks for your interest in contributing! Here's how to get started.

## Getting Started

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/DNS-Benchmark.git
   cd DNS-Benchmark
   ```
3. Run the benchmark (requires Administrator):
   ```powershell
   # Right-click PowerShell > "Run as Administrator"
   .\DNS-Benchmark.ps1 -SkipApply
   ```

## Development Notes

- **Single-script architecture** — All logic lives in `DNS-Benchmark.ps1`. Functions are extracted for testability but the script is self-contained.
- **No build step** — Edit the `.ps1` file and run it directly.
- **Admin required** — The script changes DNS settings via `Set-DnsClientServerAddress`, which requires elevation. Use `-SkipApply` for safe benchmarking during development.
- **PowerShell 5.1+** — Must work on the version pre-installed with Windows 10/11. Avoid PS 7-only syntax.

## Testing

Run tests before submitting a PR:

```powershell
# Install test dependencies (first time only)
Install-Module -Name Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser

# Run linter
Invoke-ScriptAnalyzer -Path ./DNS-Benchmark.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Warning,Error

# Run tests
Invoke-Pester ./tests -Output Detailed
```

When adding new functionality, add corresponding tests in the `tests/` directory. Tests use Pester 5 with AST-based function extraction so functions can be tested without running the full benchmark.

## What to Work On

Some areas where help is appreciated:

- **New DNS providers** — Adding emerging privacy-focused DNS resolvers
- **IPv6 support** — Testing and applying IPv6 DNS addresses
- **Cross-platform** — PowerShell 7 support for Linux/macOS DNS configuration
- **Concurrent testing** — Parallel DNS queries for faster benchmarking
- **Test coverage** — More edge-case tests for scoring and statistical functions

## Pull Request Guidelines

1. **Keep PRs focused** — One feature or fix per PR.
2. **Test manually** — Run the benchmark with `-SkipApply` and verify output looks correct.
3. **Follow existing style** — Match the code style you see in the project.
4. **Update the README** if your change adds or modifies user-facing behavior.
5. **Run the linter** — `Invoke-ScriptAnalyzer` should report zero issues.

## Reporting Bugs

Open an issue with:

- What you expected to happen
- What actually happened
- Steps to reproduce
- PowerShell version (`$PSVersionTable.PSVersion`)
- Windows version
- Network adapter type (Wi-Fi, Ethernet, etc.)

## Code of Conduct

Be respectful, constructive, and inclusive. We're all here to make a useful tool better.
