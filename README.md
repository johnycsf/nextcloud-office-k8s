# nextcloud-office-k8s

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Issues](https://img.shields.io/badge/issues-welcome-lightgrey.svg)](../../issues/new/choose)

![`./manage.sh` control center](docs/manage-demo.gif)

**Nextcloud + Collabora Office on Kubernetes** — official images, guided storage/replicas, safe updates & backups.

Uses the **official** [`nextcloud`](https://hub.docker.com/_/nextcloud) and [`mariadb:latest`](https://hub.docker.com/_/mariadb) images, plus Collabora’s official [`collabora/code`](https://hub.docker.com/r/collabora/code).

Docker Compose version (no Kubernetes needed): [nextcloud-office-docker](https://github.com/johnycsf/nextcloud-office-docker)

> **Updating an older clone?** Pulling git is safe. Re-running `./manage.sh` against SQLite or LinuxServer installs is not an in-place migration. Read [BREAKING-CHANGES.md](BREAKING-CHANGES.md).

## Install

```bash
git clone https://github.com/johnycsf/nextcloud-office-k8s.git
cd nextcloud-office-k8s
chmod +x manage.sh
./manage.sh
```

You need a Kubernetes cluster (`kubectl` context already set), `sudo` on this machine so `./manage.sh` can install missing tools, and disk for PersistentVolumes.

`./manage.sh` asks for **StorageClass** and **replica count** (re-run anytime to change). Non-interactive: `STORAGE_CLASS=longhorn REPLICAS=1 ./manage.sh`. Optional Redis: `./manage.sh install --include-redis`.

After install, open Nextcloud, create the admin account, then try **+ New → Document**. If Office fails, `./scripts/configure-office.sh` needs the address **your browser uses** (LAN IP or hostname — not a ClusterIP).

### Storage

Default PVCs in `deploy.yaml`: Nextcloud files `100Gi`, MariaDB `20Gi`. One-time Longhorn (if that is your StorageClass):

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace
```

## Update

```bash
./manage.sh update
```

Before changing anything, the script runs `./manage.sh backup` into `./backups` (incremental, database-safe). After a successful update it asks whether to **keep** or **delete** that snapshot, and how many local copies to retain. Copy important backups to an external drive, NAS, or cloud so they do not fill this disk.

To roll back later:

```bash
./manage.sh backup --restore --from ./backups
```

This re-applies manifests, rolls Deployments so `:latest` images refresh, and prunes **unused** images when possible. PVCs and Secrets are left untouched.

Nextcloud major upgrades: **one major version at a time**. SQLite / LinuxServer installs: see [BREAKING-CHANGES.md](BREAKING-CHANGES.md).

## Backup / restore

Incremental snapshots via `rsync` hardlinks (unchanged files are not re-copied). `./manage.sh update` uses this same backup before updating.

```bash
./manage.sh backup --dest /mnt/usb/nextcloud-office-k8s-backups
./manage.sh backup --restore --from /mnt/usb/nextcloud-office-k8s-backups
```

Each snapshot includes `SHA256SUMS` plus a `snapshot_sha256` key in `META.txt`. Keep the backup root on **one filesystem** so hardlinks work.

**Database safety:** Nextcloud uses a verified MariaDB *logical* dump (`mariadb-dump --single-transaction`) — the live DB PVC files are never rsync’d.

## Credits

This repo packages or configures upstream software. See [CREDITS.md](CREDITS.md) for the main developers and projects this work builds on.

## Disclaimer

This project is provided **as is**. The author is **not responsible** for any loss, damage, data corruption, downtime, security issues, or other consequences from using it. Full text: [DISCLAIMER.md](DISCLAIMER.md).

If this helped, star the repo or [sponsor johnycsf](https://github.com/sponsors/johnycsf).
