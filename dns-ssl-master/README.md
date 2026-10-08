# Master DNS SSL — zero inbound ports, simple interactive SSL

Install Let's Encrypt certificates on a MASTER VPS using DNS-01, even when the hostname points to a different NODE IP. No inbound 80/443 required for issuance.

## Install with one command (Ubuntu/Debian)

    curl -fsSL https://raw.githubusercontent.com/smorad3363/Marzban-scripts/master/dns-ssl-master/install.sh -o /tmp/master-dns-ssl-install.sh && sudo bash /tmp/master-dns-ssl-install.sh

After installation:

    sudo master-dns-ssl

## Two easy modes

### 1. Cloudflare auto — recommended for unattended cron renewal

Enter your domain, email and Cloudflare API Token (masked). You do NOT have to look up or enter a Zone ID. acme.sh detects the zone automatically.

Token permissions restricted to the correct zone:

- Zone / DNS / Edit
- Zone / Zone / Read

The script gets a Let's Encrypt certificate using dns_cf, copies it to the install path, and configures a daily renewal check at 03:23 server time. No manual DNS records or changing A/AAAA records. A successful renewal triggers the configured reload command.

### 2. Manual TXT — simplest for one-time issuance

No Cloudflare API credentials are required. The script prints the DNS TXT record(s), and you add them in your DNS panel manually. This can work with other DNS providers too.

For example, to cover the hostname german-hetzner.drwrdoh.org and its wildcard *.german-hetzner.drwrdoh.org, validation TXT records appear under:

    _acme-challenge.german-hetzner.drwrdoh.org

If both hostname and wildcard were selected, two TXT values at the same record name may be required. Keep both TXT values until validation succeeds.

After adding the records and waiting for propagation, return to the menu and use option 6 to finish verification if you closed the initial prompt.

**Manual TXT mode cannot automatically renew with cron.** DNS-01 values are different at each issuance or renewal. Use automatic Cloudflare API mode for uninterrupted renewals.

## Manager menu

1. Issue SSL (Cloudflare automatic / manual TXT)
2. List certificates
3. Inspect certificate
4. Force renewal (intended for automatic DNS API mode)
5. Cron status and logs
6. Finish pending manual TXT challenge
0. Exit

## Certificate paths

    /etc/ssl/master-dns-ssl/<domain>/fullchain.pem
    /etc/ssl/master-dns-ssl/<domain>/privkey.pem

Installed launcher: /usr/local/sbin/master-dns-ssl.

The Cloudflare API token is stored by acme.sh in root-only files under /root/.acme.sh; never commit or share these files.

## Notes

- The master certificate does not automatically configure TLS on a node that terminates client connections.
- No inbound port is required for DNS-01 issuance, but your application may still need publicly accessible ports.
- Choose a reload hook (Nginx, Caddy, Marzban, custom) for servers to read the new certificate automatically after renewal.
- Outbound HTTPS and working DNS are still necessary.
- Review internet-fetched code before running it with root privileges.

Based on official acme.sh: https://github.com/acmesh-official/acme.sh
