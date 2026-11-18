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
Application-owned idle `FIN-WAIT-2` and `CLOSE-WAIT` sockets are included; the
kernel's orphaned FIN timeout does not reliably release those application-owned
descriptors. Half-closed sockets with queued payload are retained.

The host profile enables TCP MTU probing, keeps stricter existing keepalive
settings, limits the default established conntrack timeout to two hours and disables
router redirects. Default conntrack budgets are 32768 below 3 GiB RAM, 65536
below 7 GiB, and 131072 on larger hosts. An existing sensible smaller table is
retained. Oversized tables are reduced only with 25% free capacity around the
current entry count; busy hosts can temporarily retain a larger kernel table.
Existing flows are never flushed. The count is sampled again immediately before
applying a reduction, rather than relying on the pre-download snapshot.
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

### Node performance history and GRE path MTU

The node installer enables one host-wide `marzban-node-health.service`. It records
one timestamped JSON sample per minute under `/var/log/marzban-node-health/samples.jsonl`.
The directory holds up to eight 8 MiB files including the active file. Collection
skips disk writes while less than 512 MiB is available and resumes automatically.
`systemctl status marzban-node-health` shows the time and outcome of the latest sample.
On container creation, the runtime also supplies Docker rotation for an unbounded
`json-file` driver (8 MiB, up to three files). Existing rotation and custom drivers
are respected. A running container takes new Docker log options on its next recreation.

Samples include CPU and softirq per core, Xray CPU/RSS and cgroup pressure counters,
memory, swap, system pressure, disk space and I/O, interface throughput/errors, RX queue RPS
masks, qdisc drops, socket and protocol counters, UDP errors, TCP retransmissions,
IPv4 fragmentation failures, conntrack occupancy and admission status. GRE Manager pairs
include configured, live and kernel-reported route MTUs. Public port counts and queue
sizes reuse the existing idle-guard snapshot. Per-port byte deltas cover sockets seen
in both observations. The history contains aggregate counters and omits client endpoints,
accounts and payloads. A raw snapshot is available immediately with:

```bash
sudo /usr/local/lib/marzban-node/health.py --once
```

If a foreign GRE pair has a verified smaller route MTU, the host helper can lower
that one active pair using GRE Manager's existing transactional update. The kernel
route must use that pair and report a smaller MTU of at least 1280. Applying a
repair is explicit and GRE Manager saves the setting across reboots. Set the same
value on the matching ingress pair so its TCP MSS rule follows the new MTU:

```bash
# On the node, replace PAIR_ID with the affected GRE Manager pair ID.
sudo /usr/local/lib/marzban-node/health.py --apply-gre-pmtu PAIR_ID
# On the ingress, use the same ID and the value printed on the node.
sudo gremgr-pair set-mtu PAIR_ID OBSERVED_MTU
```

### Connection admission budget

The installer enables one host-wide `marzban-node-admission.service`. Every two
seconds it reads the local conntrack count. At 75% of the smaller kernel limit
and configured budget it temporarily rejects **new TCP SYNs only**, on public
listeners owned by Xray in host-network Marzban-node containers. At 60% it
reopens admission. Listener ownership is refreshed periodically. SSH, node
control/API ports, loopback, established TCP sessions and UDP remain unchanged.
IPv4 and IPv6 use dedicated owned chains; unrelated firewall rules are retained.
Stopping or failing the service removes its gate. Multiple node instances share
one controller and one host budget. Bridge-mode nodes are not gated by this
host INPUT controller.

An optional `/etc/marzban-node/connection-budget.json` sets a lower operator
budget, for example:

```json
{"tracked_budget": 50000, "pause_percent": 75, "resume_percent": 60}
```

The default budget uses the RAM tiers above. Status, selected data ports and
thresholds are recorded in `/run/marzban-node-admission.json`. Changes are
validated and read during operation. Invalid settings stop the controller and
clear its gate rather than leaving a stale rejection rule.

This is admission backpressure, not a strict provider-side connection limit.
An upstream host can already have tracked a SYN before the guest rejects it;
the two-second sampling interval can also overshoot. Existing sessions, their
new outbound flows, UDP, other services and other VPSs are outside this gate.
For a guaranteed provider limit, coordinate upstream enforcement and obtain the
actual provider budget. A warning reporting 242000 tracked entries is not itself
a published per-VPS allowance. This feature does not change interface MTU/MSS
or block UDP.

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
