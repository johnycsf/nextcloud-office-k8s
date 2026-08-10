# Contributing

Thanks for wanting to help. These projects are meant to stay simple for homelab beginners.

## How to contribute

1. Fork the repository
2. Create a branch for your change
3. Make the smallest change that solves the problem
4. Test on a real Kubernetes/homelab setup when the change touches install or deploy scripts
5. Open a Pull Request that explains:
   - what problem you hit
   - what you changed
   - how you verified it

## Guidelines

- Prefer clarity over cleverness — READMEs and scripts should work for first-time users
- Keep one-command installs working (`./install.sh` where present)
- Do not commit secrets, tokens, or personal hostnames/IPs
- Match existing file style (bash, YAML, Markdown)

## Issues

Bug reports and ideas are welcome. Include:

- Distro / Kubernetes version (if relevant)
- Exact command you ran
- Error output or screenshots
