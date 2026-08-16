# Contributing

Thanks for wanting to help. These projects are meant to stay simple for homelab beginners.

## Disclaimer

See [DISCLAIMER.md](DISCLAIMER.md). By using or contributing to this repository, you acknowledge that the author is **not responsible** for any damage, data loss, outages, security issues, or other consequences from using this software.


### Credits

If your change adds a new upstream app, library, or CLI tool (for example age, rsync, or a new container image), update [CREDITS.md](CREDITS.md) in the same pull request. If you **remove** a tool, remove its credit in the same PR.

## Reporting bugs

If you encounter an error or unexpected behavior, please use GitHub (that is the supported contribution path):

1. Search [existing Issues](../../issues) for a duplicate.
2. Open a **new Issue** and include:
   - What you were trying to do
   - Exact commands you ran
   - Full error output
   - OS and relevant tool versions (for example Docker / Compose, kubectl / Helm, or shell / Starship when applicable)
   - Whether you used `./manage.sh`, `./manage.sh`, or manual steps
3. Optionally open a **Pull Request** with a fix (see below).

Do not expect private email or DM troubleshooting. Bug reports and fixes belong on GitHub Issues and Pull Requests.

## Maintainer branch workflow

- **`main`** — stable **GitHub default** branch (what `git clone` checks out for users). **Never** set `testing` as the repository default — it may contain untested changes.
- **`testing`** — integration branch for maintainers only. Verify here before merging to `main`.

1. Develop on `testing` (or merge feature branches into `testing`).
2. When you find a bug, **open a GitHub Issue** first (or as soon as you have a clear repro) — even if you already know the fix. Search for duplicates; include commands, errors, OS, and Docker vs Podman.
3. Fix on `testing`, reference the issue in the commit message / CHANGELOG (for example `Fixes #12`).
4. Test on a real machine until confident.
5. Update **CHANGELOG.md** in the same change set.
6. Open a **Pull Request**: `testing` → `main` (changelog + verification note + linked issues).
7. Merge only after the PR looks good; close linked issues when the fix is verified (on `testing` or after merge to `main`).

External contributors can still open PRs from a fork/feature branch; maintainers may land those on `testing` first when the change needs live verification.


## How to contribute (Pull Requests)

1. Fork the repository
2. Create a branch for your change
3. Make the smallest change that solves the problem
4. Test on a real machine when changing install or deploy scripts
5. Open a Pull Request that explains what broke, what you changed, and how you verified it

## Guidelines

- Prefer clarity over cleverness
- Keep one-command installs working (`./manage.sh` / `./manage.sh` where present)
- Do not commit secrets, tokens, or personal hostnames/IPs
- Match existing file style
