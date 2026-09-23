#!/usr/bin/env python3
"""Two-node direct-peer PQLN channel, payment, restart, and reorg check."""
import json
import re
import sqlite3
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "crates/pq-light-client/target/debug/pq-light-client"


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(predicate, message, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.3)
    raise RuntimeError(f"timed out waiting for {message}")


class Node:
    def __init__(self, name, fixture, peer_port, second_peer_port, listen_port):
        self.state = fixture / name
        self.listen_port = listen_port
        self.output_path = fixture / f"{name}.out"
        self.output = self.output_path.open("a+")
        self.output_start = len(self.text())
        self.log_path = self.state / "node/ldk_node.log"
        old_syncs = self.log_path.read_text(errors="ignore").count("Direct Bitcoin peer initial sync complete") if self.log_path.exists() else 0
        self.process = subprocess.Popen(
            [str(CLIENT), str(self.state), f"127.0.0.1:{peer_port},127.0.0.1:{second_peer_port}", f"127.0.0.1:{listen_port}"],
            stdin=subprocess.PIPE, stdout=self.output, stderr=subprocess.STDOUT, text=True,
        )
        wait_for(
            lambda: self.log_path.exists() and self.log_path.read_text(errors="ignore").count("Direct Bitcoin peer initial sync complete") > old_syncs,
            f"{name} initial sync", 120,
        )
        if self.process.poll() is not None:
            raise RuntimeError(f"{name} exited: {self.text()}")

    def text(self):
        return self.output_path.read_text(errors="ignore")

    def send(self, command, marker, timeout=45):
        previous = len(self.text())
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()
        try:
            return wait_for(lambda: (tail if marker in (tail := self.text()[previous:]) else None), marker, timeout)
        except RuntimeError as error:
            log = self.log_path.read_text(errors="ignore")[-2500:] if self.log_path.exists() else ""
            raise RuntimeError(f"{error}; node output: {self.text()[-1500:]}; log: {log}") from error

    def event(self, marker, timeout=90, since=None):
        start = self.output_start if since is None else since
        return wait_for(lambda: marker in self.text()[start:], marker, timeout)

    def stop(self):
        if self.process.poll() is None:
            self.process.stdin.write("quit\n")
            self.process.stdin.flush()
            self.process.wait(timeout=30)
        self.output.close()
        if self.process.returncode:
            raise RuntimeError(f"node exited with {self.process.returncode}: {self.text()[-1500:]}")


def main():
    with tempfile.TemporaryDirectory(prefix="winnow-pqln-filter-") as directory:
        fixture = Path(directory)
        datadir = fixture / "bitcoin"
        datadir.mkdir()
        second_dir = fixture / "bitcoin-second"
        second_dir.mkdir()
        rpc_port, peer_port, second_rpc, second_peer_port, alice_port, bob_port = (port() for _ in range(6))

        def btc(*args):
            return subprocess.check_output(
                ["bitcoin-cli", f"-datadir={datadir}", "-regtest", f"-rpcport={rpc_port}", *args],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()

        def second(*args):
            return subprocess.check_output(
                ["bitcoin-cli", f"-datadir={second_dir}", "-regtest", f"-rpcport={second_rpc}", *args],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()

        subprocess.run([
            "bitcoind", f"-datadir={datadir}", "-regtest", "-server=1", "-listen=1",
            "-bind=127.0.0.1", "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1",
            f"-rpcport={rpc_port}", f"-port={peer_port}", "-blockfilterindex=1",
            "-peerblockfilters=1", "-txindex=1", "-fallbackfee=0.0001", "-daemon",
        ], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([
            "bitcoind", f"-datadir={second_dir}", "-regtest", "-server=1", "-listen=1",
            "-bind=127.0.0.1", "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1",
            f"-rpcport={second_rpc}", f"-port={second_peer_port}", "-blockfilterindex=1",
            "-peerblockfilters=1", "-txindex=1", "-fallbackfee=0.0001", "-daemon",
        ], check=True, stdout=subprocess.DEVNULL)
        alice = bob = None
        try:
            for _ in range(80):
                try:
                    btc("getblockchaininfo")
                    break
                except subprocess.CalledProcessError:
                    time.sleep(0.25)
            else:
                raise RuntimeError("bitcoind did not start")
            for _ in range(80):
                try:
                    second("getblockchaininfo")
                    break
                except subprocess.CalledProcessError:
                    time.sleep(0.25)
            else:
                raise RuntimeError("second bitcoind did not start")
            btc("addnode", f"127.0.0.1:{second_peer_port}", "onetry")
            btc("createwallet", "mine")
            mine = btc("getnewaddress")
            btc("generatetoaddress", "101", mine)
            wait_for(lambda: second("getblockcount") == "101", "second peer chain sync")
            alice = Node("alice", fixture, peer_port, second_peer_port, alice_port)
            bob = Node("bob", fixture, peer_port, second_peer_port, bob_port)
            address = re.search(r"bcrt1[0-9a-z]{20,}", alice.send("address", "bcrt1")).group()
            late_address = btc("getnewaddress")
            btc("sendtoaddress", late_address, "0.00100000")
            btc("generatetoaddress", "1", mine)
            wait_for(lambda: second("getblockcount") == btc("getblockcount"), "second peer historical watch block")
            btc("sendtoaddress", address, "0.00200000")
            btc("generatetoaddress", "1", mine)
            wait_for(lambda: second("getblockcount") == btc("getblockcount"), "second peer funding block")
            def funded():
                return "total_onchain_balance_sats: 200000" in alice.send("balance", "BalanceDetails")
            wait_for(funded, "funded Alice wallet", 60)
            alice_id = (alice.state / "node-id.txt").read_text().strip()
            bob_id = (bob.state / "node-id.txt").read_text().strip()
            alice.send(f"connect {bob_id} 127.0.0.1:{bob_port} {bob.state / 'pq-kem-key.hex'}", "PQLN peer connected")
            bob.send(f"connect {alice_id} 127.0.0.1:{alice_port} {alice.state / 'pq-kem-key.hex'}", "PQLN peer connected")
            alice.send(f"open-public {bob_id} 100000", "channel opening started")
            wait_for(lambda: json.loads(btc("getrawmempool")), "channel funding broadcast", 60)
            btc("generatetoaddress", "6", mine)
            wait_for(lambda: second("getblockcount") == btc("getblockcount"), "second peer channel block")
            alice.event("ChannelReady", 120)
            bob.event("ChannelReady", 120)
            assert "is_usable: true" in alice.send("channels", "is_usable:")
            wait_for(
                lambda: f"PQ: pinned ML-KEM key for node {bob_id}" in alice.log_path.read_text(errors="ignore"),
                "authenticated PQLN gossip", 90,
            )
            invoice = fixture / "invoice.txt"
            bob.send(f"invoice-file 1000 {invoice} first", "invoice saved")
            alice_before, bob_before = len(alice.text()), len(bob.text())
            alice.send(f"pay {invoice} {bob.state / 'pq-node-key.hex'}", "payment started")
            alice.event("PaymentSuccessful", 90, alice_before)
            bob.event("PaymentReceived", 90, bob_before)
            alice.send(f"test-watch {late_address}", "test watch registered")
            wait_for(lambda: "Bitcoin watch replayed from height 102" in alice.log_path.read_text(errors="ignore"), "late watch replay", 90)
            assert "is_usable: true" in alice.send("channels", "is_usable:")
            alice.stop()
            bob.stop()
            alice = Node("alice", fixture, peer_port, second_peer_port, alice_port)
            bob = Node("bob", fixture, peer_port, second_peer_port, bob_port)
            assert "is_usable: true" in alice.send("channels", "is_usable:")
            bob.send(f"invoice-file 2000 {invoice} restart", "invoice saved")
            alice_before, bob_before = len(alice.text()), len(bob.text())
            alice.send(f"pay {invoice} {bob.state / 'pq-node-key.hex'}", "payment started")
            alice.event("PaymentSuccessful", 90, alice_before)
            bob.event("PaymentReceived", 90, bob_before)
            invalidated = btc("generatetoaddress", "1", mine)
            fork_height = int(btc("getblockcount"))
            wait_for(lambda: second("getblockcount") == btc("getblockcount"), "second peer reorg target")
            block_hash = json.loads(invalidated)[0]
            wait_for(
                lambda: block_hash in alice.log_path.read_text(errors="ignore")
                and block_hash in bob.log_path.read_text(errors="ignore"),
                "both clients to accept the soon-to-be-reorganized block", 45,
            )
            btc("invalidateblock", block_hash)
            btc("generatetoaddress", "2", btc("getnewaddress"))
            wait_for(lambda: second("getbestblockhash") == btc("getbestblockhash"), "second peer reorganization")
            wait_for(lambda: "blocks_disconnected" in alice.log_path.read_text(errors="ignore"), "chain reorganization", 60)
            for node in (alice, bob):
                archive = node.state / "node/compact-filter-history.sqlite"
                def archived_forks():
                    if not archive.exists():
                        return False
                    with sqlite3.connect(archive) as db:
                        return db.execute(
                            "SELECT COUNT(*) FROM filters WHERE height = ?", (fork_height,),
                        ).fetchone()[0] >= 2
                wait_for(archived_forks, f"{node.state.name} filter archive to retain both branches", 60)
            bob.send(f"invoice-file 3000 {invoice} reorg", "invoice saved")
            alice_before, bob_before = len(alice.text()), len(bob.text())
            alice.send(f"pay {invoice} {bob.state / 'pq-node-key.hex'}", "payment started")
            alice.event("PaymentSuccessful", 90, alice_before)
            bob.event("PaymentReceived", 90, bob_before)
            counts = re.findall(r"Bitcoin compact filters: (\d+) header-only blocks, (\d+) full blocks downloaded", alice.log_path.read_text(errors="ignore"))
            assert counts and any(int(fetched) > 0 for _, fetched in counts), counts
            print("PQLN channel, payments, restart, and reorg passed with compact-filter scanning")
            print(f"Alice filter counts: {counts[-1]}")
        finally:
            for node in (alice, bob):
                if node is not None and node.process.poll() is None:
                    try:
                        node.stop()
                    except Exception:
                        node.process.kill()
            try:
                btc("stop")
            except (FileNotFoundError, subprocess.CalledProcessError):
                pass
            try:
                second("stop")
            except (FileNotFoundError, subprocess.CalledProcessError):
                pass


if __name__ == "__main__":
    main()
