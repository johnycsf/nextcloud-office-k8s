# Breaking changes (read before updating)

**`git pull` alone does not delete PVCs or restart pods.**  
Your cluster keeps the old Deployments until you re-run `install.sh` or `kubectl apply -f deploy.yaml`.

If you installed from an **older revision**, re-applying current manifests is **not** a lossless in-place migration. **Back up first.**

## What changed

| Older clone | Current repo | Risk if you re-apply |
|-------------|--------------|----------------------|
| LinuxServer Nextcloud image | Official `nextcloud:latest` | Volume/layout mismatch; do not reuse old PVC casually |
| Nextcloud on **SQLite** (no `db` Deployment) | **MariaDB** (`mariadb:lts` + Secret `nextcloud-db`) | Existing install keeps SQLite in `config.php`; MariaDB is unused/empty. No automatic migration |
| Single `nextcloud-html` PVC | Also `nextcloud-db` PVC | New disk for the database |

Nextcloud does **not** auto-convert SQLite → MariaDB.

## If you already have a working Nextcloud

1. **Do nothing** after pulling — do not run `./install.sh`.
2. Or pin the last working commit.
3. Or migrate deliberately: backup, delete/recreate PVCs (or new namespace), fresh install, restore files.

`install.sh` refuses when it detects LinuxServer or SQLite installs, unless:

```bash
I_UNDERSTAND_THIS_IS_A_FRESH_INSTALL=yes ./install.sh
```
