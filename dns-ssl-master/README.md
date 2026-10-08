# Master DNS SSL — Quick SSL issuance on a Master server

An interactive manager for Let's Encrypt DNS-01 certificates. Your hostname may point to a separate NODE IP; no inbound ports 80/443 are needed **to issue or renew certificates**.

## Install or update (Ubuntu/Debian)

    curl -fsSL https://raw.githubusercontent.com/smorad3363/Marzban-scripts/master/dns-ssl-master/install.sh -o /tmp/master-dns-ssl-install.sh && sudo bash /tmp/master-dns-ssl-install.sh

Open menu again:

    sudo master-dns-ssl

## Quick mode: only the essential questions

**Option 1: Manual DNS TXT SSL**
1. Enter a domain name once, like dfsah.org (without https:// or *.).
2. By default the program requests both dfsah.org and *.dfsah.org, creates the TXT challenges and displays all needed values.
3. Create BOTH TXT values in your DNS panel (often two records with the same _acme-challenge.dfsah.org name).
4. Once publicly propagated, press Enter. If you want to finish later, type q; next time simply use menu option 6. The manager remembers the pending domain, so you don't need to retype it.

No email, wildcard, reload, folder, mode or initial confirmation prompts. **Manual TXT certificates DO NOT automatically renew**. New TXT values are required for every renewal. Issuing DNS TXT challenges does not change DNS A/AAAA records.

**Option 2: Cloudflare auto SSL**
1. Enter a domain.
2. If you have never used this token before, enter a Cloudflare API Token (input hidden). Zone/DNS/Edit and Zone/Zone/Read permissions are required for the zone.
3. The manager issues root + wildcard SSL and sets a daily ACME renewal check using cron (03:23 server time).

Zone ID is not requested, and an existing saved API Token is automatically reused. acme.sh persists the certificate file destinations and renewal/reload hooks for future renewals.

For accounts requiring a different DNS-zone token, configure the correct token in acme.sh's protected credential configuration before issuance; different zone permissions can cause the reused credential to fail.

## Defaults

- Domain + wildcard: ON
- Certificate directory: /var/lib/marzban/certs/<domain>/
- Certificate: /var/lib/marzban/certs/<domain>/fullchain.pem
- Private key: /var/lib/marzban/certs/<domain>/key.pem
- Service reload on renewal: OFF (configure if needed)
- Account email: NOT required (rather than inventing a fake email)
- ACME CA: Let's Encrypt
- Incoming ports for DNS-01 issuance: NONE

If an acme.sh account already exists, its account contact is retained.

For example:

    /var/lib/marzban/certs/dfsah.org/fullchain.pem
    /var/lib/marzban/certs/dfsah.org/key.pem

Both file paths are displayed after installation, in "List certificates", and in "Certificate details". Use fullchain.pem as the Xray TLS certificateFile, key.pem as the keyFile. If Xray runs on a NODE, the certificate must also reach that server, which is separate from issuance on MASTER.

## Menu

1. Manual TXT SSL (default root + wildcard)
2. Cloudflare automatic SSL with cron renewal
3. List certificates and paths
4. Certificate details and paths
5. Force-renew an API-issued certificate
6. Complete pending manual TXT challenge without retyping the domain
7. Cron status and logs
8. Advanced Settings
9. Change existing certificate directory
0. Exit

## Advanced Settings (option 8)

- Change default base directory; every new hostname still gets a distinct subfolder.
- Configure a reload command for future installs (e.g., Nginx reload, Docker restart, custom).
- Set an **optional real** Let's Encrypt account email (used for new installations of acme.sh).
- Toggle wildcard coverage off if you want only the root domain.

Existing installed certificates are not rewritten when advanced settings change. Use option 9 to reinstall an existing certificate to a new destination and apply the current reload choice.

For existing certificates issued with older versions, the manager continues to recognize /etc/ssl/master-dns-ssl/<domain> and can help move them.

## Security and limits

- Manual TXT remains manual at each renewal. Cron does not replace the human TXT changes.
- Cloudflare credentials are stored in acme.sh's root-only configuration under /root/.acme.sh for unattended renewals. Never disclose them.
- Advanced custom reload commands run as root; enter only trusted commands.
- Service TLS requires its own open port(s). DNS-01 certificate issuance does not.
- Certificate files belong to the master host until you explicitly configure the actual TLS endpoint (e.g., Xray/Marzban or NODE) to use them.
- Always review code before executing a script from the internet as root.

Uses the official acme.sh project: https://github.com/acmesh-official/acme.sh
