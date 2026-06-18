# Contributing to obsigna-examples

See [AGENTS.md](./AGENTS.md) for repo conventions and architecture. This file
covers the local tooling that keeps contributions clean.

## Pre-commit hooks

This repo uses [Lefthook](https://github.com/evilmartians/lefthook) for local
hooks that mirror the CI gates, so failures surface before you push.

```bash
brew install lefthook   # or: go install github.com/evilmartians/lefthook@latest
lefthook install        # set up git hooks
```

**Pre-commit** runs [shellcheck](https://www.shellcheck.net/) on staged `*.sh`
files (install with `brew install shellcheck`). CI runs it on every shell script
regardless.

## Commit messages

This project follows [Conventional Commits](https://www.conventionalcommits.org/).
Every commit message must start with a type:

```
feat: add new feature
fix: correct a bug
docs: update documentation
chore: maintenance task
refactor: restructure without behavior change
test: add or update tests
ci: change CI/CD configuration
```

The `commit-msg` hook enforces this locally via [convco](https://convco.github.io/check/)
on each commit you write. This repo **squash-merges**, so the **PR title** is
what becomes the commit on `main` — the **CI: conventional commits** workflow
lints that title on every PR. Keep your PR title conventional (e.g.
`feat: add foo example`), even if it can't reach `main` without the local hook
installed.

Install convco:

```bash
brew install convco          # macOS
cargo install convco         # Linux / Windows / any platform with Rust
```

See the [convco installation docs](https://convco.github.io/check/installation/)
for all options.
