#!/bin/bash
# Wait for the named bridge to appear
until ip link show lab-br0 >/dev/null 2>&1; do
    echo "[suricata] Waiting for lab-br0 interface..."
    sleep 2
done

# Update ET Open rules; don't abort if the host has no internet
echo "[suricata] Running suricata-update..."
suricata-update --no-test 2>&1 || echo "[suricata] Warning: rule update failed — using cached/empty rules"

# Ensure the rules file exists so Suricata doesn't exit on a missing include
mkdir -p /var/lib/suricata/rules
touch /var/lib/suricata/rules/suricata.rules

echo "[suricata] Starting Suricata on lab-br0..."
exec suricata -c /etc/suricata/suricata.yaml -i lab-br0
