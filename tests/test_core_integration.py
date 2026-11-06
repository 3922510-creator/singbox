"""Real sing-box validation and loopback-only WS proxy test; never touches services."""
from pathlib import Path
import http.server
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = Path(os.environ.get("SB_TEST_CORE", "/usr/local/bin/sing-box"))


@unittest.skipUnless(CORE.is_file(), "set SB_TEST_CORE to a real sing-box binary")
class CoreIntegrationTests(unittest.TestCase):
    def test_real_core_accepts_nodes_forward_and_warp(self):
        with tempfile.TemporaryDirectory(prefix="sb-real-check-") as directory:
            script = r'''
set -e -o pipefail
source "$1"
ROOT="$2"; BIN_FILE="$3"
CONFIG_DIR="$ROOT/config"; CONFIG_FILE="$CONFIG_DIR/config.json"
META_DIR="$CONFIG_DIR/.meta"; STATE_FILE="$META_DIR/state.json"
ARGO_DIR="$META_DIR/tunnels"; BACKUP_DIR="$ROOT/backups"
SERVICE_FILE="$ROOT/unit"; INIT_SYS=systemd
umask 077; mkdir -p "$META_DIR"; printf '# sb-v4-managed\n' > "$SERVICE_FILE"
write_json "$CONFIG_FILE" '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}'
write_json "$STATE_FILE" '{"format":4,"nodes":{}}'
confirm() { :; }; acquire_lock() { :; }; svc_active() { :; }; svc_restart() { :; }; sleep() { :; }
prepare_core() { :; }; offer_firewall_port() { :; }; show_node() { :; }
read_valid_port() { printf '%s' "$PORT"; }
PORT=30101; add_direct_node vless <<< $'example.com\nVLESS\n'
PORT=30102; add_direct_node anytls <<< $'example.com\nAnyTLS\n'
# Argo's generated schema, with no public listener and no cloud credentials.
config=$(jq '.inbounds += [{type:"vless",tag:"argo",listen:"127.0.0.1",listen_port:30103,users:[{uuid:"11111111-1111-4111-8111-111111111111"}],transport:{type:"ws",path:"/test/path"}}]' "$CONFIG_FILE")
state=$(jq '.nodes.argo={kind:"argo",name:"Argo",domain:"argo.example.com",tunnel_id:"11111111-1111-4111-8111-111111111111"}' "$STATE_FILE")
apply_config "$config" "$state" Argo
# Use a local fixture key, not a real WARP account. No account registration/network.
register_warp_account() { printf '{"private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","ipv6":"2606:4700:110:1234::2","reserved":[1,2,3]}'; }
add_warp
select_node() { printf argo; }
add_warp_node_route
PORT=30104; add_port_forward <<< '127.0.0.1'
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '(.inbounds|length)==4 and (.endpoints|length)==1 and (.route.rules|length)==2' "$CONFIG_FILE"
'''
            result = subprocess.run(["bash", "-c", script, "test", str(ROOT / "singbox.sh"), directory, str(CORE)], capture_output=True, text=True, timeout=25)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_real_vless_ws_end_to_end_loopback(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                payload = b"sb-v4-local-ws-ok"
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        def free_port():
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                return sock.getsockname()[1]

        target = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=target.serve_forever, daemon=True)
        thread.start()
        processes = []
        try:
            with tempfile.TemporaryDirectory(prefix="sb-ws-e2e-") as directory:
                server_port, client_port = free_port(), free_port()
                while client_port == server_port:
                    client_port = free_port()
                uuid = "11111111-1111-4111-8111-111111111111"
                configs = {
                    "server": {"log": {"level": "error"}, "inbounds": [{"type": "vless", "listen": "127.0.0.1", "listen_port": server_port, "users": [{"uuid": uuid}], "transport": {"type": "ws", "path": "/test/path"}}], "outbounds": [{"type": "direct"}]},
                    "client": {"log": {"level": "error"}, "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": client_port}], "outbounds": [{"type": "vless", "server": "127.0.0.1", "server_port": server_port, "uuid": uuid, "transport": {"type": "ws", "path": "/test/path"}}]},
                }
                for name, config in configs.items():
                    path = Path(directory) / f"{name}.json"
                    path.write_text(json.dumps(config))
                    path.chmod(0o600)
                    subprocess.run([str(CORE), "check", "-c", str(path)], check=True, capture_output=True, timeout=5)
                    process = subprocess.Popen([str(CORE), "run", "-c", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
                    processes.append(process)
                result = None
                for _ in range(20):
                    if any(process.poll() is not None for process in processes):
                        self.fail("isolated core exited: " + str([p.stderr.read().decode() for p in processes if p.poll() is not None]))
                    result = subprocess.run(["curl", "-fsS", "--noproxy", "", "--max-time", "2", "--proxy", f"socks5h://127.0.0.1:{client_port}", f"http://127.0.0.1:{target.server_port}/"], capture_output=True, text=True)
                    if result.returncode == 0:
                        break
                    time.sleep(0.1)
                self.assertIsNotNone(result)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "sb-v4-local-ws-ok")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()  # Only the child Popen object created by this test.
                    process.communicate(timeout=5)
            target.shutdown()
            target.server_close()
            thread.join(timeout=5)
