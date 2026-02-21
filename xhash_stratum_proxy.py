#!/usr/bin/env python3
"""
Parallax XHash Stratum-to-Getwork Proxy
========================================

Bridges GPU miners that speak Stratum (SRBMiner-Multi, etc.)
to a Parallax (prlx) full node that speaks HTTP getwork (eth_getWork).

Supports two Ethash stratum variants:
  - EthProxy:    eth_submitLogin / eth_getWork / eth_submitWork / mining.notify
  - Stratum v1:  mining.subscribe / mining.authorize / mining.submit / mining.notify

The proxy:
  1. Listens for TCP stratum connections from GPU miners
  2. Polls the prlx node's eth_getWork RPC for new work
  3. Distributes work to connected miners as stratum notifications
  4. Forwards solutions back to the node via eth_submitWork

Usage:
    python3 xhash_stratum_proxy.py [options]

    Options:
        --rpc-url       prlx node RPC URL        (default: http://127.0.0.1:8545)
        --host          Stratum listen host       (default: 0.0.0.0)
        --port          Stratum listen port       (default: 4444)
        --poll          Work poll interval (s)    (default: 0.5)
        --log-level     DEBUG / INFO / WARNING    (default: INFO)
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import time
import traceback
import urllib.request
import urllib.error
from typing import Any, Dict, List, Optional

log = logging.getLogger("xhash-proxy")


# ---------------------------------------------------------------------------
# Node RPC client
# ---------------------------------------------------------------------------

class NodeRPC:
    """Minimal HTTP JSON-RPC 2.0 client for prlx / geth."""

    def __init__(self, url: str):
        self.url = url
        self._id = 0

    def call(self, method: str, params: list | None = None) -> Any:
        self._id += 1
        body = json.dumps({
            "jsonrpc": "2.0",
            "id": self._id,
            "method": method,
            "params": params or [],
        }).encode()
        req = urllib.request.Request(
            self.url,
            data=body,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        if data.get("error"):
            raise RuntimeError(f"RPC {method}: {data['error']}")
        return data.get("result")

    def get_work(self) -> list | None:
        """Returns [headerHash, seedHash, boundary] or None on failure."""
        try:
            return self.call("eth_getWork")
        except Exception as e:
            log.error("eth_getWork failed: %s", e)
            return None

    def submit_work(self, nonce: str, header_hash: str, mix_digest: str) -> bool:
        """Submit a mining solution.  Returns True if accepted."""
        return self.call("eth_submitWork", [nonce, header_hash, mix_digest])

    def submit_hashrate(self, rate_hex: str, client_id: str) -> bool:
        return self.call("eth_submitHashrate", [rate_hex, client_id])

    def block_number(self) -> int:
        result = self.call("eth_blockNumber")
        return int(result, 16) if isinstance(result, str) else int(result)

    def mining_active(self) -> bool:
        return self.call("eth_mining")


# ---------------------------------------------------------------------------
# Job tracking
# ---------------------------------------------------------------------------

class Job:
    __slots__ = ("job_id", "header_hash", "seed_hash", "boundary", "created")

    def __init__(self, job_id: str, header_hash: str, seed_hash: str, boundary: str):
        self.job_id = job_id
        self.header_hash = header_hash
        self.seed_hash = seed_hash
        self.boundary = boundary
        self.created = time.time()


class JobManager:
    """Polls eth_getWork and tracks active jobs."""

    def __init__(self, rpc: NodeRPC):
        self.rpc = rpc
        self.jobs: Dict[str, Job] = {}
        self.current_job: Optional[Job] = None
        self._counter = 0
        self._by_header: Dict[str, Job] = {}

    def poll_work(self) -> Optional[Job]:
        """Check for new work.  Returns a Job if the header changed, else None."""
        result = self.rpc.get_work()
        if not result or len(result) < 3:
            return None

        header_hash = result[0]
        seed_hash = result[1]
        boundary = result[2]

        if self.current_job and self.current_job.header_hash == header_hash:
            return None

        self._counter += 1
        job_id = hex(self._counter)

        job = Job(job_id, header_hash, seed_hash, boundary)
        self.jobs[job_id] = job
        self._by_header[header_hash.lower()] = job
        self.current_job = job

        # Prune old jobs (keep last 20)
        if len(self.jobs) > 20:
            old_ids = sorted(self.jobs.keys(), key=lambda x: int(x, 16))[:-20]
            for oid in old_ids:
                j = self.jobs.pop(oid, None)
                if j:
                    self._by_header.pop(j.header_hash.lower(), None)

        return job

    def find_job(self, job_id: str = None, header_hash: str = None) -> Optional[Job]:
        """Look up a job by job_id (Stratum) or header_hash (EthProxy)."""
        if job_id and job_id in self.jobs:
            return self.jobs[job_id]
        if header_hash:
            return self._by_header.get(header_hash.lower())
        return None

    def submit_solution(self, nonce: str, header_hash: str, mix_digest: str) -> str:
        """Forward solution to node.  Returns 'accepted', 'rejected', or error."""
        if not nonce.startswith("0x"):
            nonce = "0x" + nonce
        if not header_hash.startswith("0x"):
            header_hash = "0x" + header_hash
        if not mix_digest.startswith("0x"):
            mix_digest = "0x" + mix_digest

        try:
            ok = self.rpc.submit_work(nonce, header_hash, mix_digest)
            if ok:
                log.info("*** BLOCK FOUND! *** nonce=%s header=%s", nonce, header_hash[:18])
                return "accepted"
            else:
                log.warning("Solution REJECTED by node  nonce=%s", nonce)
                return "rejected"
        except Exception as e:
            log.error("eth_submitWork error: %s", e)
            return f"error: {e}"


# ---------------------------------------------------------------------------
# Miner session (one TCP connection)
# ---------------------------------------------------------------------------

class MinerSession:
    """Handles a single stratum miner connection.
    Auto-detects EthProxy vs Stratum v1 based on the first message."""

    def __init__(self, reader, writer, job_manager: JobManager, on_disconnect):
        self.reader = reader
        self.writer = writer
        self.job_manager = job_manager
        self.on_disconnect = on_disconnect
        self.peer = writer.get_extra_info("peername")
        self.authorized = False
        self.worker_name = "unknown"
        self.protocol = "unknown"
        self._closed = False
        self.shares_accepted = 0
        self.shares_rejected = 0

    async def run(self):
        log.info("Miner connected: %s", self.peer)
        try:
            while not self._closed:
                line = await self.reader.readline()
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line.decode("utf-8", errors="replace"))
                except json.JSONDecodeError:
                    log.warning("Bad JSON from %s: %s", self.peer, line[:200])
                    continue
                await self._dispatch(msg)
        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            pass
        except Exception:
            log.error("Session error (%s):\n%s", self.peer, traceback.format_exc())
        finally:
            await self.close()
            log.info(
                "Miner disconnected: %s  (accepted=%d rejected=%d)",
                self.peer, self.shares_accepted, self.shares_rejected,
            )
            self.on_disconnect(self)

    async def _dispatch(self, msg: dict):
        method = msg.get("method", "")
        msg_id = msg.get("id")
        params = msg.get("params", [])

        log.debug("<- %s  id=%s  params=%s", method, msg_id, params)

        # EthProxy methods
        if method == "eth_submitLogin":
            await self._ethproxy_login(msg_id, params)
        elif method == "eth_getWork":
            await self._ethproxy_getwork(msg_id)
        elif method == "eth_submitWork":
            await self._ethproxy_submitwork(msg_id, params)
        elif method == "eth_submitHashrate":
            await self._ethproxy_hashrate(msg_id, params)
        # Standard Stratum methods
        elif method == "mining.subscribe":
            await self._stratum_subscribe(msg_id, params)
        elif method == "mining.authorize":
            await self._stratum_authorize(msg_id, params)
        elif method == "mining.submit":
            await self._stratum_submit(msg_id, params)
        elif method == "mining.extranonce.subscribe":
            await self._send_result(msg_id, True)
        else:
            log.debug("Unknown method from %s: %s", self.peer, method)
            await self._send_result(msg_id, True)

    # -- EthProxy handlers --

    async def _ethproxy_login(self, msg_id, params):
        self.protocol = "ethproxy"
        self.worker_name = params[0] if params else "unknown"
        self.authorized = True
        log.info("EthProxy login: %s (%s)", self.worker_name, self.peer)
        await self._send_result(msg_id, True)

    async def _ethproxy_getwork(self, msg_id):
        job = self.job_manager.current_job
        if job:
            await self._send_result(msg_id, [
                job.header_hash, job.seed_hash, job.boundary,
            ])
        else:
            await self._send_error(msg_id, -1, "No work available yet")

    async def _ethproxy_submitwork(self, msg_id, params):
        if len(params) < 3:
            await self._send_error(msg_id, -1, "Need [nonce, headerHash, mixDigest]")
            return
        nonce, header_hash, mix_digest = params[0], params[1], params[2]
        log.info("EthProxy submit: nonce=%s header=%s...%s",
                 nonce, header_hash[:10], header_hash[-4:])
        result = self.job_manager.submit_solution(nonce, header_hash, mix_digest)
        if result == "accepted":
            self.shares_accepted += 1
            await self._send_result(msg_id, True)
        else:
            self.shares_rejected += 1
            await self._send_error(msg_id, -1, f"Rejected: {result}")

    async def _ethproxy_hashrate(self, msg_id, params):
        if len(params) >= 2:
            try:
                self.job_manager.rpc.submit_hashrate(params[0], params[1])
            except Exception:
                pass
        await self._send_result(msg_id, True)

    # -- Stratum handlers --

    async def _stratum_subscribe(self, msg_id, params):
        self.protocol = "stratum"
        agent = params[0] if params else "unknown"
        log.info("Stratum subscribe: %s (%s)", agent, self.peer)
        result = [
            [["mining.notify", "xhash_proxy"]],
            "",
            "0",
        ]
        await self._send_result(msg_id, result)
        if self.job_manager.current_job:
            await self.send_stratum_job(self.job_manager.current_job, clean=True)

    async def _stratum_authorize(self, msg_id, params):
        self.worker_name = params[0] if params else "unknown"
        self.authorized = True
        log.info("Stratum authorized: %s (%s)", self.worker_name, self.peer)
        await self._send_result(msg_id, True)
        if self.job_manager.current_job:
            await self.send_stratum_job(self.job_manager.current_job, clean=True)

    async def _stratum_submit(self, msg_id, params):
        if not self.authorized:
            await self._send_error(msg_id, 24, "Not authorized")
            return
        if len(params) < 3:
            await self._send_error(msg_id, 21, "Not enough parameters")
            return

        worker = params[0]
        job_id = params[1]
        nonce = params[2]

        job = self.job_manager.find_job(job_id=job_id)

        if len(params) >= 5:
            header_hash = params[3]
            mix_digest = params[4]
        elif len(params) >= 4:
            mix_digest = params[3]
            header_hash = job.header_hash if job else None
        else:
            header_hash = job.header_hash if job else None
            mix_digest = None

        if not header_hash or not mix_digest:
            if not job:
                await self._send_error(msg_id, 21, "Job not found, can't reconstruct submission")
                return
            log.warning("Submit with incomplete params - may be rejected")

        log.info("Stratum submit: worker=%s job=%s nonce=%s", worker, job_id, nonce)
        result = self.job_manager.submit_solution(nonce, header_hash, mix_digest)

        if result == "accepted":
            self.shares_accepted += 1
            await self._send_result(msg_id, True)
        elif result == "job-not-found":
            self.shares_rejected += 1
            await self._send_error(msg_id, 21, "Job not found (stale)")
        else:
            self.shares_rejected += 1
            await self._send_error(msg_id, 20, f"Rejected: {result}")

    # -- Push work to miner --

    async def send_new_work(self, job: Job, clean: bool = True):
        if self.protocol == "ethproxy":
            await self.send_ethproxy_job(job)
        else:
            await self.send_stratum_job(job, clean)

    async def send_ethproxy_job(self, job: Job):
        await self._send_notification("mining.notify", [
            job.header_hash, job.seed_hash, job.boundary,
        ])

    async def send_stratum_job(self, job: Job, clean: bool = True):
        boundary_int = int(job.boundary, 16) if job.boundary else 1
        difficulty = (2**256 - 1) / boundary_int if boundary_int > 0 else 1.0
        await self._send_notification("mining.set_difficulty", [difficulty])
        await self._send_notification("mining.notify", [
            job.job_id, job.seed_hash, job.header_hash, clean,
        ])

    # -- Wire protocol --

    async def _send_result(self, msg_id, result):
        await self._send_json({"id": msg_id, "result": result, "error": None})

    async def _send_error(self, msg_id, code: int, message: str):
        await self._send_json({"id": msg_id, "result": None, "error": [code, message, None]})

    async def _send_notification(self, method: str, params):
        await self._send_json({"id": None, "method": method, "params": params})

    async def _send_json(self, obj: dict):
        if self._closed:
            return
        try:
            line = json.dumps(obj) + "\n"
            self.writer.write(line.encode("utf-8"))
            await self.writer.drain()
            log.debug("-> %s", line.strip())
        except (ConnectionResetError, BrokenPipeError, OSError):
            self._closed = True

    async def close(self):
        if not self._closed:
            self._closed = True
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Stratum server
# ---------------------------------------------------------------------------

class StratumProxy:
    def __init__(self, rpc_url: str, host: str, port: int, poll_interval: float):
        self.rpc = NodeRPC(rpc_url)
        self.job_manager = JobManager(self.rpc)
        self.host = host
        self.port = port
        self.poll_interval = poll_interval
        self.sessions: List[MinerSession] = []

    async def start(self):
        server = await asyncio.start_server(
            self._on_connect, self.host, self.port,
        )
        addr = server.sockets[0].getsockname()
        log.info("Stratum proxy listening on %s:%d", addr[0], addr[1])
        asyncio.create_task(self._poll_loop())
        async with server:
            await server.serve_forever()

    async def _on_connect(self, reader, writer):
        session = MinerSession(reader, writer, self.job_manager, self._on_disconnect)
        self.sessions.append(session)
        await session.run()

    def _on_disconnect(self, session: MinerSession):
        if session in self.sessions:
            self.sessions.remove(session)

    async def _poll_loop(self):
        consecutive_errors = 0
        while True:
            try:
                job = await asyncio.get_event_loop().run_in_executor(
                    None, self.job_manager.poll_work,
                )
                if job:
                    n_miners = sum(1 for s in self.sessions if s.authorized)
                    log.info(
                        "New work: job=%s  header=%s...%s  -> %d miner(s)",
                        job.job_id,
                        job.header_hash[:10], job.header_hash[-6:],
                        n_miners,
                    )
                    await self._broadcast(job)
                consecutive_errors = 0
            except Exception:
                consecutive_errors += 1
                if consecutive_errors <= 3 or consecutive_errors % 30 == 0:
                    log.error("Poll error (#%d): %s", consecutive_errors,
                              traceback.format_exc())
            await asyncio.sleep(self.poll_interval)

    async def _broadcast(self, job: Job):
        for session in list(self.sessions):
            if not session._closed:
                try:
                    await session.send_new_work(job, clean=True)
                except Exception:
                    pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Parallax XHash Stratum-to-Getwork Proxy"
    )
    parser.add_argument("--rpc-url", default="http://127.0.0.1:8545",
                        help="prlx node HTTP RPC URL")
    parser.add_argument("--host", default="0.0.0.0",
                        help="Stratum listen host (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=4444,
                        help="Stratum listen port (default: 4444)")
    parser.add_argument("--poll", type=float, default=0.5,
                        help="Work poll interval in seconds (default: 0.5)")
    parser.add_argument("--log-level", default="INFO",
                        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
                        help="Logging level (default: INFO)")
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s [%(levelname)-5s] %(message)s",
        datefmt="%H:%M:%S",
    )

    # Verify node connectivity
    rpc = NodeRPC(args.rpc_url)
    try:
        block_num = rpc.block_number()
        mining = rpc.mining_active()
        work = rpc.get_work()
        log.info("Node OK - block=%d  mining=%s  getWork=%s",
                 block_num, mining, "available" if work else "NOT AVAILABLE")
        if not work:
            log.warning("eth_getWork returned nothing - is mining enabled?")
    except Exception as e:
        log.error("Cannot connect to prlx node at %s: %s", args.rpc_url, e)
        log.error("Make sure prlx is running with --http and --mine flags")
        sys.exit(1)

    log.info("Parallax XHash Stratum Proxy")
    log.info("  Node RPC: %s", args.rpc_url)
    log.info("  Stratum:  %s:%d", args.host, args.port)
    log.info("  Poll:     %.1fs", args.poll)

    proxy = StratumProxy(args.rpc_url, args.host, args.port, args.poll)
    try:
        asyncio.run(proxy.start())
    except KeyboardInterrupt:
        log.info("Proxy stopped.")


if __name__ == "__main__":
    main()
