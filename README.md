# nextcloud-office-k8s

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/bbf1d0685d6a0387a3d1479b5c486c911d26b7a6.svg "Repobeats analytics image")

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

## What you need

1. A working **Kubernetes** cluster (`kubectl` talks to it)
2. **Longhorn** storage (or change `storageClassName` in `deploy.yaml`)
3. About **3 GiB RAM free** for Collabora in addition to Nextcloud + MariaDB
4. A browser that can reach **both** Nextcloud `:80` and Collabora `:9980`

## One-time: install Longhorn

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace

kubectl -n longhorn-system get pod
```

## Install Nextcloud + Office

```bash
git clone https://github.com/johnycsf/nextcloud-office-k8s.git
cd nextcloud-office-k8s
chmod +x install.sh configure-office.sh verify-office.sh
./install.sh
# optional Redis (official caching / file locking):
# ./install.sh --include-redis
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

Before changing anything, the script writes a timestamped rollback copy under `backups/`. After a successful update it asks whether to **keep** or **delete** that snapshot, and how many local copies to retain (older ones are pruned). Copy important backups to an external drive, NAS, or cloud so they do not fill this disk.

To roll back later:

```bash
chmod +x restore.sh
./restore.sh
# or from an external copy of the backups folder:
./restore.sh --external /path/to/backups
```

This re-applies manifests, rolls Deployments so `:latest` images refresh, and prunes **unused** images on this machine when possible (k3s `crictl rmi --prune` or Docker dangling prune). PVCs and Secrets are left untouched.

Afterward you can run `./verify-office.sh`. Re-run `./configure-office.sh` only if your LAN IP/hostname changed.

Nextcloud major upgrades: **one major version at a time**.

SQLite / LinuxServer installs: see [BREAKING-CHANGES.md](BREAKING-CHANGES.md).

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


## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
