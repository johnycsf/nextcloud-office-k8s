# Security Policy

## Supported versions

Security fixes are applied on a best-effort basis to the **latest `main`** branch of this repository (install/update/backup scripts and manifests). Upstream applications (for example Immich, Vaultwarden, Nextcloud, Collabora, Heimdall) have their **own** security processes — report product vulnerabilities to those projects when the issue is in their code or images.

## Reporting a vulnerability

Please **do not** open a public GitHub Issue for sensitive security reports.

1. Use GitHub’s **Private vulnerability reporting** on this repository if it is enabled, **or**
2. Email **johnycsf@gmail.com** with:
   - Repo name and commit/tag
   - Description of the issue and impact
   - Steps to reproduce (no secrets in screenshots if avoidable)
   - Whether the issue is in **this** packaging/scripts or in an **upstream** app

You should receive an acknowledgment when possible. There is no bug bounty for these personal homelab projects.

## Hardening expectations

These stacks are aimed at **homelab / trusted LAN** use. You are responsible for reverse proxies, TLS, firewalls, backups, and keeping upstream images updated (`./manage.sh update` where provided).

See also [DISCLAIMER.md](DISCLAIMER.md) and [CREDITS.md](CREDITS.md).
