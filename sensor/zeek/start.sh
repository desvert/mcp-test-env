#!/bin/bash
# Wait for the named bridge to appear
until [ -d /sys/class/net/lab-br0 ]; do
    echo "[zeek] Waiting for lab-br0 interface..."
    sleep 2
done

echo "[zeek] Starting Zeek on lab-br0 (logs -> /zeek-logs/)"
exec zeek -i lab-br0 local
