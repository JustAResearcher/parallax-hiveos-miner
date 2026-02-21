#!/usr/bin/env bash
###############################################################################
# Parallax Miner for HiveOS — Stats Reporter
#
# Queries SRBMiner-Multi API and outputs HiveOS-compatible JSON stats.
# Called periodically by HiveOS to display hashrate, temps, fans, shares.
###############################################################################

MINER_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MINER_DIR"

# Default stats (returned on any error)
EMPTY='{"hs":[],"hs_units":"hs","temp":[],"fan":[],"uptime":0,"ver":"0","ar":[0,0],"algo":"xhash"}'

# Read API port from config
API_PORT=$(jq -r '.api_port // 21550' config.json 2>/dev/null)
[[ -z "$API_PORT" || "$API_PORT" == "null" ]] && API_PORT=21550

# Query SRBMiner API
stats_raw=$(curl -s --connect-timeout 2 --max-time 5 "http://127.0.0.1:${API_PORT}" 2>/dev/null)

if [[ -z "$stats_raw" || "$stats_raw" == "null" ]]; then
    echo "$EMPTY"
    exit 0
fi

# Parse with Python3 for robust JSON handling
echo "$stats_raw" | python3 -c "
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print(json.dumps({'hs':[],'hs_units':'hs','temp':[],'fan':[],'uptime':0,'ver':'0','ar':[0,0],'algo':'xhash'}))
    sys.exit(0)

hs   = []
temp = []
fan  = []
bus  = []

# ── Parse per-GPU stats from algorithms[0].devices[] (SRBMiner 2.x+) ────────
algos = data.get('algorithms', [])
if algos:
    for d in algos[0].get('devices', []):
        hs.append(d.get('hashrate', 0))
        temp.append(d.get('core_temperature', 0))
        fan.append(d.get('fan_speed_percentage', 0))
        bid = str(d.get('bus_id', '0'))
        try:
            bus.append(int(bid.split(':')[0], 16) if ':' in bid else int(bid))
        except (ValueError, IndexError):
            bus.append(0)

# ── Fallback: top-level devices[] ────────────────────────────────────────────
if not hs:
    for d in data.get('devices', []):
        hs.append(d.get('hashrate', 0))
        temp.append(d.get('temperature', d.get('core_temperature', 0)))
        fan.append(d.get('fan_speed', d.get('fan_speed_percentage', 0)))
        bid = str(d.get('bus_id', '0'))
        try:
            bus.append(int(bid.split(':')[0], 16) if ':' in bid else int(bid))
        except (ValueError, IndexError):
            bus.append(0)

# ── Uptime, version, shares ─────────────────────────────────────────────────
uptime = data.get('mining_time', data.get('uptime', 0))
ver    = str(data.get('version', 'unknown'))
shares = data.get('shares', {})
acc    = shares.get('accepted', 0)
rej    = shares.get('rejected', 0) + shares.get('invalid', 0)

result = {
    'hs':          hs,
    'hs_units':    'hs',
    'temp':        temp,
    'fan':         fan,
    'uptime':      uptime,
    'ver':         ver,
    'ar':          [acc, rej],
    'algo':        'xhash',
    'bus_numbers': bus,
}

print(json.dumps(result))
"
