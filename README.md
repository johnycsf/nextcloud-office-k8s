# nextcloud-office-k8s

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/bbf1d0685d6a0387a3d1479b5c486c911d26b7a6.svg "Repobeats analytics image")

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Issues](https://img.shields.io/badge/issues-welcome-lightgrey.svg)](../../issues/new/choose)

Deploy [Nextcloud](https://nextcloud.com/) on a [Kubernetes](https://kubernetes.io/) homelab with almost no Kubernetes knowledge — including **LibreOffice document editing** via [Collabora Online (CODE)](https://www.collaboraonline.com/code/) and **MariaDB** (not SQLite).

Uses the **official** [`nextcloud`](https://hub.docker.com/_/nextcloud) and [`mariadb:lts`](https://hub.docker.com/_/mariadb) images.

> **Updating an older clone?** Pulling git is safe. Re-running `./install.sh` against SQLite or LinuxServer installs is not an in-place migration. Read [BREAKING-CHANGES.md](BREAKING-CHANGES.md).

Docker Compose version (no Kubernetes needed): [nextcloud-office-docker](https://github.com/johnycsf/nextcloud-office-docker)

## Why MariaDB

Nextcloud treats SQLite as testing/minimal only. [MariaDB and PostgreSQL are recommended](https://docs.nextcloud.com/server/latest/admin_manual/configuration_database/linux_database_configuration.html). This stack mirrors the [official Nextcloud Docker Compose MariaDB pattern](https://github.com/nextcloud/docker#running-this-image-with-docker-compose):

- `mariadb:lts`
- `--transaction-isolation=READ-COMMITTED` (required)
- `--binlog-format=ROW` and `utf8mb4` / `utf8mb4_bin`
- Nextcloud `MYSQL_HOST=db` + credentials from Secret `nextcloud-db`

## Why Office editing needs Collabora

In many Nextcloud setups, **+ New → Document / Spreadsheet / Presentation** appears in the UI but never actually opens a working editor. This repo follows [Nextcloud’s recommended approach](https://docs.nextcloud.com/server/latest/admin_manual/office/example-docker.html): run a **separate** Collabora Online server and connect it with the **Nextcloud Office** app.

References:

- [Nextcloud Office Docker example](https://docs.nextcloud.com/server/latest/admin_manual/office/example-docker.html)
- [richdocuments install notes](https://github.com/nextcloud/richdocuments/blob/main/docs/install.md)
- [Database configuration](https://docs.nextcloud.com/server/latest/admin_manual/configuration_database/linux_database_configuration.html)

## What gets installed

| Component | Image | Port | Role |
|-----------|--------|------|------|
| MariaDB | `mariadb:lts` (official) | `3306` (ClusterIP) | Nextcloud database |
| Redis (optional) | `redis:alpine` (official) | `6379` (ClusterIP) | Cache / file locking (`./install.sh --include-redis`) |
| Nextcloud | `nextcloud:latest` (official Docker Hub) | `80` | Files + UI (HTTP) |
| Collabora Online | `collabora/code:latest` (official Collabora CODE) | `9980` | LibreOffice editing in the browser |

### Reliability details (the parts that usually break)

| Problem | What this repo does |
|---------|---------------------|
| SQLite not suitable beyond tiny installs | Uses MariaDB with official auto-config env vars |
| Built-in in-container Office editor does not work | Disables it; uses external Collabora instead |
| Nextcloud cannot reach Collabora via LAN IP (hairpin NAT) | `wopi_url` uses in-cluster DNS; `public_wopi_url` uses the LoadBalancer for browsers |
| Collabora cannot reach Nextcloud via LAN IP | `hostAliases` maps your Nextcloud host/IP to the Service ClusterIP |
| Slow Collabora first start | Longer startup probe + higher memory limit |

**Nextcloud + Collabora on Kubernetes** — official images, guided storage/replicas, safe updates & backups.

> **Choose your path:** [Docker Compose](https://github.com/johnycsf/nextcloud-office-docker) · **Kubernetes (this repo)**

## Who this is for

**Good fit:** homelab Kubernetes users who want Nextcloud Office without assembling charts by hand.

**Not for:** huge multi-tenant Nextcloud farms — start with the suggested replica count and scale carefully.

## Why this repo (not just another manifest dump)

- **`./manage.sh`** control center — install, update, backup, status/doctor, uninstall
- Interactive colored install with step progress
- Auto-detects your OS and installs missing host tools (`kubectl`, `helm`, …)
- Choose **StorageClass** and **replica count** (re-run anytime to change)
- Safe **`./update.sh`** with automatic pre-update backup
- Incremental hardlink **`./backup.sh`** + restore
- **Official upstream images only**

## Support this work

If this stack saved you setup time, please consider sponsoring — it funds:

- Keeping install/update/backup scripts working across common Linux distros
- Testing safe upgrades against **official** upstream images
- Building more beginner-friendly stacks that share the same `./manage.sh` UX

[![Sponsor johnycsf](https://img.shields.io/badge/GitHub%20Sponsors-Donate-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)

👉 **[github.com/sponsors/johnycsf](https://github.com/sponsors/johnycsf)**

## What you need

- A Kubernetes cluster (`kubectl` context already set)
- `sudo` on this machine so `./install.sh` can install missing tools (kubectl, helm, curl, openssl, rsync, …)
- Disk for PersistentVolumes

`./install.sh` is interactive (colors + step progress). It asks for **StorageClass** and **replica count** (with a safe per-app suggestion). Re-run it later to change those choices. Non-interactive: `STORAGE_CLASS=longhorn REPLICAS=1 ./install.sh`.

## One-time: install Longhorn

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace

kubectl -n longhorn-system get pod
```

## Interactive control center

`./manage.sh` opens an **arrow-key menu** (↑↓ + Enter) powered by [gum](https://github.com/charmbracelet/gum). If gum isn’t installed yet, the script installs it automatically (or falls back to whiptail / a numbered list).

## Install Nextcloud + Office

```bash
git clone https://github.com/johnycsf/nextcloud-office-k8s.git
cd nextcloud-office-k8s
chmod +x manage.sh install.sh configure-office.sh verify-office.sh
./manage.sh          # interactive control center
# or: ./install.sh
# optional Redis: ./install.sh --include-redis
```

What the script does:

1. Creates Secret `nextcloud-db` (generated MariaDB passwords) if missing
2. Applies `deploy.yaml` (MariaDB + Nextcloud + Collabora)
3. Optionally applies `deploy-redis.yaml` when you pass `--include-redis`
4. Waits for Deployments (Collabora image is large — be patient)
5. Waits for you to open Nextcloud and **create the admin account** (DB already configured)
6. Runs `configure-office.sh` (URLs, apps, hostAliases)
7. Runs `verify-office.sh` (DB type + Office connectivity)

Then try: **+ New → Document / Spreadsheet / Presentation**.

### Optional Redis

```bash
./install.sh --include-redis
```

Deploys official `redis:alpine` and sets `REDIS_HOST=redis` on Nextcloud ([caching docs](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/caching_configuration.html)). Skip the flag for a smaller stack.

Fresh install only — do **not** reuse a previous SQLite PVC with this MariaDB setup.

### Verify anytime

```bash
./verify-office.sh
```

All checks should print `PASS` (including `dbtype=mysql`).

### If Office fails — set your real LAN address

`configure-office.sh` needs the address **your browser uses** to open Nextcloud and Collabora. That is usually your home-network / LAN IP (or hostname), **not** a Kubernetes ClusterIP / pod IP.

```bash
# Example only — substitute YOUR address from EXTERNAL-IP / your router
NEXTCLOUD_HOST=192.168.1.50 COLLABORA_HOST=192.168.1.50 ./configure-office.sh
./verify-office.sh
```

Do **not** use values like `10.43.x.x` / `10.42.x.x` ClusterIPs here — those are internal to the cluster and your browser cannot reach them for Office editing.

Liked the install? Star the repo or [sponsor johnycsf](https://github.com/sponsors/johnycsf) so more stacks stay maintained.


## Open the apps

```bash
kubectl -n nextcloud get svc
```

- Nextcloud: `http://EXTERNAL-IP/`
- Collabora discovery: `http://EXTERNAL-IP:9980/hosting/discovery`  
  (your browser should show XML containing `urlsrc=`)
- MariaDB stays ClusterIP-only (`db:3306`) — not exposed to the LAN

## Customize

| Setting | Where | Default |
|--------|--------|---------|
| Timezone | Nextcloud `TZ` in `deploy.yaml` | `America/New_York` |
| App + files disk | `nextcloud-html` PVC (`/var/www/html`) | `100Gi` |
| Database disk | `nextcloud-db` PVC (`/var/lib/mysql`) | `20Gi` |
| DB passwords | Secret `nextcloud-db` | generated by `install.sh` |
| Office dictionaries | Collabora `dictionaries` | `en_US` |

## Update

Keep the stack current (safe while pods are running; brief rollout downtime):

```bash
chmod +x update.sh
./update.sh
```

Before changing anything, the script runs `./backup.sh` into `./backups` (incremental, database-safe). After a successful update it asks whether to **keep** or **delete** that snapshot, and how many local copies to retain (older ones are pruned). Copy important backups to an external drive, NAS, or cloud so they do not fill this disk.

To roll back later (same tool as disaster recovery):

```bash
./backup.sh --restore --from ./backups
# or from an external copy:
./backup.sh --restore --from /mnt/usb/my-backups
```

Older `backups/update-*` tarball folders (from previous script versions) are no longer used by `./update.sh`; use each folder's `RESTORE.txt` if you still need one, or delete them to free space.

This re-applies manifests, rolls Deployments so `:latest` images refresh, and prunes **unused** images on this machine when possible (k3s `crictl rmi --prune` or Docker dangling prune). PVCs and Secrets are left untouched.

Afterward you can run `./verify-office.sh`. Re-run `./configure-office.sh` only if your LAN IP/hostname changed.

Nextcloud major upgrades: **one major version at a time**.

SQLite / LinuxServer installs: see [BREAKING-CHANGES.md](BREAKING-CHANGES.md).

## Disaster recovery (full backup / restore)

Incremental snapshots via `rsync` hardlinks (unchanged files are not re-copied). `./update.sh` uses this same `backup.sh` before updating (into `./backups`).

```bash
chmod +x backup.sh

# Backup to USB/NAS/external path (repeat anytime; later runs are incremental)
./backup.sh --dest /mnt/usb/nextcloud-office-k8s-backups
./backup.sh --dest /mnt/usb/nextcloud-office-k8s-backups --keep 5   # optional: retain only newest N

# On a brand-new machine/cluster after ./install.sh:
./backup.sh --restore --from /mnt/usb/nextcloud-office-k8s-backups
# or a specific snapshot:
./backup.sh --restore --from /mnt/usb/nextcloud-office-k8s-backups/snapshots/YYYYMMDD-HHMMSS
```

Each snapshot includes `SHA256SUMS` plus a `snapshot_sha256` key in `META.txt`. Restore verifies these and **warns** (does not abort) if integrity is lost.

Keep the backup root on **one filesystem** so hardlinks work. Prefer an external drive, NAS, or cloud sync of that folder.

**Database safety:** Nextcloud uses a verified MariaDB *logical* dump (`mariadb-dump --single-transaction`) — the live `data/db` / DB PVC files are never rsync'd. SQLite apps (Heimdall, Vaultwarden) are stopped or scaled to 0, WAL-checkpointed when `sqlite3` is available, integrity-checked, then copied. Incremental hardlinks apply to file trees; each SQL dump is a full verified file with a SHA-256 in `META.txt`.

For Nextcloud, restore also imports MariaDB, runs `occ` repair helpers, and `files:scan --all` with a live **percentage progress bar** (can still take a long time on large libraries), then re-applies Office/trusted-domain settings when possible.

## Uninstall

```bash
kubectl delete -f deploy.yaml
kubectl -n nextcloud delete secret nextcloud-db --ignore-not-found
```

Deletes PVCs and your Nextcloud + MariaDB data.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|----------------|-----|
| New → Document spins / blank | Browser cannot reach `:9980` | Open `http://IP:9980/hosting/discovery` from your PC |
| “Unauthorized WOPI host” | Callback allow list / URL mismatch | Re-run `./configure-office.sh` |
| Collabora pod `OOMKilled` | Not enough RAM | Free memory or raise the limit in `deploy.yaml` |
| `dbtype` is `sqlite` | Old SQLite install on the HTML PVC | Delete PVCs / reinstall so `MYSQL_*` applies on first boot |
| MariaDB not Ready | First init still running | `kubectl -n nextcloud logs deploy/db -f` |

## Notes for beginners

- Keep **one replica** of Nextcloud, MariaDB, and Collabora.
- This homelab layout serves Nextcloud over **HTTP :80** and Collabora over **HTTP :9980** so it works without a reverse proxy. For internet exposure, put **both** behind Caddy/Traefik/nginx with real HTTPS certificates and re-run `configure-office.sh` with your DNS names.
- Official Nextcloud guides prefer a dedicated hostname for Collabora (e.g. `office.example.com`); the IP + LoadBalancer approach here is intentionally simpler for first-time homelab use.

## Credits

This repo packages or configures upstream software. See [CREDITS.md](CREDITS.md) for the main developers and projects this work builds on.

## Disclaimer

This project is provided **as is**. The author is **not responsible** for any loss, damage, data corruption, downtime, security issues, or other consequences from using it. Full text: [DISCLAIMER.md](DISCLAIMER.md).

## Bug reports & contributions

If you hit an error, please [open a GitHub Issue](../../issues/new/choose) and follow [CONTRIBUTING.md](CONTRIBUTING.md). Fixes via Pull Request are welcome. GitHub Issues/PRs are the supported way to report problems—there is no private support channel.

## Encrypted backups

Local snapshots stay as incremental hardlink trees (fast rollback). For offsite/USB/NAS confidentiality, create an **age**-encrypted export (`./backup.sh --dest ./backups --encrypt`). SHA256 checksums cover integrity; age covers confidentiality. See upstream docs in repo-framework `docs/BACKUP_ENCRYPTION.md`.

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.
