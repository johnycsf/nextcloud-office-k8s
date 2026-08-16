## Unreleased

- Single entrypoint: `./manage.sh` (install/update/backup helpers moved under `scripts/`).

- Native ↑/↓ `>` menus in `./manage.sh` (replaced gum/whiptail chooser).

- Optional compressed backup exports (`--archive tar.gz|tar.xz|zip`) with simple password protection; age remains available for strong crypto.

- Optional age-encrypted backup exports (`--encrypt`) for offsite disaster recovery.

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/) where tagged releases exist.

## [Unreleased]

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
