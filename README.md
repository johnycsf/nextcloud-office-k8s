# nextcloud-k3s

Deploy [Nextcloud](https://nextcloud.com/) on a [k3s](https://k3s.io/) homelab with almost no Kubernetes knowledge — including **LibreOffice document editing** via [Collabora Online (CODE)](https://www.collaboraonline.com/code/).

## Why “New → Document” used to do nothing

The [LinuxServer Nextcloud image](https://docs.linuxserver.io/images/docker-nextcloud/) **cannot** run Nextcloud’s built-in Collabora/OnlyOffice packages (they need glibc). Those menu entries appear, but editing never works.

This repo fixes that the way Nextcloud documents recommend: run a **separate** `collabora/code` server and connect it with the **Nextcloud Office** (`richdocuments`) app.

See:

- [Nextcloud Office Docker example](https://docs.nextcloud.com/server/latest/admin_manual/office/example-docker.html)
- [richdocuments install notes](https://github.com/nextcloud/richdocuments/blob/main/docs/install.md)

## What gets installed

| Component | Image | Port | Role |
|-----------|--------|------|------|
| Nextcloud | `lscr.io/linuxserver/nextcloud:latest` | `443` | Files + UI |
| Collabora CODE | `collabora/code:latest` | `9980` | LibreOffice editing in the browser |

Storage uses **Longhorn** PVCs (`/config` + `/data`). SQLite is fine for a typical home lab.

## What you need

1. A working **k3s** cluster (`kubectl` talks to it)
2. **Longhorn** storage (or change `storageClassName` in `deploy.yaml`)
3. About **2–3 GiB RAM free** for Collabora in addition to Nextcloud
4. A browser that can reach **both** the Nextcloud and Collabora LoadBalancer IPs/ports

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
git clone https://github.com/johnycsf/nextcloud-k3s.git
cd nextcloud-k3s
chmod +x install.sh configure-office.sh
./install.sh
```

What the script does:

1. Applies `deploy.yaml` (Nextcloud + Collabora)
2. Waits for both Deployments
3. Asks you (by waiting) to open Nextcloud and **create the admin account**
4. Runs `configure-office.sh` to:
   - allow your Nextcloud host in Collabora (`aliasgroup1` / `domain`)
   - install/enable `richdocuments`
   - set `wopi_url` to Collabora
   - disable the broken built-in CODE apps if present
   - allow local/LAN WOPI callbacks (homelab-friendly)

Then try: **+ New → Document / Spreadsheet / Presentation**.

### Re-run Office wiring later

If your IP/DNS changes, or Office stopped working:

```bash
NEXTCLOUD_HOST=192.168.1.50 COLLABORA_HOST=192.168.1.50 ./configure-office.sh
```

## Open the apps

```bash
kubectl -n nextcloud get svc
```

- Nextcloud: `https://EXTERNAL-IP/` (self-signed cert — accept the warning)
- Collabora discovery (for debugging): `http://EXTERNAL-IP:9980/hosting/discovery`

## Customize

| Setting | Where | Default |
|--------|--------|---------|
| Timezone | Nextcloud `TZ` | `America/New_York` |
| User/group | `PUID` / `PGID` | `1000` |
| Config disk | `nextcloud-config` PVC | `10Gi` |
| Files disk | `nextcloud-data` PVC | `100Gi` |
| Office dictionaries | Collabora `dictionaries` | `en_US` |

## Update

```bash
kubectl -n nextcloud set image deployment/nextcloud \
  nextcloud=lscr.io/linuxserver/nextcloud:latest
kubectl -n nextcloud set image deployment/collabora \
  collabora=collabora/code:latest
kubectl -n nextcloud rollout status deployment/nextcloud
kubectl -n nextcloud rollout status deployment/collabora
./configure-office.sh
```

Nextcloud major upgrades must happen **one version at a time** (LinuxServer pulls the new image and upgrades on start). Prefer the `previous` tag for careful upgrades — see [LinuxServer docs](https://docs.linuxserver.io/images/docker-nextcloud/).

## Uninstall

```bash
kubectl delete -f deploy.yaml
```

Deletes PVCs and your Nextcloud data.

## Notes for beginners

- Keep **one replica** of Nextcloud (SQLite) and one of Collabora.
- Collabora needs more RAM than Nextcloud; if the Collabora pod is `OOMKilled`, lower other workloads or raise the memory limit in `deploy.yaml`.
- This homelab layout serves Collabora over **HTTP :9980** and Nextcloud over **HTTPS :443** with a self-signed cert so it works without a reverse proxy. For internet exposure, put **both** behind Caddy/Traefik/nginx with real certificates and re-run `configure-office.sh` with your DNS names.
- Official Nextcloud guides prefer a dedicated hostname for Collabora (e.g. `office.example.com`); the IP + LoadBalancer approach here is intentionally simpler for first-time homelab use.
