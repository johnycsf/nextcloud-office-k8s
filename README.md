# nextcloud-office-k8s

Deploy [Nextcloud](https://nextcloud.com/) on a [Kubernetes](https://kubernetes.io/) homelab with almost no Kubernetes knowledge — including **LibreOffice document editing** via [Collabora Online (CODE)](https://www.collaboraonline.com/code/).

Uses the **official** [`nextcloud`](https://hub.docker.com/_/nextcloud) image.

Docker Compose version (no Kubernetes needed): [nextcloud-office-docker](https://github.com/johnycsf/nextcloud-office-docker)

## Why Office editing needs Collabora

In many Nextcloud setups, **+ New → Document / Spreadsheet / Presentation** appears in the UI but never actually opens a working editor. This repo follows [Nextcloud’s recommended approach](https://docs.nextcloud.com/server/latest/admin_manual/office/example-docker.html): run a **separate** Collabora Online server and connect it with the **Nextcloud Office** app.

References:

- [Nextcloud Office Docker example](https://docs.nextcloud.com/server/latest/admin_manual/office/example-docker.html)
- [richdocuments install notes](https://github.com/nextcloud/richdocuments/blob/main/docs/install.md)

## What gets installed

| Component | Image | Port | Role |
|-----------|--------|------|------|
| Nextcloud | `nextcloud:latest` (official Docker Hub) | `80` | Files + UI (HTTP) |
| Collabora Online | `collabora/code:latest` (official Collabora CODE) | `9980` | LibreOffice editing in the browser |

### Reliability details (the parts that usually break)

| Problem | What this repo does |
|---------|---------------------|
| Built-in in-container Office editor does not work | Disables it; uses external Collabora instead |
| Nextcloud cannot reach Collabora via LAN IP (hairpin NAT) | `wopi_url` uses in-cluster DNS; `public_wopi_url` uses the LoadBalancer for browsers |
| Collabora cannot reach Nextcloud via LAN IP | `hostAliases` maps your Nextcloud host/IP to the Service ClusterIP |
| Slow Collabora first start | Longer startup probe + higher memory limit |

## What you need

1. A working **Kubernetes** cluster (`kubectl` talks to it)
2. **Longhorn** storage (or change `storageClassName` in `deploy.yaml`)
3. About **3 GiB RAM free** for Collabora in addition to Nextcloud
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

All checks should print `PASS`.

### If Office fails — set your real LAN address

`configure-office.sh` needs the address **your browser uses** to open Nextcloud and Collabora. That is usually your home-network / LAN IP (or hostname), **not** a Kubernetes ClusterIP / pod IP.

`192.168.1.50` below is only an **example**. Replace it with whatever you actually open in the browser.

Find it with:

```bash
kubectl -n nextcloud get svc
```

Use the `EXTERNAL-IP` column (on k3s that is often your node’s LAN IP). On many homelabs Nextcloud and Collabora share the same host IP and only differ by port (`80` vs `9980`), so both variables are often identical:

```bash
# Example only — substitute YOUR address from EXTERNAL-IP / your router
NEXTCLOUD_HOST=192.168.1.50 COLLABORA_HOST=192.168.1.50 ./configure-office.sh
./verify-office.sh
```

Examples of valid values:

| Your situation | What to put |
|----------------|-------------|
| Browser opens `http://192.168.0.20/` | `NEXTCLOUD_HOST=192.168.0.20` (and usually the same for `COLLABORA_HOST`) |
| Browser opens `http://nextcloud.lan/` | `NEXTCLOUD_HOST=nextcloud.lan` |
| Different IPs for each service | Set each host to the matching `EXTERNAL-IP` |

Do **not** use values like `10.43.x.x` / `10.42.x.x` ClusterIPs here — those are internal to the cluster and your browser cannot reach them for Office editing.

## Open the apps

```bash
kubectl -n nextcloud get svc
```

- Nextcloud: `http://EXTERNAL-IP/`
- Collabora discovery: `http://EXTERNAL-IP:9980/hosting/discovery`  
  (your browser should show XML containing `urlsrc=`)

That same `EXTERNAL-IP` is what belongs in `NEXTCLOUD_HOST` / `COLLABORA_HOST` when you re-run `configure-office.sh`.

## Customize

| Setting | Where | Default |
|--------|--------|---------|
| Timezone | Nextcloud `TZ` in `deploy.yaml` | `America/New_York` |
| App + files disk | `nextcloud-html` PVC (`/var/www/html`) | `100Gi` |
| Office dictionaries | Collabora `dictionaries` | `en_US` |

## Update

Pull newer images by editing the tags in `deploy.yaml` (or re-applying after bumping them), then:

```bash
kubectl apply -f deploy.yaml
kubectl -n nextcloud rollout status deployment/nextcloud
kubectl -n nextcloud rollout status deployment/collabora
./configure-office.sh
./verify-office.sh
```

Nextcloud major version upgrades should be done **one major version at a time**.

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
| Works on LAN IP only after reconfigure | Your PC’s LAN IP/DNS changed | Re-run configure with the new browser-facing address (see above) — not a ClusterIP |

## Notes for beginners

- Keep **one replica** of Nextcloud (SQLite) and one of Collabora.
- This homelab layout serves Nextcloud over **HTTP :80** and Collabora over **HTTP :9980** so it works without a reverse proxy. For internet exposure, put **both** behind Caddy/Traefik/nginx with real HTTPS certificates and re-run `configure-office.sh` with your DNS names.
- Official Nextcloud guides prefer a dedicated hostname for Collabora (e.g. `office.example.com`); the IP + LoadBalancer approach here is intentionally simpler for first-time homelab use.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
