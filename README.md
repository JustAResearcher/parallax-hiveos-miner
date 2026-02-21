# Parallax Solo Miner for HiveOS

Solo mine **Parallax ($LAX)** on HiveOS rigs using **HashWarp** — the official
Parallax GPU miner. Zero dev fee, direct getwork to your node.

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
| **Installation URL** | `https://github.com/JustAResearcher/parallax-hiveos-miner/releases/download/v2.0/parallax-miner-v2.0.tar.gz` |
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
 │  HashWarp            │ getwork │  prlx full node  │
 │  (xhash GPU miner)  ├────────►│  (eth_getWork)   │
 │                      │  HTTP   │  Port 8545       │
 │  CUDA 12 / OpenCL   │◄────────┤  (eth_submitWork) │
 └──────────────────────┘         └──────────────────┘
```

HashWarp connects **directly** to your prlx node via getwork protocol.
No stratum proxy needed — one simple process per rig.

---

## Extra Config Options

The **Extra config argument** field accepts JSON:

```json
{
    "extra_args": "--cl-global-work 4194304 --cl-local-work 256",
    "api_port": 21550
}
```

| Key | Default | Description |
|---|---|---|
| `extra_args` | `""` | Extra HashWarp command line flags |
| `api_port` | `21550` | HashWarp API port (for stats reporting) |

### Useful `extra_args`

| Flag | Description |
|---|---|
| `--cl-devices 0 1 2` | Select specific GPUs (OpenCL) |
| `--cl-global-work 4194304` | Global work size (power of 2, tune for perf) |
| `--cl-local-work 256` | Local work size (64, 128, or 256) |
| `--noeval` | Skip host re-evaluation of nonces (faster submit) |
| `--display-interval 10` | Stats display interval in seconds |
| `--farm-recheck 200` | Getwork polling interval in ms (default 500) |
| `-G` | Force OpenCL only (default: auto-detect) |
| `-v 1` | Verbose stratum messages |

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

| GPU | Build | Status |
|---|---|---|
| RTX 4070 Ti Super | CUDA 12 | Tested, works |
| RTX 4080/4090 | CUDA 12 | Should work (Ada Lovelace) |
| RTX 3060-3090 | CUDA 12 | Should work (Ampere) |
| RTX 5090 | CUDA 12 / OpenCL | Tested with OpenCL |
| AMD RX 6000/7000 | OpenCL | Use OpenCL build |

> **Note:** This package includes the CUDA 12 build for NVIDIA GPUs.
> For AMD GPUs, modify `h-install.sh` to download the OpenCL build instead.

---

## Troubleshooting

### Hashrate shows 0
- Wait 30-60 seconds for DAG generation on first start
- Verify the prlx node is running and accessible: `curl http://YOUR_PC_IP:8545`
- Confirm mining is enabled on the node: `--mine` flag

### "HashWarp not found"
- Check `h-install.sh` ran successfully
- Verify internet connectivity on the rig
- Try reinstalling: `bash /hive/miners/custom/parallax-miner/h-install.sh`

### Rig shows "offline" in HiveOS
- h-stats.sh cannot reach HashWarp API
- Check if HashWarp is running: `screen -r`
- Test API: `echo '{"id":1,"jsonrpc":"2.0","method":"miner_ping"}' | nc 127.0.0.1 21550`

### Connection refused / no work
- Verify prlx node has `--http.addr "0.0.0.0"` (not just localhost)
- Check Windows Firewall allows port 8545 from LAN
- Verify node is synced and mining: `prlx attach --exec "eth.mining"`

---

## Building a Release

On your Windows PC with the repo cloned:

```powershell
.\build_release.ps1 -Version "2.0"
```

This creates `parallax-miner-v2.0.tar.gz` ready for GitHub Releases upload.

---

## File Structure

```
parallax-miner/
├── h-manifest.conf     # HiveOS miner identity
├── h-config.sh         # Generates config from flight sheet
├── h-run.sh            # Launches HashWarp with getwork
├── h-stats.sh          # Reports stats to HiveOS dashboard
├── h-install.sh        # Downloads HashWarp if needed
└── README.md           # This file
```

---

## License

MIT. HashWarp is the official Parallax miner with 0% dev fee.
