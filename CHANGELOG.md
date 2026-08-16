## Unreleased

- Manage menu includes **Restore** (backup root, snapshot, or archive).

- Single entrypoint: `./manage.sh` (install/update/backup helpers moved under `scripts/`).

- Native ↑/↓ `>` menus in `./manage.sh` (replaced gum/whiptail chooser).

- Optional compressed backup exports (`--archive tar.gz|tar.xz|zip`) with simple password protection; age remains available for strong crypto.

- Optional age-encrypted backup exports (`--encrypt`) for offsite disaster recovery.

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/) where tagged releases exist.

## [Unreleased]
- Open chosen host ports in firewalld during install (rootless Podman needs this for LAN access).
- Show live progress for compose pull/build (`ui_run --stream`) so long image downloads do not look frozen.
- Fix features blurb: backticks around CONTAINER_ENGINE ran it as a shell command.
- Control-center banner uses remembered Docker/Podman engine label.
- UI polish: install/doctor/uninstall banners reflect Docker vs Podman from `CONTAINER_ENGINE`.
- Remember `CONTAINER_ENGINE` from `.env` for all manage actions; preserve it (and host ports) across restore; stop hard-requiring `docker` when Podman is selected.
- Podman: prefer `podman-compose` over `podman compose`/docker-compose plugin; silence provider banner.
- Clarify that `main` stays the GitHub default; log bugs as Issues during testing.
- Document `testing` → `main` PR workflow (verify first, include CHANGELOG).
- Ensure rootless Podman API socket (`podman.socket` + linger) before `podman compose`.
- Fix `compose_engine` Docker path (was recursively calling itself instead of `docker compose`).

### Added

- Interactive `./manage.sh` control center (where applicable)
- Soft pastel terminal UI for install/manage scripts
- `DISCLAIMER.md`, `CREDITS.md`, `CONTRIBUTING.md`, Sponsors funding links
- GitHub Issue bug report template

### Changed

- Standardized beginner-friendly install, update, and backup UX

<!--
## [1.0.0] - YYYY-MM-DD
### Added
- Initial public release
-->
