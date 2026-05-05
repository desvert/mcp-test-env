# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

---

## [0.2.0] - 2026-05-05

### Added

- **`modbus-sim/`** — new service: Modbus TCP HVAC controller simulator
  - `Dockerfile` — `python:3.12-slim` base, installs `pymodbus==3.13.0`, binds
    port 502 with `NET_BIND_SERVICE` capability (no full root required)
  - `hvac_server.py` — async pymodbus 3.x server simulating a four-register-type
    HVAC device (coils, discrete inputs, holding registers, input registers);
    zone temperature drifts toward setpoint with noise; alarms latch and clear
    via dedicated reset coil; 5-second sensor update loop with structured logging
  - `mbpoll_cheatsheet.txt` — quick-reference commands for reading/writing all
    register types and scripted attack/exercise scenarios (setpoint override,
    actuator lock-out, freeze/overheat simulation)
- **`docker-compose.yml`** — added `modbus-sim` service (172.30.0.30 on labnet,
  `cap_drop: ALL` + `cap_add: NET_BIND_SERVICE`, `PYTHONUNBUFFERED=1`, json-file
  logging with rotation); added `modbus-sim` to `attacker.depends_on` so attack
  traffic begins only after the PLC simulator is ready
- **`attacker/Dockerfile`** — added `mbpoll` to the apt install block for
  Modbus TCP register polling from the attacker container

---

## [0.1.0] - 2026-03-12

### Added

- **`docker-compose.yml`** — five-service Compose stack:
  - `victim` (Metasploitable2, 172.30.0.10) — intentionally vulnerable target
  - `attacker` (ubuntu:22.04, 172.30.0.20) — automated attack runner
  - `tcpdump` (alpine:3.19, host net) — full PCAP capture sensor
  - `suricata` (jasonish/suricata, host net) — IDS with ET Open rules
  - `zeek` (zeek/zeek, host net) — NSM protocol logging
- **Named Docker bridge `lab-br0`** via `com.docker.network.bridge.name` driver
  option, giving sensors a deterministic interface to capture on
- **`attacker/Dockerfile`** — Ubuntu 22.04 base with nmap, nikto, hydra, curl,
  wget, netcat-openbsd, python3, dnsutils, iputils-ping
- **`attacker/attacks.sh`** — 16-phase automated attack script covering:
  port scanning, web scanning, FTP/SSH brute force, HTTP injection (SQLi, LFI,
  XSS, Shellshock), anonymous FTP, DNS lookups, banner grabs, VNC/IRC probes,
  and Tomcat credential brute force
- **`attacker/wordlists/users.txt`** — 10 usernames common to Metasploitable2
- **`attacker/wordlists/passwords.txt`** — 16 passwords including Metasploitable2
  defaults
- **`sensor/tcpdump/Dockerfile`** — minimal Alpine image with tcpdump installed
  at build time
- **`sensor/tcpdump/start.sh`** — waits for `lab-br0`, then captures to
  `output/pcap/capture.pcap` with full snaplen (`-s 0`)
- **`sensor/suricata/start.sh`** — waits for `lab-br0`, runs `suricata-update`
  (with graceful fallback if offline), then launches Suricata
- **`sensor/suricata/suricata.yaml`** — complete Suricata 8 configuration:
  `HOME_NET` set to lab subnet, Community ID enabled in eve-log, HTTP port list
  expanded to include Tomcat (8180), checksum validation disabled for local
  traffic, SSH HASSH fingerprinting enabled, all protocol app-layer parsers
active
- **`sensor/zeek/start.sh`** — waits for `lab-br0`, then runs `zeek -i lab-br0
  local` writing logs to `output/zeek/`
- **`output/`** directory scaffold with `.gitkeep` files for `pcap/`,
  `suricata/`, `zeek/`, and `attacker/` subdirectories
- **`.gitignore`** — excludes all generated runtime artifacts (PCAPs, Suricata
  logs, Zeek logs, nmap/nikto/hydra output, attacker run log) while preserving
  directory structure via `.gitkeep`
- **`README.md`** — full documentation covering architecture rationale, service
  details, startup sequencing, generated output reference, MCP toolchain
  integration guide, customization options, and troubleshooting

[Unreleased]: https://github.com/desvert/mcp-test-env/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/desvert/mcp-test-env/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/desvert/mcp-test-env/releases/tag/v0.1.0