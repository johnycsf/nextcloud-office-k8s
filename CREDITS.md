# Credits

This repository packages and automates deployment. Credit for the applications belongs to their upstream developers.

## Nextcloud + Office stack

- **Nextcloud** — [Nextcloud GmbH](https://nextcloud.com/) and contributors ([nextcloud/server](https://github.com/nextcloud/server)); image [`nextcloud`](https://hub.docker.com/_/nextcloud)
- **Collabora Online Development Edition (CODE)** — [Collabora Productivity](https://www.collaboraonline.com/); image [`collabora/code`](https://hub.docker.com/r/collabora/code) ([CollaboraOnline/online](https://github.com/CollaboraOnline/online))
- **MariaDB** — [MariaDB Foundation](https://mariadb.org/) / contributors; image [`mariadb`](https://hub.docker.com/_/mariadb)
- Optional **Redis** — [Redis Ltd.](https://redis.io/) / Redis project (when enabled in this stack)
- **Kubernetes** — [kubernetes/kubernetes](https://github.com/kubernetes/kubernetes)

## Shared johnycsf tooling

These install/manage/backup helpers are used across johnycsf stacks. Credit the upstream projects:

| Tool | Role in this repo | Upstream |
|------|-------------------|----------|
| **age** | Optional encrypted offsite backup exports (`./backup.sh --encrypt` / password-protected tar archives) | [FiloSottile/age](https://github.com/FiloSottile/age) |
| **zip** / **unzip** | Optional compressed zip exports (`./backup.sh --archive zip`) | [Info-ZIP](http://www.info-zip.org/) |
| **xz** | Optional tar.xz compressed exports | OS `xz` / xz-utils package |
| **rsync** | Incremental hardlink snapshot backups | [rsync.samba.org](https://rsync.samba.org/) / your OS package |
| **Docker** / **Docker Compose** | Container runtime for app stacks | [docker.com](https://www.docker.com/) |
| **Catppuccin** | Color inspiration for the pastel terminal UI | [catppuccin/catppuccin](https://github.com/catppuccin/catppuccin) |

When you add a new helper tool or feature dependency, **add it here** (and in `repo-framework`’s template) in the same PR.

All trademarks and project names belong to their respective owners. This repo is not affiliated with or endorsed by Nextcloud, Collabora, MariaDB, or the Kubernetes project.
