#!/usr/bin/env bash
###############################################################################
# Parallax Miner for HiveOS — Stats Reporter  (v2.0 — HashWarp)
#
# Queries HashWarp's ethminer-compatible JSON-RPC API and outputs
# HiveOS-compatible JSON stats (hashrate, temps, fans, shares).
# Called periodically by HiveOS to display mining statistics.
###############################################################################

MINER_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MINER_DIR"

# Default stats (returned on any error)
EMPTY='{"hs":[],"hs_units":"hs","temp":[],"fan":[],"uptime":0,"ver":"0","ar":[0,0],"algo":"xhash"}'

# Read API port from config
API_PORT=$(jq -r '.api_port // 21550' config.json 2>/dev/null)
[[ -z "$API_PORT" || "$API_PORT" == "null" ]] && API_PORT=21550

# Query HashWarp API via JSON-RPC and parse results with Python3
python3 -c "
import socket, json, sys

API_PORT = ${API_PORT}
EMPTY = {'hs':[],'hs_units':'hs','temp':[],'fan':[],'uptime':0,'ver':'0','ar':[0,0],'algo':'xhash'}

def query_api(method):
    '''Send a JSON-RPC request to HashWarp API over TCP.'''
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(('127.0.0.1', API_PORT))
    req = json.dumps({'id': 1, 'jsonrpc': '2.0', 'method': method}) + '\n'
    s.sendall(req.encode())
    data = b''
    while True:
        try:
            chunk = s.recv(8192)
            if not chunk:
                break
            data += chunk
            # Check if we have a complete JSON response
            try:
                json.loads(data)
                break
            except json.JSONDecodeError:
                continue
        except socket.timeout:
            break
    s.close()
    return json.loads(data)

try:
    resp = query_api('miner_getstatdetail')
    result = resp.get('result', {})

    devices = result.get('devices', [])
    host = result.get('host', {})
    mining = result.get('mining', {})

    hs   = []
    temp = []
    fan  = []
    bus  = []

    for d in devices:
        # Hashrate is a hex string like '0x0000000000e3fcbb' (hashes/sec)
        hr_hex = d.get('mining', {}).get('hashrate', '0x0')
        hs.append(int(hr_hex, 16))

        # Sensors: [temperature, fan_percent, power_watts]  (requires --HWMON 1)
        sensors = d.get('hardware', {}).get('sensors', [0, 0, 0])
        temp.append(sensors[0] if len(sensors) > 0 else 0)
        fan.append(sensors[1] if len(sensors) > 1 else 0)

        # PCI bus ID: '01:00.0' → bus number 1
        pci = d.get('hardware', {}).get('pci', '00:00.0')
        try:
            bus.append(int(pci.split(':')[0], 16))
        except (ValueError, IndexError):
            bus.append(0)

    # Shares: [found, rejected, failed, time_since_last_share]
    shares = mining.get('shares', [0, 0, 0, 0])
    acc = shares[0] if len(shares) > 0 else 0
    rej = shares[1] if len(shares) > 1 else 0

    # Uptime in seconds, version string
    uptime = host.get('runtime', 0)
    ver = host.get('version', 'unknown')
    # Clean version: 'hashwarp 1.2.0+commit.94e76b5b' → '1.2.0'
    if 'hashwarp' in ver.lower():
        ver = ver.split()[-1] if ' ' in ver else ver
    if '+' in ver:
        ver = ver.split('+')[0]

    print(json.dumps({
        'hs':          hs,
        'hs_units':    'hs',
        'temp':        temp,
        'fan':         fan,
        'uptime':      uptime,
        'ver':         ver,
        'ar':          [acc, rej],
        'algo':        'xhash',
        'bus_numbers': bus,
    }))

except Exception:
    print(json.dumps(EMPTY))
"
