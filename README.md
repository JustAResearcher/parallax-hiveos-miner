# Parallax Solo Miner for HiveOS

Solo mine **Parallax ($LAX)** on HiveOS rigs with zero configuration headaches.

Each rig runs a self-contained stratum-to-getwork bridge — just point the flight
sheet at your Parallax full node and start mining.

---

## Quick Setup (3 Steps)

### Step 1 — Parallax Node (Windows PC)

Your Windows PC must run the `prlx` full node with RPC **open to LAN**:

```batch
prlx.exe ^
  --http ^
  --http.api "eth,net,web3,miner" ^
  --http.addr "0.0.0.0" ^
  --http.port 8545 ^
  --mine ^
  --miner.coinbase "YOUR_WALLET_ADDRESS" ^
  --port 32110 ^
  --syncmode "snap"
```

> **Important:** `--http.addr "0.0.0.0"` lets HiveOS rigs reach the RPC.
> Open port **8545** in Windows Firewall for your LAN subnet.

Find your PC's LAN IP:
```
ipconfig | findstr "IPv4"
```

### Step 2 — Create HiveOS Flight Sheet

1. **Workers** → select your rig(s) → **Flight Sheets** tab
2. Click **Add Flight Sheet**
3. Fill in:

| Field | Value |
|---|---|
| **Coin** | `LAX` *(create as custom coin if not listed)* |
| **Wallet** | Your Parallax wallet address, e.g. `0xcae2d6...` |
| **Pool** | *Configure in miner* |
| **Miner** | **Custom** |

4. Click **Setup Miner Config** and fill in the Custom Miner fields:

| Custom Miner Field | Value |
|---|---|
| **Miner name** | `parallax-miner` |
| **Installation URL** | `https://github.com/YOUR_USER/parallax-hiveos-miner/releases/download/v1.0/parallax-miner-v1.0.tar.gz` |
| **Hash algorithm** | `xhash` |
| **Wallet and worker template** | `%WAL%.%WORKER_NAME%` |
| **Pool URL** | `http://YOUR_PC_IP:8545` |
| **Extra config argument** | *(leave empty or see below)* |

5. **Apply** the flight sheet to your rigs

### Step 3 — Verify

In HiveOS dashboard you should see:
- Hashrate reporting per GPU
- Temperatures and fan speeds
- Accepted/rejected share counts

On the Parallax node's console you'll see
`*** BLOCK FOUND! ***` when a rig finds a block.

---

## How It Works

```
  HiveOS Rig                          Windows PC
 ┌──────────────────────┐         ┌──────────────────┐
 │  SRBMiner-Multi      │         │  prlx full node  │
 │    (xhash GPU miner) │         │  (eth_getWork)   │
 │         │             │         │       ▲          │
 │         ▼             │  HTTP   │       │          │
 │  Stratum Proxy ───────┼────────►│  Port 8545      │
 │  (embedded, auto)     │         │                  │
 └──────────────────────┘         └──────────────────┘
```

Each HiveOS rig runs:
1. **Stratum proxy** (Python, embedded) — translates stratum → getwork
2. **SRBMiner-Multi** — GPU mining via local stratum proxy

The proxy polls `eth_getWork` from your prlx node and pushes work to SRBMiner
via stratum protocol. Solutions are forwarded back via `eth_submitWork`.

---

## Extra Config Options

The **Extra config argument** field accepts JSON:

```json
{
    "extra_args": "--gpu-id 0,1 --gpu-intensity 25",
    "api_port": 21550,
    "proxy_port": 4444
}
```

| Key | Default | Description |
|---|---|---|
| `extra_args` | `""` | Extra SRBMiner command line flags |
| `api_port` | `21550` | SRBMiner API port (for stats) |
| `proxy_port` | `4444` | Local stratum proxy port |

### Useful `extra_args`

| Flag | Description |
|---|---|
| `--gpu-id 0,1,2` | Select specific GPUs |
| `--gpu-intensity 25` | Adjust intensity (higher = more hash, more power) |
| `--gpu-boost 1` | Enable GPU boost |
| `--log-file srbminer.log` | Log to file |

---

## Alternative: Direct Stratum Mode

If you prefer running a **centralized stratum proxy** on your Windows PC
(instead of one per rig), set the **Pool URL** to the proxy address:

| Field | Value |
|---|---|
| **Pool URL** | `192.168.68.78:4444` |

In this mode, no per-rig proxy is started — SRBMiner connects directly.

You must run `xhash_stratum_proxy.py` on your Windows PC separately:
```
python xhash_stratum_proxy.py --rpc-url http://127.0.0.1:8545 --port 4444
```

---

## Windows Firewall Setup

Allow HiveOS rigs to reach prlx RPC (run as Administrator):

```powershell
New-NetFirewallRule -DisplayName "Parallax RPC (LAN)" `
  -Direction Inbound -Protocol TCP -LocalPort 8545 `
  -RemoteAddress 192.168.0.0/16 -Action Allow
```

---

## Supported GPUs

| GPU | Status |
|---|---|
| RTX 4070 Ti Super | Tested, works great |
| RTX 4080/4090 | Should work (Ada Lovelace) |
| RTX 3060-3090 | Should work (Ampere) |
| RTX 5090 | Use HashWarp instead (SRBMiner kernel issue on Blackwell) |
| AMD RX 6000/7000 | Should work with SRBMiner OpenCL |

---

## Troubleshooting

### "Stratum proxy failed to start"
- Check that your prlx node is running
- Verify the Pool URL is correct (e.g., `http://192.168.68.78:8545`)
- Make sure port 8545 is open in Windows Firewall
- Confirm mining is enabled: `prlx attach --exec "miner.start(1)"`

### Hashrate shows 0
- Wait 30-60 seconds for DAG generation
- Check `proxy.log` on the rig: `cat /hive/miners/custom/parallax-miner/proxy.log`
- Verify the prlx node has `--mine` flag and mining is active

### "SRBMiner not found"
- HiveOS usually has SRBMiner pre-installed
- If not, install via HiveOS: **Workers** → **Miners** → install SRBMiner-Multi
- Or let `h-install.sh` download it automatically

### Rig shows "offline" in HiveOS
- This means h-stats.sh cannot read SRBMiner API
- Check if SRBMiner is actually running: `screen -r`
- Verify API port with: `curl http://127.0.0.1:21550`

---

## Building a Release

On your Windows PC with the repo cloned:

```powershell
.\build_release.ps1
```

This creates `parallax-miner-v1.0.tar.gz` ready for GitHub Releases upload.

---

## File Structure

```
parallax-miner/
├── h-manifest.conf          # HiveOS miner identity
├── h-config.sh              # Generates config from flight sheet
├── h-run.sh                 # Starts proxy + SRBMiner
├── h-stats.sh               # Reports stats to HiveOS dashboard
├── h-install.sh             # Downloads SRBMiner if needed
├── xhash_stratum_proxy.py   # Stratum-to-getwork bridge
└── README.md                # This file
```

---

## License

MIT. The stratum proxy and HiveOS integration scripts are open source.
SRBMiner-Multi has a 3% dev fee on xhash.
