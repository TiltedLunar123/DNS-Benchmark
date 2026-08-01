# Contributing

Fork it, clone your fork, and run the benchmark with `-SkipApply` so you are not
rewriting your own DNS settings every time you test a change:

```powershell
.\DNS-Benchmark.ps1 -SkipApply
```

You need an elevated PowerShell for the parts that actually apply settings, but
`-SkipApply` covers most development.

## Things worth knowing before you edit

Everything lives in `DNS-Benchmark.ps1`. There is no build step and no module layout;
functions are broken out so the tests can get at them, but the script is meant to stay
one file you can read top to bottom.

It has to run on PowerShell 5.1, which is what ships with Windows 10 and 11. PS7-only
syntax will pass on your machine and fail for most people who run this.

If you change `DNS-Benchmark.ps1`, regenerate the checksum or both `install.ps1` and the
test suite will reject the file:

```powershell
$c = [System.IO.File]::ReadAllText("DNS-Benchmark.ps1") -replace "`r`n","`n" -replace "`r","`n"
$h = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($c))).Replace("-","").ToLower()
Set-Content checksums.txt "$h  DNS-Benchmark.ps1" -NoNewline -Encoding utf8
```

That trips people up, including me, more than anything else in the repo.

## Tests

```powershell
Install-Module -Name Pester -MinimumVersion 5.0 -Force -Scope CurrentUser
Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser

Invoke-ScriptAnalyzer -Path ./DNS-Benchmark.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Warning,Error
Invoke-Pester ./tests -Output Detailed
```

The linter should come back clean. Tests use Pester 5 and pull functions out via the AST,
so they can exercise the scoring and statistics without running a real benchmark. New
behaviour wants a test alongside it.

## Pull requests

One thing per PR, please. Run the linter and the tests, update the README if you changed
something a user would notice, and match the style already in the file rather than
introducing a new one.

## Bugs

Open an issue and include what you expected, what happened instead, and how to
reproduce it. For anything involving results being wrong or the apply step misbehaving,
also include your PowerShell version (`$PSVersionTable.PSVersion`), your Windows
version, and whether you are on Wi-Fi or Ethernet. DNS behaviour varies more by adapter
and network than you would think, and without that I usually cannot reproduce it.
