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
