# nextcloud-office-k8s

Deploy [Nextcloud](https://nextcloud.com/) on a [Kubernetes](https://kubernetes.io/) homelab with almost no Kubernetes knowledge — including **LibreOffice document editing** via [Collabora Online (CODE)](https://www.collaboraonline.com/code/).

## Why “New → Document” used to do nothing

The [LinuxServer Nextcloud image](https://docs.linuxserver.io/images/docker-nextcloud/) **cannot** run Nextcloud’s built-in Collabora/OnlyOffice packages (they need glibc). Those menu entries appear, but editing never works.

This repo fixes that the way Nextcloud documents recommend: run a **separate** `collabora/code` server and connect it with the **Nextcloud Office** (`richdocuments`) app.

References:

- [Nextcloud Office Docker example](https://docs.nextcloud.com/server/latest/admin_manual/office/example-docker.html)
- [richdocuments install notes](https://github.com/nextcloud/richdocuments/blob/main/docs/install.md)

## What gets installed

| Component | Image | Port | Role |
|-----------|--------|------|------|
| Nextcloud | `lscr.io/linuxserver/nextcloud:latest` | `443` | Files + UI |
| Collabora CODE | `collabora/code:latest` | `9980` | LibreOffice editing in the browser |

### Reliability details (the parts that usually break)

| Problem | What this repo does |
|---------|---------------------|
| Built-in Office app is broken on LinuxServer | Disables `richdocumentscode*`; uses external Collabora |
| Nextcloud cannot reach Collabora via LAN IP (hairpin NAT) | `wopi_url` uses in-cluster DNS; `public_wopi_url` uses the LoadBalancer for browsers |
| Collabora cannot reach Nextcloud via LAN IP | `hostAliases` maps your Nextcloud host/IP to the Service ClusterIP |
| Self-signed Nextcloud cert | `disable_certificate_verification` + Collabora `ssl.ssl_verification=false` |
| Slow Collabora first start | `startupProbe` with a long failure window + 3Gi memory limit |

## What you need

1. A working **Kubernetes** cluster (`kubectl` talks to it)
2. **Longhorn** storage (or change `storageClassName` in `deploy.yaml`)
3. About **3 GiB RAM free** for Collabora in addition to Nextcloud
4. A browser that can reach **both** Nextcloud `:443` and Collabora `:9980`

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
```

What the script does:

1. Applies `deploy.yaml` (Nextcloud + Collabora)
2. Waits for both Deployments (Collabora image is large — be patient)
3. Waits for you to open Nextcloud and **create the admin account**
4. Runs `configure-office.sh` (URLs, apps, hostAliases)
5. Runs `verify-office.sh` (connectivity + config smoke tests)

Then try: **+ New → Document / Spreadsheet / Presentation**.

### Verify anytime

```bash
./verify-office.sh
```

All checks should print `PASS`. If something fails:

```bash
NEXTCLOUD_HOST=192.168.1.50 COLLABORA_HOST=192.168.1.50 ./configure-office.sh
./verify-office.sh
```

## Open the apps

```bash
kubectl -n nextcloud get svc
```

- Nextcloud: `https://EXTERNAL-IP/` (self-signed cert — accept the warning)
- Collabora discovery: `http://EXTERNAL-IP:9980/hosting/discovery`  
  (your browser should show XML containing `urlsrc=`)

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
./verify-office.sh
```

Nextcloud major upgrades must happen **one version at a time** (LinuxServer pulls the new image and upgrades on start). Prefer the `previous` tag for careful upgrades — see [LinuxServer docs](https://docs.linuxserver.io/images/docker-nextcloud/).

## Uninstall

```bash
kubectl delete -f deploy.yaml
```

Deletes PVCs and your Nextcloud data.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|----------------|-----|
| New → Document spins / blank | Browser cannot reach `:9980` | Open `http://IP:9980/hosting/discovery` from your PC |
| “Unauthorized WOPI host” | Callback allow list / URL mismatch | Re-run `./configure-office.sh` |
| Collabora pod `OOMKilled` | Not enough RAM | Free memory or raise the limit in `deploy.yaml` |
| Collabora stuck not Ready | First pull/start still running | `kubectl -n nextcloud logs deploy/collabora -f` |
| Works on LAN IP only after reconfigure | IP/DNS changed | Set `NEXTCLOUD_HOST` / `COLLABORA_HOST` and re-run configure |
| Built-in Office still enabled | Old app left on | `./configure-office.sh` disables `richdocumentscode*` |

## Notes for beginners

- Keep **one replica** of Nextcloud (SQLite) and one of Collabora.
- This homelab layout serves Collabora over **HTTP :9980** and Nextcloud over **HTTPS :443** with a self-signed cert so it works without a reverse proxy. For internet exposure, put **both** behind Caddy/Traefik/nginx with real certificates and re-run `configure-office.sh` with your DNS names.
- Official Nextcloud guides prefer a dedicated hostname for Collabora (e.g. `office.example.com`); the IP + LoadBalancer approach here is intentionally simpler for first-time homelab use.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
