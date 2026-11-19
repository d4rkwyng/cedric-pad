# Owl clean corpus: sources and licences

Real, working files that Cedric's language rules must give **no** hints on
(`OwlLanguageRulesTests.cleanCorpusGetsNoLanguageHints`). Copied unchanged
unless noted. No GPL files.

| Files | Source | Licence |
|---|---|---|
| `shell/brew-*.sh`, `yaml/brew-*.yml`, `toml/brew-formula-analytics-pyproject.toml` | Homebrew/brew (`Library/Homebrew/utils/lock.sh`, `utils/git.sh`, `cmd/shellenv.sh`, `cmd/exec.sh`; `.github/workflows/{actionlint,docs,check-issues}.yml`, `.github/dependabot.yml`; `Library/Homebrew/formula-analytics/pyproject.toml`) | BSD-2-Clause, © Homebrew contributors |
| `python/textwrap.py`, `python/shlex.py` | CPython 3.9 standard library | PSF License |
| `js/async-lock.js`, `json/async-lock-package.json` | async-lock (npm) `lib/index.js`, `package.json` | MIT |
| `js/is-typed-array.js`, `js/is-typed-array.d.ts`, `json/is-typed-array-package.json` | is-typed-array (npm) | MIT |
| `shell/owlink-test.sh`, `xml/OwlInk-Info.plist` (from `Scripts/bundle-app.sh`, version filled in), `xml/owl.svg`, `toml/owlink-sample.toml`, `env/*` | OwlInk itself | BSD-2-Clause (this repository) |
| `markdown/brew-FAQ.md` | Homebrew/brew `docs/FAQ.md` | BSD-2-Clause, © Homebrew contributors |
| `markdown/markdownlint-README.md` | DavidAnson/markdownlint `README.md` | MIT, © David Anson |
| `csv/matplotlib-msft.csv` | matplotlib `mpl-data/sample_data/msft.csv` | Matplotlib License (PSF-based) |
| `csv/regexp_parser-short.csv` | regexp_parser (Ruby gem) `lib/regexp_parser/scanner/properties/short.csv` | MIT, © Ammar Ali |
| `csv/owlink-sample.tsv`, `csv/owlink-excel.csv` | OwlInk itself | BSD-2-Clause (this repository) |
| `sql/sakila-mysql-schema.sql`, `sql/sakila-postgres-schema.sql` | jOOQ/sakila (`mysql-sakila-db/mysql-sakila-schema.sql`, `postgres-sakila-db/postgres-sakila-schema.sql`) | BSD (Sakila © 2006 MySQL AB; the jOOQ/sakila port BSD-2-Clause, © 2021 jOOQ) |
| `powershell/install-powershell.ps1` | PowerShell/PowerShell `tools/install-powershell.ps1` | MIT, © Microsoft Corporation |
| `powershell/dotnet-install.ps1` | dotnet/install-scripts `src/dotnet-install.ps1` | MIT, © .NET Foundation and contributors |

Markdown fixtures are checked without a file probe: their relative links
point into their own repositories (the large run checks links in place).
