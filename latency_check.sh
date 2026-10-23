#!/bin/bash
# latency_check.sh - where does ping time to a Radmin peer go?
# Usage (with run_macos.sh up, in another terminal):
#   ./latency_check.sh <peer 26.x address> [pings]
#
# Pings the peer and captures packets in two places at once: on feth26, where
# the ping enters our stack, and on the uplink (Wi-Fi/Ethernet), where Radmin's
# encrypted datagram for it leaves. Matching the two by time splits the RTT:
#   out    — feth26 → bridge → Wine driver → Radmin → uplink   (our stack, Mac→peer)
#   net    — uplink → peer's whole Radmin stack → uplink       (internet + their side)
#   in     — uplink → Radmin → Wine driver → bridge → feth26   (our stack, peer→Mac)
# Needs sudo for tcpdump.
set -euo pipefail

PEER="${1:-}"
COUNT="${2:-40}"
[[ "$PEER" =~ ^26\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <peer 26.x address> [pings]" >&2; exit 1; }
[[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "pings must be a number" >&2; exit 1; }
ifconfig feth26 >/dev/null 2>&1 || { echo "feth26 not found — start ./run_macos.sh first" >&2; exit 1; }

UPLINK=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2; exit}')
[ -n "$UPLINK" ] || { echo "no default route" >&2; exit 1; }
case "$UPLINK" in utun*|feth*) echo "warning: the default route goes through $UPLINK (another VPN?) — Radmin's traffic may not be visible there" >&2 ;; esac

TMP=$(mktemp -d)
trap 'sudo kill $P1 $P2 2>/dev/null || true; rm -rf "$TMP"' EXIT

sudo -v
echo "Capturing on feth26 and $UPLINK, pinging $PEER x$COUNT..."
sudo tcpdump -i feth26 -n -tt -l -B 4096 "icmp and host $PEER" > "$TMP/vpn" 2>/dev/null & P1=$!
# Radmin's peer traffic on the uplink; skip the obvious other talkers.
sudo tcpdump -i "$UPLINK" -n -tt -l -B 4096 \
    "(udp or tcp) and not port 53 and not port 5353 and not port 443 and not port 80" > "$TMP/wan" 2>/dev/null & P2=$!
sleep 1.5
ping -c "$COUNT" -i 0.5 "$PEER" > "$TMP/ping" || true
sleep 1
sudo kill $P1 $P2 2>/dev/null || true
wait 2>/dev/null || true

LOCAL_IP=$(ipconfig getifaddr "$UPLINK" 2>/dev/null || true)
python3 - "$TMP/vpn" "$TMP/wan" "$TMP/ping" "$LOCAL_IP" <<'EOF'
import re, sys, statistics
vpn_f, wan_f, ping_f, local_ip = sys.argv[1:5]

req, rep = [], []                      # timestamps on feth26
for line in open(vpn_f):
    m = re.match(r'(\d+\.\d+) IP ([\d.]+) > ([\d.]+): ICMP echo (request|reply)', line)
    if m: (req if m.group(4) == 'request' else rep).append(float(m.group(1)))

out_pk, in_pk = [], []                 # (ts, remote endpoint) on the uplink
for line in open(wan_f):
    m = re.match(r'(\d+\.\d+) IP ([\d.]+)\.(\d+) > ([\d.]+)\.(\d+):', line)
    if not m: continue
    ts, src, dst = float(m.group(1)), m.group(2), m.group(4)
    if local_ip and src == local_ip:   out_pk.append((ts, f'{dst}:{m.group(5)}'))
    elif local_ip and dst == local_ip: in_pk.append((ts, f'{src}:{m.group(3)}'))

WIN = 0.08   # a frame must cross our stack within 80 ms to be matched
def first_after(pk, t, ep=None):
    c = [p for p in pk if t <= p[0] <= t + WIN and (ep is None or p[1] == ep)]
    return min(c) if c else None
def last_before(pk, t, ep=None):
    c = [p for p in pk if t - WIN <= p[0] <= t and (ep is None or p[1] == ep)]
    return max(c) if c else None

# The peer's endpoint: the remote that most often both follows an echo request
# (outgoing) and precedes its reply (incoming). Other traffic rarely does both.
def pairs():
    for t_req in req:
        reps = [r for r in rep if t_req < r < t_req + 2]
        if reps: yield t_req, reps[0]
cands = {p[1] for p in out_pk}
votes = {}
for t_req, t_rep in pairs():
    for ep_c in cands:
        if first_after(out_pk, t_req, ep_c) and last_before(in_pk, t_rep, ep_c):
            votes[ep_c] = votes.get(ep_c, 0) + 1
if not votes:
    sys.exit("No Radmin packets matched on the uplink — is the peer online and connected directly (not via relay)?")
ep = max(votes, key=votes.get)

outs, ins, nets = [], [], []
for t_req in req:
    o = first_after(out_pk, t_req, ep)
    if not o: continue
    reps = [r for r in rep if t_req < r < t_req + 2]
    if not reps: continue
    t_rep = reps[0]
    i = last_before(in_pk, t_rep, ep)
    if not i or i[0] < o[0]: continue
    outs.append((o[0] - t_req) * 1000); ins.append((t_rep - i[0]) * 1000); nets.append((i[0] - o[0]) * 1000)

rtts = [float(x) for x in re.findall(r'time=([\d.]+) ms', open(ping_f).read())]
def s(v): return f"median {statistics.median(v):6.2f} ms   p90 {sorted(v)[int(len(v)*0.9)-1 if len(v)>1 else 0]:6.2f} ms"
print(f"\npeer endpoint on the internet: {ep}   matched {len(outs)} of {len(req)} pings")
if rtts: print(f"ping RTT (total)        : {s(rtts)}   loss {100 - 100*len(rtts)//max(len(req),1)}%")
if outs:
    print(f"our stack, Mac → peer   : {s(outs)}")
    print(f"our stack, peer → Mac   : {s(ins)}")
    print(f"internet + peer's side  : {s(nets)}")
    ours = statistics.median(outs) + statistics.median(ins)
    print(f"\nour side adds ~{ours:.1f} ms of the ~{statistics.median(rtts) if rtts else 0:.1f} ms round trip")
EOF
