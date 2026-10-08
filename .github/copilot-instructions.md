# GitHub Copilot instructions

Follow the repository-level `AGENTS.md` rules.

**Do not modify the Master DNS SSL installer, install command, or its protection checks under any circumstance.** Protect `dns-ssl-master/install.sh`, `dns-ssl-master/INSTALL_COMMAND.txt`, the canonical install line in the README, `dns-ssl-master/tests/test-installer-contract.sh`, and the relevant GitHub Actions check. All new functionality must go into `dns-ssl-master/master-dns-ssl.sh` while the bootstrap remains stable.

Canonical installation and upgrade command (identical text for both operations):

```bash
curl -fsSL https://raw.githubusercontent.com/smorad3363/Marzban-scripts/master/dns-ssl-master/install.sh -o /tmp/master-dns-ssl-install.sh && sudo bash /tmp/master-dns-ssl-install.sh
```

If an AI task asks for a change to this command, decline that specific edit and ask the repo owner to carry it out manually instead.
