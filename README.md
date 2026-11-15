# Marzban-scripts
Scripts for Marzban

## Set the system Owner

After updating Marzban to a version that supports the Admin hierarchy, select an
existing Admin as the Owner with:

```bash
marzban set-owner USERNAME
```

The equivalent command for servers that still have an older management script is:

```bash
marzban cli admin set-owner --username USERNAME
```

## Installing Marzban
- **Install Marzban with SQLite**:

```bash
sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install
```

- **Install Marzban with MySQL**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install --database mysql
  ```

- **Install Marzban with MariaDB**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb
  ```
  
- **Install Marzban with MariaDB and Dev branch**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb --dev
  ```

- **Install Marzban with MariaDB and Manual version**:

  ```bash
  sudo bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install --database mariadb --version v0.5.2
  ```

- **Update or Change Xray-core Version**:

  ```bash
  sudo marzban core-update
  ```


## Installing Marzban-node

The standard Marzban-node command keeps the upstream arguments, menus, instance
names and management commands. Only the GitHub owner in the URL changes:

```bash
sudo bash -c "$(curl -sL https://github.com/smorad3363/Marzban-scripts/raw/master/marzban-node.sh)" @ install --name master
```

Use this same command on an existing `master` node to upgrade it in place. It
preserves the certificate, ports, protocol, previous core binary, data and original
`docker-compose.yml`; it does not ask for the certificate again. Keep the original
instance name when upgrading another instance.

The existing management commands remain available:

```bash
master status
master logs
master restart
master update
master core-update
```

The memory profile uses `GOGC=50` and assigns 75% of the server's effective
RAM to Go's soft memory budget. Installation and upgrades recalculate this budget,
including instances previously installed with the 50% policy. The profile adds
idle, handshake and buffer policies; their enforcement depends on the protocol
and core implementation. Traffic counters and account settings are retained. This is a soft Go
budget, not a hard RSS cap. Diagnostics stay opt-in to avoid port collisions
between instances. The selected image is pinned locally in
`/opt/<name>/docker-compose.runtime.json`; `update` still pulls the original image
tag from the unchanged base Compose file before preparing its runtime.
If pulling the standard Docker Hub image fails or is rate limited, the official
GHCR mirror is pulled and tagged locally. The base Compose file is retained and
the same runtime source checks run before deployment. Custom images are never
silently replaced with the standard mirror.

Install/update/restart now select official **Xray v26.3.27** on amd64 and arm64.
Both archive and executable SHA256 values are checked before deployment. The
previous executable and assets remain available for rollback. The version pin is
in the runtime overlay, so `core-update` does not override it on the next install,
update or restart.

The runtime reaps terminated children, serializes core changes, and drains stderr
with stdout. REST start/restart returns when the core-ready message arrives,
instead of always waiting the complete three-second timeout.

Some v26.3.27 transports, including legacy SS2022, do not fully enforce `connIdle`.
A per-instance systemd timer therefore checks only that container's Xray TCP
sockets. It closes at most 2000 sockets per minute in verified batches after five minutes without data,
requiring unchanged byte counters in two observations, empty queues, matching
socket ownership and a final rescan. SSH and node control ports are excluded.
This also closes deliberately idle live client sessions after five minutes;
clients reconnect normally. It does not kill processes or flush conntrack. UDP
is retained because its use must be established separately for each service.

The host profile enables TCP MTU probing, keeps stricter existing keepalive
settings, limits the default established conntrack timeout to two hours, disables
router redirects and increases undersized conntrack tables according to RAM.
It does not change interface MTU, routes, DNS, congestion control or firewall
policy. Multiple node instances are serialized with one host-wide installer lock.
The 75% Go budget is per instance and is not a reservation; several busy instances
can exceed host RAM together and need a shared capacity plan.
An explicit Compose memory limit is included in the effective-memory calculation:
the Go budget is 75% of the smaller host or target-container limit. Setting a
container limit can therefore reserve host capacity for kernel buffers and other
services without changing the default 75% policy.

The installer validates the runtime module and Compose configuration before
recreating the node. Runtime backups are stored under
`/var/lib/<name>/node-runtime-backups/`; a failed deployment restores the previous
runtime and image. Unsupported future module versions are rejected before the
running node is stopped. The master-side fixes tested separately are not applied
to a different master by this node installer.

### Legacy master connection stability

`master-runtime/patches.py` contains separately reviewed, checksum-gated fixes for
the deployed legacy master's control client and health job. The REST client
serializes session changes and status requests, bounds TLS certificate retrieval
to ten seconds, and uses a monotonic cache clock. The health job requires repeated
failures and a fresh check before recovery, renews a stale REST gRPC channel first,
and applies a two-minute recovery cooldown. An explicitly stopped core gets a
shorter confirmation period. One slow two-second statistics probe no longer
immediately restarts a data core.

For the exact supported legacy source, run as root from this checkout:

```bash
python3 master-runtime/apply.py /opt/marzban
```

The helper refuses unknown source or mount layouts, backs up existing files,
adds only the two code mounts, and recreates only the panel service. It does not
modify accounts, accounting rules or database configuration. The node installer
does not apply this master patch automatically to unrelated panel versions.

### Optional multi-instance wrapper

Use the multi-instance-safe installer from this fork:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/smorad3363/Marzban-scripts/master/install-node.sh)"
```

The installer interactively asks for:

- a unique node instance name; it suggests `marzban-node`, then `marzban-node2`, `marzban-node3`, and so on;
- `SERVICE_PORT`;
- `XRAY_API_PORT`;
- the Client Certificate generated by the main Marzban panel;
- whether to use the REST protocol.

The port checks cover both currently listening ports and ports reserved in existing
Marzban-node compose files. This prevents a stopped node from being accidentally
configured with the same ports as a new node. Every instance gets its own
`/opt/<instance>`, `/var/lib/<instance>`, Docker container name and management
command, so multiple nodes can run safely on one server.

For example, after installing an instance named `marzban-node2`:

```bash
marzban-node2 status
marzban-node2 logs
marzban-node2 restart
marzban-node2 update
```

The legacy installer remains available when you intentionally want to manage the
instance name yourself:

```bash
sudo bash -c "$(curl -sL https://github.com/smorad3363/Marzban-scripts/raw/master/marzban-node.sh)" @ install --name marzban-node2
```

To install only the legacy management script:

```bash
sudo bash -c "$(curl -sL https://github.com/smorad3363/Marzban-scripts/raw/master/marzban-node.sh)" @ install-script
```

Use `help` on the installed instance command to view all commands, for example:

```bash
marzban-node2 help
```

- **Update or Change Xray-core Version**:

  ```bash
  sudo marzban-node2 core-update
  ```
