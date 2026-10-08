# Master DNS SSL — Quick SSL issuance on a Master server

An interactive manager for Let's Encrypt DNS-01 certificates. Your hostname may point to a separate NODE IP; no inbound ports 80/443 are needed **to issue or renew certificates**.

## Install or update (Ubuntu/Debian)

**PERMANENT INSTALL + UPDATE COMMAND — DO NOT CHANGE.** Run this same exact line on a clean server to install, or on an existing server to update. No separate upgrade command is needed. AI agents are forbidden from editing this line or the bootstrap installer; see [AI protection rules](../AGENTS.md) and [immutable command](INSTALL_COMMAND.txt). Changes to the installed manager can continue independently.

    curl -fsSL https://raw.githubusercontent.com/smorad3363/Marzban-scripts/master/dns-ssl-master/install.sh -o /tmp/master-dns-ssl-install.sh && sudo bash /tmp/master-dns-ssl-install.sh


For additional safeguards, the repository includes a fixed-hash [installer contract test](tests/test-installer-contract.sh), AI assistant instructions, and a CODEOWNERS file. To block unauthorized merges, the repository administrator should also enable protected-branch required checks and CODEOWNERS review; text instructions and CI checks are not an absolute technical permission barrier on their own.

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


## Clear copy-ready output (v2026.10.08-ux3)

For manual issuance, the script now captures the verbose acme.sh output and displays each requested DNS record separately. Example layout:

    ------------------ TXT RECORD 1 ------------------
    TYPE:
    TXT
    NAME (FULL DNS NAME):
    _acme-challenge.example.org
    CLOUDFLARE NAME (only if the DNS zone itself is example.org):
    _acme-challenge
    CONTENT / TXT VALUE (copy the next line exactly):
    <the actual token from your run>

With wildcard enabled there are normally **two values at the same Name**; create two TXT records, don't replace the first value with the second. For subdomains, use the FULL DNS NAME or the label relative to the DNS zone that owns the records. Cloudflare automatically appends that zone to relative Name fields.

Successful certificate verification no longer dumps a complete PEM certificate into the console. The paths are printed as two standalone copyable lines:

    CERTIFICATE FILE (certificateFile):
    /var/lib/marzban/certs/example.org/fullchain.pem

    PRIVATE KEY FILE (keyFile):
    /var/lib/marzban/certs/example.org/key.pem

If verification is deferred, menu option 6 displays the **previously generated** pending TXT records again. Once issuance succeeds, pending TXT values are removed from local state and the certificate paths remain in menu options 3 and 4.

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
