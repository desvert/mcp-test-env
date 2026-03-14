# Network Forensics Lab Environment

A self-contained Docker Compose lab that automatically generates realistic network
forensics samples — PCAP, Suricata IDS alerts, and Zeek NSM logs — by running
scripted attacks against an intentionally vulnerable target. Designed for analysis
practice with the [mcp-netparse](https://github.com/desvert/ai-soc-mcp-lab) / [mcp-otparse](https://github.com/desvert/otparse-mcp) toolchain.

---

## Table of Contents

1. [What This Does](#what-this-does)
2. [Architecture](#architecture)
3. [Services](#services)
4. [Prerequisites](#prerequisites)
5. [Quickstart](#quickstart)
6. [Detailed Usage](#detailed-usage)
7. [Generated Output](#generated-output)
8. [Attack Coverage](#attack-coverage)
9. [Integration with the MCP Toolchain](#integration-with-the-mcp-toolchain)
10. [Customization](#customization)
11. [Troubleshooting](#troubleshooting)
12. [Security Notes](#security-notes)

---

## What This Does

Running `docker compose up` will:

1. Start **Metasploitable2** — a Linux VM image deliberately packed with vulnerable
   services (vsftpd 2.3.4, OpenSSH, Apache/DVWA, UnrealIRCd, Tomcat, PostgreSQL, VNC).
2. Start three **sensor containers** that passively monitor all lab traffic:
   - `tcpdump` → writes a full PCAP
   - `suricata` → IDS with Emerging Threats Open rules, writes `fast.log` and `eve.json`
   - `zeek` → NSM, writes `conn.log`, `http.log`, `dns.log`, and more
3. Start an **attacker container** that runs a sequence of automated attacks — port
   scans, web scans, brute-force, HTTP injection attempts, and banner grabs — then exits.

Everything is written to `output/` on the host, ready for analysis.

---

## Architecture

```
                ┌──────────────────────────────────────────────────────┐
                │               Docker bridge: lab-br0                 │
                │                  (172.30.0.0/24)                     │
  ┌──────────┐  │  ┌──────────────────────┐                           │
  │ attacker │◄─┼─►│       victim         │                           │
  │.0.20     │  │  │  172.30.0.10         │                           │
  └──────────┘  │  │  Metasploitable2     │                           │
                │  │  FTP · SSH · HTTP    │                           │
                │  │  SMB · VNC · IRC     │                           │
                │  │  Telnet · SMTP       │                           │
                │  └──────────────────────┘                           │
                └──────────────────────────────────────────────────────┘
                              │ all frames visible via promiscuous mode
                              ▼
                ┌─────────────────────────────────────┐
                │          host network               │
                │                                     │
                │  tcpdump ──► output/pcap/           │
                │  suricata ──► output/suricata/      │
                │  zeek ──────► output/zeek/          │
                └─────────────────────────────────────┘
```

### Why sensors run on the host network

Docker bridge networks perform L2 switching: a container only sees traffic
addressed to itself or to the broadcast address. Even with `NET_RAW` and
promiscuous mode, a container inside the bridge subnet cannot sniff unicast
frames between *other* containers.

The solution is to attach the sensor containers to the **host network** instead.
From the host they can see `lab-br0` — the Linux bridge that backs the `labnet`
Docker network — and capture every frame that crosses it.

### Why the bridge is named

Docker generates a random bridge name like `br-a3f9c12d8e1b` for each compose
project. Rather than trying to discover that at runtime, `docker-compose.yml`
sets `com.docker.network.bridge.name: lab-br0`. This gives us a stable, known
interface name that all sensor start scripts can reference without any discovery
logic.

### Startup sequencing

```
Docker creates labnet / lab-br0
        │
        ├─► victim starts         (creates lab-br0 by joining labnet)
        │
        ├─► tcpdump starts        (loops until /sys/class/net/lab-br0 exists)
        ├─► suricata starts       (same wait; then runs suricata-update; then captures)
        └─► zeek starts           (same wait; then captures)
                │
                └─► attacker starts (depends_on all sensors; then waits for victim ping)
```

`depends_on` ensures Docker's start *ordering*. The wait loops inside each
start script guard against the small race between Docker assigning the container
to the network and the bridge actually appearing in the host's interface list.
The attacker's ping loop gives Metasploitable2's init system time to fully boot
all its services before attacks begin.

---

## Services

| Service | Image | IP | Purpose |
|---|---|---|---|
| `victim` | `tleemcjr/metasploitable2` | 172.30.0.10 | Vulnerable target |
| `attacker` | custom (`ubuntu:22.04`) | 172.30.0.20 | Runs attack sequences |
| `tcpdump` | custom (`alpine:3.19`) | host | Full PCAP capture |
| `suricata` | `jasonish/suricata:latest` | host | IDS — alerts + metadata |
| `zeek` | `zeek/zeek:latest` | host | NSM — protocol logs |

### victim — Metasploitable2

Metasploitable2 is an Ubuntu 8.04 system intentionally configured with known-
vulnerable software. Services available on port:

| Port | Service | Notable vulnerability |
|---|---|---|
| 21 | vsftpd 2.3.4 | Backdoor (`:)` in username spawns shell on :6200) |
| 22 | OpenSSH 4.7 | Weak credentials; protocol downgrade |
| 23 | Telnet | Cleartext credentials |
| 25 | Sendmail / Postfix | Open relay |
| 80 | Apache + DVWA | SQLi, XSS, LFI, command injection |
| 139/445 | Samba 3.x | MS08-067 style SMB vulns |
| 3306 | MySQL | No root password |
| 5432 | PostgreSQL | Default credentials |
| 5900 | VNC | No auth / weak auth |
| 6667 | UnrealIRCd | Remote code execution backdoor |
| 8180 | Apache Tomcat 5.5 | Default manager credentials |

Because Metasploitable2 runs a full SysV `init` inside the container, it requires
`privileged: true` in the compose file. This is acceptable for an isolated lab;
see [Security Notes](#security-notes).

### attacker

Built from `ubuntu:22.04`. Installed tools:

- **nmap** — port scanning and service fingerprinting
- **nikto** — web server vulnerability scanning
- **hydra** — credential brute forcing (FTP, SSH, HTTP)
- **curl** — HTTP attacks (SQLi, traversal, XSS, Shellshock)
- **ncat / netcat-openbsd** — banner grabbing
- **python3** — available for custom scripts
- **nslookup / dig** — DNS queries (generates zeek `dns.log` entries)

Wordlists live in `attacker/wordlists/`:
- `users.txt` — 10 usernames common to Metasploitable2
- `passwords.txt` — 16 passwords including Metasploitable2 defaults

The attacker **exits after completing all sequences**. The sensors keep running
until you stop the stack. Re-run the attacker without restarting sensors:

```bash
docker compose run --rm attacker
```

### tcpdump

Built from `alpine:3.19` with `tcpdump` installed. Runs `network_mode: host`
and captures on `lab-br0` in full-packet (`-s 0`) mode, writing to
`output/pcap/capture.pcap`. No filtering is applied — every frame is preserved.

### suricata

Uses the official `jasonish/suricata` image (Debian-based). At startup,
`sensor/suricata/start.sh`:

1. Waits for `lab-br0`
2. Runs `suricata-update` to pull/refresh Emerging Threats Open rules
3. Falls back gracefully if no internet is available (touches the rules file so
   Suricata doesn't abort on a missing include)
4. Launches Suricata with the lab config (`sensor/suricata/suricata.yaml`)

Key `suricata.yaml` choices:
- `HOME_NET: 172.30.0.0/24` — alerts correctly classify attacker vs victim
- `community-id: true` in eve-log — allows correlating Suricata flows with Zeek
  `conn.log` entries using the shared Community ID field
- `checksum-validation: no` — local lab traffic often has incorrect checksums
  due to TSO/GSO offloading; disabling prevents false drops
- HTTP port list includes 8180 for Tomcat traffic
- SSH HASSH fingerprinting enabled

### zeek

Uses the official `zeek/zeek` image. Runs `zeek -i lab-br0 local`, which loads
the default `local.zeek` policy. This generates the full set of standard logs.
Logs are written to `output/zeek/` (mounted as the working directory).

---

## Prerequisites

- **Docker Engine 24.0+** with Docker Compose v2
- **Linux host** — sensors use `network_mode: host` to capture the Docker bridge.
  This will *not* work on Docker Desktop for macOS or Windows (the Docker VM's
  bridge is not visible from the host).
- **5-6 GB free disk** for images + runtime output
- **Internet access** at container startup (for `suricata-update`); the stack
  still works without it, just with an empty rule set

---

## Quickstart

```bash
# Clone the repo
git clone https://github.com/desvert/mcp-test-env
cd mcp-test-env

# Build custom images (attacker + tcpdump sensor)
docker compose build

# Option A — run everything together
docker compose up

# Option B — start sensors first, then attacker (lets you verify sensors are
# capturing before generating traffic)
docker compose up -d victim tcpdump suricata zeek
docker compose logs -f suricata zeek &   # watch sensor startup
docker compose run --rm attacker         # run attacks; exits when done
docker compose down                      # stop sensors, preserve output
```

Total runtime is roughly **15–25 minutes** depending on your machine:
- Metasploitable2 boot: ~30–60 s
- Attacker sequences: ~10–20 min (nikto and hydra are the slow parts)

---

## Detailed Usage

### Building images

```bash
# Build only the attacker image
docker compose build attacker

# Build only the tcpdump sensor
docker compose build tcpdump

# Force rebuild (e.g., after editing attacks.sh)
docker compose build --no-cache attacker
```

### Running the attacker multiple times

Each run **appends** to `attacker.log` and **overwrites** other output files.
To preserve separate runs:

```bash
# Archive the previous run's output
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p output/runs/$STAMP
cp output/pcap/capture.pcap    output/runs/$STAMP/
cp output/suricata/eve.json    output/runs/$STAMP/
cp -r output/zeek/             output/runs/$STAMP/zeek/

# Run again
docker compose run --rm attacker
```

### Stopping cleanly

```bash
# Stop all containers, remove networks (output/ is preserved)
docker compose down

# Also remove named volumes and built images
docker compose down --volumes --rmi local
```

### Monitoring sensor output live

```bash
# Suricata alerts as they fire
docker compose logs -f suricata

# Zeek conn.log in real time (sensors must be running)
tail -f output/zeek/conn.log

# Fast alert format
tail -f output/suricata/fast.log
```

---

## Generated Output

After a complete run, `output/` will contain:

### `output/pcap/capture.pcap`

Full-fidelity PCAP of every frame that crossed `lab-br0`. Open in Wireshark, or
pass to any of the `mcp__netparse__pcap_*` MCP tools.

### `output/suricata/`

| File | Contents |
|---|---|
| `fast.log` | One-line-per-alert human-readable format |
| `eve.json` | Rich JSON event stream (alerts, HTTP, DNS, TLS, SSH, FTP, flows) |
| `suricata.log` | Engine startup, rule load stats, diagnostics |
| `stats.log` | Packet counters, decoder stats, flow table metrics |

`eve.json` is the primary output. Each line is a self-contained JSON object with
a `event_type` field (`alert`, `http`, `dns`, `flow`, `ssh`, `ftp`, etc.).

Example alert entry:
```json
{
  "timestamp": "2026-03-12T14:23:01.123456+0000",
  "event_type": "alert",
  "src_ip": "172.30.0.20",
  "src_port": 54321,
  "dest_ip": "172.30.0.10",
  "dest_port": 21,
  "proto": "TCP",
  "community_id": "1:abc123...",
  "alert": {
    "action": "allowed",
    "gid": 1,
    "signature_id": 2010935,
    "rev": 3,
    "signature": "ET SCAN Potential FTP Brute-Force attempt",
    "category": "Attempted Information Leak",
    "severity": 2
  }
}
```

### `output/zeek/`

Standard Zeek TSV logs. The `local` policy generates:

| File | Contents |
|---|---|
| `conn.log` | Every TCP/UDP/ICMP flow with bytes, duration, state |
| `http.log` | HTTP requests — URI, method, status, user-agent, referrer |
| `ftp.log` | FTP commands and data channel activity |
| `ssh.log` | SSH sessions — client/server versions, auth outcome, HASSH |
| `dns.log` | DNS queries and responses |
| `ssl.log` | TLS handshakes — JA3/JA3S fingerprints, cert subject |
| `files.log` | Files transferred over HTTP, FTP, SMTP, etc. |
| `notice.log` | Zeek policy detections (port scans, etc.) |
| `weird.log` | Protocol anomalies |
| `pe.log` | Portable executable metadata (if any executables transferred) |

Zeek rotates logs by default. All logs from a single run appear in `output/zeek/`
without subdirectories (the working-dir mount keeps them flat). Actual logs generated may vary based on traffic observed.

### `output/attacker/` (written by attacker container)

| File | Contents |
|---|---|
| `nmap_targeted.txt` | Service scan of key Metasploitable2 ports |
| `nmap_targeted.xml` | Same scan in XML (parseable by nmap parsers) |
| `nmap_full.txt` | Full `-p-` scan |
| `nmap_extra.txt` | VNC / IRC targeted probes |
| `nikto_80.txt` | Web vulnerability scan on port 80 |
| `nikto_8180.txt` | Web vulnerability scan on port 8180 (Tomcat) |
| `hydra_ftp.txt` | FTP brute-force results |
| `hydra_ssh.txt` | SSH brute-force results |
| `attacker.log` | Timestamped run log |

---

## Attack Coverage

`attacker/attacks.sh` runs the following sequences in order:

| Phase | Tool | What it generates |
|---|---|---|
| 0. Reachability | ping | ICMP echo in `conn.log` |
| 1. Targeted port scan | nmap -sV -sC | SYN packets, banners; Suricata scan alerts |
| 2. Full port scan | nmap -p- | High-volume SYN sweep; `notice.log` PortScan |
| 3. Web scan port 80 | nikto | HTTP GET flood; SQLi/XSS probe signatures in `http.log` |
| 4. Web scan port 8180 | nikto | Tomcat-specific probes |
| 5. FTP brute force | hydra | Repeated FTP auth attempts; Suricata ET SCAN alert |
| 6. SSH brute force | hydra | Repeated SSH auth; `ssh.log` auth failures |
| 7. HTTP SQLi | curl | UNION, OR, stacked-query payloads; web attack signatures |
| 8. Path traversal | curl | `../../etc/passwd` LFI patterns |
| 9. XSS | curl | `<script>` tags in query strings |
| 10. Shellshock | curl | CVE-2014-6271 User-Agent payload |
| 11. Suspicious UAs | curl | sqlmap, nikto, nmap UA strings |
| 12. Anonymous FTP | curl | Anonymous login attempt |
| 13. DNS lookups | nslookup | Benign + suspicious/NXD domains in `dns.log` |
| 14. Banner grabs | ncat | Telnet (23), SMTP (25), IRC (6667) banners |
| 15. VNC/IRC probe | nmap | Version scan; VNC and IRC Zeek logs |
| 16. Tomcat auth | curl | Default credential brute against `/manager/html` |

---

## Integration with the MCP Toolchain

The `output/` directory is directly usable with the `mcp-netparse` and
`mcp-knowledgeops` servers defined in `../containers/`. Mount `output/` as the
evidence volume:

```json
// .mcp.json
{
  "mcpServers": {
    "netparse": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "--network", "none",
        "-v", "$(pwd)/output:/evidence:ro",
        "mcp-netparse:latest"
      ]
    }
  }
}
```

Then, in a Claude Code session:

```
// Triage the PCAP
mcp__netparse__pcap_triage_overview { "pcap_path": "/evidence/pcap/capture.pcap" }

// Summarise Suricata alerts
mcp__netparse__suricata_alerts { "eve_json_path": "/evidence/suricata/eve.json" }

// Top talkers
mcp__netparse__pcap_conversations { "pcap_path": "/evidence/pcap/capture.pcap" }

// DNS activity (spot the suspicious lookups)
mcp__netparse__pcap_dns_summary { "pcap_path": "/evidence/pcap/capture.pcap" }

// HTTP hosts and URIs
mcp__netparse__pcap_http_hosts { "pcap_path": "/evidence/pcap/capture.pcap" }
```

The `community_id` field in `eve.json` matches the Community ID in `conn.log`,
so alerts and flows can be correlated across both tools.

---

## Customization

### Swap the victim

Replace `tleemcjr/metasploitable2` in `docker-compose.yml`. Lighter alternatives:

| Image | Services |
|---|---|
| `vulnerables/web-dvwa` | HTTP only (SQLi, XSS, CSRF, LFI) |
| `bkimminich/juice-shop` | HTTP only, OWASP Top 10 coverage |
| `webgoat/webgoat` | Java web app, many categories |

For non-HTTP attacks (FTP/SSH brute force, banner grabs) you'll want a victim
with those services, either Metasploitable2 or a custom multi-service image.

### Add or modify attacks

Edit `attacker/attacks.sh`. The attacker image ships with `nmap`, `nikto`,
`hydra`, `curl`, `wget`, `ncat`, and `python3`. Add more tools in
`attacker/Dockerfile` and rebuild:

```bash
docker compose build attacker
```

### Expand wordlists

`attacker/wordlists/users.txt` and `passwords.txt` are small by design (fast
brute force for sample generation). Replace them with larger lists (e.g.,
`rockyou.txt`) if you want more realistic auth-failure volumes:

```bash
cp /usr/share/wordlists/rockyou.txt attacker/wordlists/passwords.txt
docker compose build attacker
```

### Tune Suricata rules

`sensor/suricata/start.sh` calls `suricata-update` which pulls Emerging Threats
Open rules by default. To add extra rule sources, drop a
`/etc/suricata/update.yaml` into the container or extend `start.sh`:

```bash
suricata-update add-source ptresearch/attackdetection
suricata-update
```

To add custom local rules, append them to
`/var/lib/suricata/rules/suricata.rules` inside `start.sh` before the `exec`.

### Add a Zeek custom policy

Create `sensor/zeek/local.zeek` and mount it into the zeek container:

```yaml
# docker-compose.yml (zeek service)
volumes:
  - ./sensor/zeek/local.zeek:/usr/local/zeek/share/zeek/site/local.zeek:ro
```

### Adjust subnet

If `172.30.0.0/24` conflicts with an existing network, change it in:
- `docker-compose.yml` (labnet subnet + all static IPs)
- `sensor/suricata/suricata.yaml` (`HOME_NET`)

---

## Troubleshooting

### `lab-br0` interface not found — sensors immediately exit

The sensors' wait loops retry for up to ~2 minutes. If they still fail:

```bash
# Check that the labnet was created
docker network ls | grep labnet

# Check that lab-br0 exists on the host
ip link show lab-br0

# If it exists but sensors can't see it, verify they're using host networking
docker compose ps
```

### Metasploitable2 exits immediately

The image needs `privileged: true` (already set). If it still exits:

```bash
docker compose logs victim
```

Metasploitable2 can be slow to appear as healthy — wait a full 60 seconds before
concluding it has failed.

### Suricata starts but fires no alerts

1. Confirm rules loaded: `docker compose logs suricata | grep "rules loaded"`
2. If 0 rules, `suricata-update` may have failed (no internet). Check:
   ```bash
   docker compose logs suricata | grep -i update
   ```
3. Pre-pull rules before running offline:
   ```bash
   docker run --rm \
     -v suricata-rules:/var/lib/suricata/rules \
     jasonish/suricata suricata-update
   ```
   Then add `suricata-rules:/var/lib/suricata/rules` to the suricata service volumes.

### Zeek logs are empty

Zeek writes logs only when it sees traffic. Verify the attacker ran and that
Zeek is on the right interface:

```bash
docker compose logs zeek        # should show "lab-br0" in startup line
wc -l output/zeek/conn.log      # should be > 0 after attacks
```

### Attacker exits before victim is ready

The ping loop has a 120 s timeout. Metasploitable2 typically boots in 30–60 s.
If your machine is slow, increase `TIMEOUT=120` at the top of `attacks.sh` and
rebuild the attacker image.

### Port conflicts on the host

Metasploitable2 ports are **not published** to the host — all services are only
reachable within the `labnet` Docker network. There are no `ports:` mappings in
`docker-compose.yml`, so no host port conflicts should occur.

---

## Security Notes

- **Isolated by design.** No ports from the victim or attacker are published to
  the host. The `labnet` network is a private Docker bridge. External hosts
  cannot reach the victim unless you explicitly add `ports:` mappings.

- **Sensors use `network_mode: host`.** This allows the sensor containers to see
  *all* Docker traffic on the host, not just lab traffic. On a shared machine,
  be aware that sensor captures may include traffic from other Docker networks.

- **`privileged: true` on the victim.** This grants the Metasploitable2
  container elevated kernel capabilities. Only run this lab on a trusted host.

- **Shut down when done.** Don't leave Metasploitable2 running unattended.
  ```bash
  docker compose down
  ```

- **Generated PCAPs contain attack payloads.** Treat `output/` as sensitive
  material. The `.gitignore` excludes all generated output from version control.
