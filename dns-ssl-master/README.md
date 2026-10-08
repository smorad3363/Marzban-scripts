# Master DNS SSL — interactive SSL on the master

Ubuntu/Debian utility to issue Let's Encrypt TLS certificates on your MASTER through Cloudflare DNS-01, even when the domain's A/AAAA record points to a different NODE IP. No inbound 80/443 ports are required for issuing or renewing these certificates.

## One-command installer

Run on your master in an interactive SSH terminal:

    curl -fsSL https://raw.githubusercontent.com/smorad3363/Marzban-scripts/master/dns-ssl-master/install.sh -o /tmp/master-dns-ssl-install.sh && sudo bash /tmp/master-dns-ssl-install.sh

Open the installed menu again:

    sudo master-dns-ssl

## Features

- Interactive ANSI-colored terminal menu.
- Cloudflare DNS-01 authorization, optionally including wildcard hosts.
- Enter a domain, Let's Encrypt email, Cloudflare Zone ID, and masked API Token.
- View, inspect, and force-renew issued certificates.
- Pick a reload strategy for Nginx, Caddy, Marzban (Docker/systemd), no reload, or custom command.
- Daily cron renewal check at 03:23 server time, reusing a pre-existing root acme.sh cron when found.
- Automatic copying of renewed full-chain and private-key files; optional application reload.
- No firewall configuration changes and no DNS A/AAAA modifications.

## Requirements

- Debian or Ubuntu with apt, SSH terminal, root/sudo.
- Outbound HTTPS access to GitHub, Cloudflare, Let's Encrypt; functioning DNS.
- Domain delegated to Cloudflare authoritative DNS.
- Scoped Cloudflare API Token with Zone > DNS > Edit and Zone > Zone > Read permissions, limited to the relevant zone.
- Cloudflare Zone ID (found on Cloudflare's zone overview page).

## Files

    /usr/local/sbin/master-dns-ssl
    /etc/ssl/master-dns-ssl/<domain>/fullchain.pem
    /etc/ssl/master-dns-ssl/<domain>/privkey.pem
    /etc/cron.d/master-dns-ssl
    /var/log/master-dns-ssl.log

The manager installs acme.sh under /root/.acme.sh. acme.sh retains Cloudflare DNS credentials in root-only configuration so unattended renewals can add temporary DNS TXT records.

## How renewal works

Every day a cron runs acme.sh --cron. acme.sh renews certificates only when appropriate (not every day). Successful renewals update the installed files and invoke the configured reload hook.

If you pick "No reload", renewed certificate files are automatically replaced, but your running server may need to be reloaded to use the replacement.

## Important

- The domain's A/AAAA records can remain pointed at your NODE throughout issuance and renewal.
- The MASTER certificate does not itself secure HTTPS/TLS that terminates on the NODE; configure TLS on whichever server actually accepts client connections.
- No inbound port is needed for DNS-01 issuance, but a public service may still need open ports for actual traffic.
- Other DNS providers require their own API integrations; manual DNS cannot support unattended renewal.
- Store the API Token securely and do not publish /root/.acme.sh.
- Review remotely downloaded scripts before executing them as root.

Uses the upstream official acme.sh project: https://github.com/acmesh-official/acme.sh
