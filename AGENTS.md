# Repository AI agent rules

## Protected installer contract for Master DNS SSL

**ABSOLUTE RULE: AI agents must never change the public installation/update command or its bootstrap installer.** The GitHub repository owner is the only person authorized to approve and perform such modifications manually.

The immutable, public, single-command interface (used for BOTH fresh installation and upgrades) is:

```bash
curl -fsSL https://raw.githubusercontent.com/smorad3363/Marzban-scripts/master/dns-ssl-master/install.sh -o /tmp/master-dns-ssl-install.sh && sudo bash /tmp/master-dns-ssl-install.sh
```

For ANY AI coding assistant, Copilot, PR agent, or autonomous bot working in this repository:

- NEVER edit, rename, move, delete, or replace `dns-ssl-master/install.sh`.
- NEVER change the exact command above, its URL, branch, file path, temporary file name, `sudo bash` invocation, or the canonical line in `dns-ssl-master/README.md` and `dns-ssl-master/INSTALL_COMMAND.txt`.
- NEVER edit or disable `dns-ssl-master/tests/test-installer-contract.sh`, its expected hash, or its CI checks in `.github/workflows/master-dns-ssl-check.yml`.
- NEVER edit this protection rule, `.github/copilot-instructions.md`, or `.github/CODEOWNERS` to circumvent the lock.
- New functionality, fixes, menus, UI, DNS plugins, and security improvements belong in `dns-ssl-master/master-dns-ssl.sh` and other nonprotected files. The stable bootstrap already downloads the latest manager from the master branch, so it requires no edits for normal upgrades.
- If a requested task would require changing any protected installer contract item, **do not perform it**; flag the conflict to the repository owner for a separate human-controlled change.

The automated installer-contract test is a second defense. Branch protection requiring passing checks plus CODEOWNERS review should be enabled by the GitHub repository administrator. These written instructions alone cannot technically prohibit force-pushes, direct owner commits, or other noncompliant AI tooling.
