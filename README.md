# nextcloud-k3s

Deploy [Nextcloud](https://nextcloud.com/) on a [k3s](https://k3s.io/) homelab with almost no Kubernetes knowledge.

Nextcloud is your private file sync and collaboration suite (like a self-hosted Dropbox / Google Drive).

This repo follows the current [LinuxServer Nextcloud image docs](https://docs.linuxserver.io/images/docker-nextcloud/), which match what Nextcloud itself expects for a small self-hosted setup:

- Image: `lscr.io/linuxserver/nextcloud:latest` (stable releases)
- Config volume: `/config`
- Data volume: `/data`
- Web UI on **HTTPS port 443**
- `PUID` / `PGID` / `TZ` as recommended by LinuxServer

For a typical home lab, the image’s built-in **SQLite** database is fine. Move to PostgreSQL/MySQL later if you grow into a larger team.

## What you need

1. A working **k3s** cluster (`kubectl` talks to it)
2. **Longhorn** storage (or change `storageClassName` in `deploy.yaml`)
3. Enough disk for your files (default data PVC is **100Gi** — edit before install if needed)

## One-time: install Longhorn

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace

kubectl -n longhorn-system get pod
```

Longhorn creates volumes automatically from the PVCs. No manual “Create Volume” step in the UI.

## Install Nextcloud

```bash
git clone https://github.com/johnycsf/nextcloud-k3s.git
cd nextcloud-k3s

# Optional: edit deploy.yaml storage sizes / timezone first
chmod +x install.sh
./install.sh
```

Or:

```bash
kubectl apply -f deploy.yaml
kubectl -n nextcloud get svc nextcloud
```

## Open Nextcloud

```bash
kubectl -n nextcloud get svc nextcloud
```

Open `https://EXTERNAL-IP/` (or your node IP).  
The container uses a **self-signed certificate** by default — accept the browser warning.

Complete the first-run wizard and create your admin user.

### “Access through untrusted domain”

If Nextcloud shows that error, add your IP or hostname.

Easiest path for beginners — exec into the pod and edit config:

```bash
POD=$(kubectl -n nextcloud get pod -l app=nextcloud -o jsonpath='{.items[0].metadata.name}')
kubectl -n nextcloud exec -it "$POD" -- bash
```

Inside the container, edit `/config/www/nextcloud/config/config.php` and add your address to `trusted_domains`, for example:

```php
'trusted_domains' =>
array (
  0 => 'localhost',
  1 => '192.168.1.50',   // your EXTERNAL-IP or hostname
),
```

Then reload the page.

## Customize

| Setting | Where | Default |
|--------|--------|---------|
| Timezone | `TZ` | `America/New_York` |
| User/group | `PUID` / `PGID` | `1000` |
| Config disk | `nextcloud-config` PVC | `10Gi` |
| Files disk | `nextcloud-data` PVC | `100Gi` |

## Update (important)

LinuxServer upgrades Nextcloud **by pulling a new image**, not via the web updater.

You can only jump **one major version at a time**. Prefer the `previous` tag if you need a careful upgrade path — see [LinuxServer docs](https://docs.linuxserver.io/images/docker-nextcloud/).

```bash
kubectl -n nextcloud set image deployment/nextcloud \
  nextcloud=lscr.io/linuxserver/nextcloud:latest
kubectl -n nextcloud rollout status deployment/nextcloud
```

## Uninstall

```bash
kubectl delete -f deploy.yaml
```

This deletes the PVCs and your Nextcloud data.

## Notes for beginners

- Keep **one replica**. SQLite + shared Nextcloud data is not a multi-pod setup.
- For internet access, put Nextcloud behind a reverse proxy with a real TLS certificate (Caddy, Traefik, nginx).
- Collabora / OnlyOffice built into Nextcloud are **not** supported inside this LinuxServer image — run them as separate apps if you need office editing.
