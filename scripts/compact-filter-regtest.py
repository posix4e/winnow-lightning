#!/usr/bin/env python3
"""Exercise LDK's direct-peer wallet with unrelated and relevant regtest blocks."""
import re
import hashlib
import socket
import socketserver
import sqlite3
import subprocess
import tempfile
import threading
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "crates/pq-light-client/target/debug/pq-light-client"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class FilterMutatingProxy:
    def __init__(self, upstream_port):
        self.changed = threading.Event()
        self.commands = []

        class Handler(socketserver.BaseRequestHandler):
            def handle(handler):
                try:
                    with socket.create_connection(("127.0.0.1", upstream_port), timeout=10) as upstream:
                        upstream.settimeout(None)
                        downstream = handler.request

                        def to_peer():
                            try:
                                while data := downstream.recv(65536):
                                    upstream.sendall(data)
                            except OSError:
                                pass
                            try:
                                upstream.shutdown(socket.SHUT_WR)
                            except OSError:
                                pass

                        sender = threading.Thread(target=to_peer, daemon=True)
                        sender.start()

                        def read_exact(count):
                            result = bytearray()
                            while len(result) < count:
                                chunk = upstream.recv(count - len(result))
                                if not chunk:
                                    return None
                                result.extend(chunk)
                            return bytes(result)

                        while header := read_exact(24):
                            self.commands.append(header[4:16].rstrip(b"\x00"))
                            length = int.from_bytes(header[16:20], "little")
                            if length > 4_000_000:
                                raise RuntimeError("unexpected Bitcoin message length")
                            payload = read_exact(length)
                            if payload is None:
                                break
                            if header[4:16].rstrip(b"\x00") == b"cfheaders" and len(payload) >= 98:
                                payload = payload[:-1] + bytes([payload[-1] ^ 1])
                                checksum = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
                                header = header[:20] + checksum
                                self.changed.set()
                            downstream.sendall(header + payload)
                        sender.join(timeout=1)
                except OSError:
                    pass

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()


def main():
    with tempfile.TemporaryDirectory(prefix="winnow-compact-filter-") as directory:
        fixture = Path(directory)
        bitcoin_dir = fixture / "bitcoin"
        bitcoin_dir.mkdir()
        second_dir = fixture / "bitcoin-second"
        second_dir.mkdir()
        client_dir = fixture / "client"
        rpc_port, p2p_port, second_rpc, second_p2p, listen_port = (free_port() for _ in range(5))

        def btc(*args):
            return subprocess.check_output(
                ["bitcoin-cli", f"-datadir={bitcoin_dir}", "-regtest", f"-rpcport={rpc_port}", *args],
                text=True,
            ).strip()

        def second(*args):
            return subprocess.check_output(
                ["bitcoin-cli", f"-datadir={second_dir}", "-regtest", f"-rpcport={second_rpc}", *args],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()

        def run_client(commands, after_sync=None):
            log = client_dir / "node/ldk_node.log"
            old_syncs = log.read_text(errors="ignore").count("Direct Bitcoin peer initial sync complete") if log.exists() else 0
            process = subprocess.Popen(
                [str(CLIENT), str(client_dir), f"127.0.0.1:{p2p_port},127.0.0.1:{second_p2p}", f"127.0.0.1:{listen_port}"],
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
                if after_sync is not None:
                    after_sync()
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
        subprocess.run([
            "bitcoind", f"-datadir={second_dir}", "-regtest", "-server=1", "-listen=1",
            "-bind=127.0.0.1", "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1",
            f"-rpcport={second_rpc}", f"-port={second_p2p}", "-blockfilterindex=1",
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
            for _ in range(60):
                try:
                    second("getblockchaininfo")
                    break
                except subprocess.CalledProcessError:
                    time.sleep(0.25)
            else:
                raise RuntimeError("second bitcoind did not start")
            btc("addnode", f"127.0.0.1:{second_p2p}", "onetry")
            btc("createwallet", "mine")
            mine_address = btc("getnewaddress")
            btc("generatetoaddress", "101", mine_address)
            for _ in range(120):
                if second("getblockcount") == "101":
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError("second peer did not sync mined blocks")

            with FilterMutatingProxy(second_p2p) as proxy:
                bad_state = fixture / "tampered-client"
                bad_log = bad_state / "node/ldk_node.log"
                process = subprocess.Popen(
                    [str(CLIENT), str(bad_state), f"127.0.0.1:{p2p_port},127.0.0.1:{proxy.port}", f"127.0.0.1:{free_port()}"],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                )
                try:
                    assert proxy.changed.wait(30), f"the proxy did not receive a filter header: {proxy.commands}, {bad_log.read_text(errors='ignore')[-1000:] if bad_log.exists() else ''}"
                    time.sleep(4)
                    assert not bad_log.exists() or "Direct Bitcoin peer initial sync complete" not in bad_log.read_text(errors="ignore"), "tampered filter header was accepted"
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=10)

            output, log = run_client("address\nsync\nbalance\nquit\n")
            archive = client_dir / "node/compact-filter-history.sqlite"
            with sqlite3.connect(archive) as db:
                assert db.execute("SELECT COUNT(*) FROM filters").fetchone()[0] == 101
            address = re.search(r"bcrt1[0-9a-z]{20,}", output)
            assert address, output
            counts = re.findall(r"Bitcoin compact filters: (\d+) header-only blocks, (\d+) full blocks downloaded", log)
            assert counts and int(counts[-1][0]) >= 100 and int(counts[-1][1]) == 0, counts

            btc("generatetoaddress", "3", mine_address)
            late_address = btc("getnewaddress")
            btc("sendtoaddress", late_address, "0.00100000")
            btc("generatetoaddress", "1", mine_address)
            btc("sendtoaddress", address.group(), "0.00200000")
            btc("generatetoaddress", "1", mine_address)
            for _ in range(120):
                if second("getblockcount") == btc("getblockcount"):
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError("second peer did not sync funding block")
            output, log = run_client("sync\nbalance\nquit\n")
            with sqlite3.connect(archive) as db:
                assert db.execute("SELECT COUNT(*) FROM filters").fetchone()[0] == 106
            counts = re.findall(r"Bitcoin compact filters: (\d+) header-only blocks, (\d+) full blocks downloaded", log)
            assert counts and int(counts[-1][0]) >= 4 and int(counts[-1][1]) == 1, counts
            assert "200000" in output, output
            output, log = run_client(f"test-watch {late_address}\nsync\nquit\n")
            assert "test watch registered" in output, output
            assert "Bitcoin watch replayed from height 105 through 106" in log, log[-3000:]
            assert "Bitcoin compact filter cache loaded through height 106" in log, log[-3000:]
            downloaded = re.findall(r"Bitcoin compact filter bodies downloaded since startup: (\d+)", log)
            assert downloaded and int(downloaded[-1]) == 0, downloaded
            replay_counts = re.findall(r"Bitcoin compact filters: (\d+) header-only blocks, (\d+) full blocks downloaded", log)
            assert replay_counts and int(replay_counts[-1][1]) >= 1, replay_counts
            with sqlite3.connect(archive) as db:
                assert db.execute("SELECT COUNT(*) FROM filters").fetchone()[0] == 106
            successful_replays = log.count("Bitcoin watch replayed from height")

            old_tip = btc("getblockhash", "106")
            btc("invalidateblock", old_tip)
            btc("generatetoaddress", "2", btc("getnewaddress"))
            for _ in range(120):
                if second("getbestblockhash") == btc("getbestblockhash"):
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError("second peer did not accept offline reorganization")
            _, log = run_client("sync\nquit\n")
            downloaded = re.findall(r"Bitcoin compact filter bodies downloaded since startup: (\d+)", log)
            assert downloaded and int(downloaded[-1]) == 2, downloaded
            with sqlite3.connect(archive) as db:
                assert db.execute("SELECT COUNT(*) FROM filters WHERE height = 106").fetchone()[0] == 2

            def corrupt_archive():
                with sqlite3.connect(archive) as db:
                    db.execute("UPDATE filters SET contents = x'00' WHERE block_hash = ?", (bytes.fromhex(old_tip)[::-1],))

            _, log = run_client(f"test-watch {late_address}\nsync\nquit\n", after_sync=corrupt_archive)
            assert log.count("Bitcoin watch replayed from height") == successful_replays, "corrupt cached filter was accepted"
            print("compact filters skipped unrelated blocks and downloaded the wallet match")
            print("a late script watch replayed its earlier funding block")
            print("a restart reused all 106 archived filter bodies without downloading them again")
            print("an offline reorganization fetched only two replacement filters")
            print("a corrupted archived filter failed closed")
            print("a tampered second peer prevented initial sync")
            print(f"first sync: {counts[0]}; funded sync: {counts[-1]}")
        finally:
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
