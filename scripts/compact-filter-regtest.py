#!/usr/bin/env python3
"""Exercise LDK's direct-peer wallet with unrelated and relevant regtest blocks."""
import re
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "crates/pq-light-client/target/debug/pq-light-client"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    with tempfile.TemporaryDirectory(prefix="winnow-compact-filter-") as directory:
        fixture = Path(directory)
        bitcoin_dir = fixture / "bitcoin"
        bitcoin_dir.mkdir()
        client_dir = fixture / "client"
        rpc_port, p2p_port, listen_port = (free_port() for _ in range(3))

        def btc(*args):
            return subprocess.check_output(
                ["bitcoin-cli", f"-datadir={bitcoin_dir}", "-regtest", f"-rpcport={rpc_port}", *args],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()

        def run_client(commands):
            log = client_dir / "node/ldk_node.log"
            old_syncs = log.read_text(errors="ignore").count("Direct Bitcoin peer initial sync complete") if log.exists() else 0
            process = subprocess.Popen(
                [str(CLIENT), str(client_dir), f"127.0.0.1:{p2p_port}", f"127.0.0.1:{listen_port}"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            try:
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f"client exited during sync: {process.stdout.read()}")
                    if log.exists() and log.read_text(errors="ignore").count("Direct Bitcoin peer initial sync complete") > old_syncs:
                        break
                    time.sleep(0.25)
                else:
                    raise RuntimeError("client initial sync timed out")
                output, _ = process.communicate(commands, timeout=90)
                if process.returncode:
                    raise RuntimeError(f"client exited with {process.returncode}: {output}")
                return output, log.read_text(errors="ignore")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

        subprocess.run([
            "bitcoind", f"-datadir={bitcoin_dir}", "-regtest", "-server=1", "-listen=1",
            "-bind=127.0.0.1", "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1",
            f"-rpcport={rpc_port}", f"-port={p2p_port}", "-blockfilterindex=1",
            "-peerblockfilters=1", "-fallbackfee=0.0001", "-daemon",
        ], check=True, stdout=subprocess.DEVNULL)
        try:
            for _ in range(60):
                try:
                    btc("getblockchaininfo")
                    break
                except subprocess.CalledProcessError:
                    time.sleep(0.25)
            else:
                raise RuntimeError("bitcoind did not start")
            btc("createwallet", "mine")
            mine_address = btc("getnewaddress")
            btc("generatetoaddress", "101", mine_address)

            output, log = run_client("address\nsync\nbalance\nquit\n")
            address = re.search(r"bcrt1[0-9a-z]{20,}", output)
            assert address, output
            counts = re.findall(r"Bitcoin compact filters: (\d+) header-only blocks, (\d+) full blocks downloaded", log)
            assert counts and int(counts[-1][0]) >= 100 and int(counts[-1][1]) == 0, counts

            btc("generatetoaddress", "3", mine_address)
            btc("sendtoaddress", address.group(), "0.00200000")
            btc("generatetoaddress", "1", mine_address)
            output, log = run_client("sync\nbalance\nquit\n")
            counts = re.findall(r"Bitcoin compact filters: (\d+) header-only blocks, (\d+) full blocks downloaded", log)
            assert counts and int(counts[-1][0]) >= 3 and int(counts[-1][1]) == 1, counts
            assert "200000" in output, output
            print("compact filters skipped unrelated blocks and downloaded the wallet match")
            print(f"first sync: {counts[0]}; funded sync: {counts[-1]}")
        finally:
            try:
                btc("stop")
            except (FileNotFoundError, subprocess.CalledProcessError):
                pass


if __name__ == "__main__":
    main()
