#!/bin/sh
# Wait for the named bridge to appear (created when victim container starts)
until [ -d /sys/class/net/lab-br0 ]; do
    echo "[tcpdump] Waiting for lab-br0 interface..."
    sleep 2
done

mkdir -p /pcap
echo "[tcpdump] Starting capture on lab-br0 -> /pcap/capture.pcap"
exec tcpdump -i lab-br0 -s 0 -n -w /pcap/capture.pcap
