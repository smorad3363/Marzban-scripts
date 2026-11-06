#!/usr/bin/env python3
"""Real Docker tests; only run on a disposable, empty GitHub Actions runner."""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time

import requests
import rpyc


ROOT = Path(__file__).resolve().parents[1]
APP = Path("/opt/master")
DATA = Path("/var/lib/master")
SCRIPT = ROOT / "marzban-node.sh"
REAL_DOCKER = shutil.which("docker")
REAL_CURL = shutil.which("curl")
PAYLOAD = b"node-runtime-integration\n" * 50000


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, timeout=kwargs.pop("timeout", 300), **kwargs)
    if result.returncode:
        error = result.stderr.decode(errors="replace") if isinstance(result.stderr, bytes) else result.stderr
        output = result.stdout.decode(errors="replace") if isinstance(result.stdout, bytes) else result.stdout
        raise RuntimeError("Failed command " + str(args[:3]) + "\n" + error[-3000:] + output[-3000:])
    return result.stdout


def docker(*args):
    return run([REAL_DOCKER, *args], text=True)


def inspect(name="master"):
    return json.loads(docker("inspect", name))[0]


def free_port():
    with socket.socket() as stream:
        stream.bind(("127.0.0.1", 0))
        return stream.getsockname()[1]


def wait_port(port, timeout=60):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=.3):
                return
        except OSError:
            time.sleep(.3)
    raise RuntimeError("Node port did not become ready: " + str(port))


def check_runtime_and_data(cert, key, origin, protocol="rest", service_port=62050):
    wait_port(service_port)
    socks_port = free_port()
    configuration = {"log": {"loglevel": "warning"}, "inbounds": [{"tag": "integration-users", "listen": "127.0.0.1", "port": socks_port, "protocol": "socks", "settings": {"auth": "noauth"}}], "outbounds": [{"protocol": "freedom"}], "policy": {"levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}}}}
    peer = None
    if protocol == "rest":
        session = requests.Session()
        session.cert = (str(cert), str(key))
        session.verify = False  # This runner owns both ends and generates a disposable node certificate.
        requests.packages.urllib3.disable_warnings()
        response = session.post("https://127.0.0.1:" + str(service_port) + "/connect", timeout=10)
        response.raise_for_status()
        token = response.json()["session_id"]
        response = session.post("https://127.0.0.1:" + str(service_port) + "/start", json={"session_id": token, "config": json.dumps(configuration)}, timeout=12)
        response.raise_for_status()
        assert response.json()["started"]
    else:
        # Build the context explicitly: RPyC's convenience wrapper cannot disable
        # hostname checking before CERT_NONE on recent Python versions.
        from rpyc.core.stream import SocketStream
        from rpyc.utils.factory import connect_stream
        context = ssl.create_default_context(cafile=str(DATA / "ssl_cert.pem"))
        context.check_hostname = False
        context.load_cert_chain(str(cert), str(key))
        raw = socket.create_connection(("127.0.0.1", service_port), timeout=10)
        peer = connect_stream(SocketStream(context.wrap_socket(raw, server_hostname="Gozargah")))
        peer.root.start(json.dumps(configuration))
    try:
        wait_port(socks_port)
        child_env = json.loads(docker("exec", "master", "python", "-c", "import pathlib,json; p=next(p for p in pathlib.Path('/proc').glob('[0-9]*') if (p/'comm').exists() and (p/'comm').read_text().strip()=='xray'); print(json.dumps([x.decode() for x in (p/'environ').read_bytes().split(b'\\0') if x.startswith((b'GOGC=',b'GOMEMLIMIT='))]))"))
        assert "GOGC=50" in child_env, child_env
        assert any(value.startswith("GOMEMLIMIT=") for value in child_env), child_env
        body = run([REAL_CURL, "-fsS", "--noproxy", "", "--proxy", "socks5h://127.0.0.1:" + str(socks_port), "--max-time", "10", origin])
        assert hashlib.sha256(body).digest() == hashlib.sha256(PAYLOAD).digest()
    finally:
        if peer:
            peer.close()
    print("PASS: real " + protocol.upper() + " control, child Go environment and verified proxy payload", flush=True)


def command_env(bin_dir, marker=None):
    result = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"], TERM="xterm", NODE_TEST_SCRIPT=str(SCRIPT), NODE_TEST_REAL_DOCKER=REAL_DOCKER, NODE_TEST_REAL_CURL=REAL_CURL)
    if marker:
        result["NODE_TEST_FAIL_UP"] = str(marker)
    else:
        result.pop("NODE_TEST_FAIL_UP", None)
    return result


def snapshot():
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in [APP / "docker-compose.yml", APP / ".env", DATA / "cert.pem", DATA / "xray-core/xray", DATA / "keep-this-file"] if path.exists()}


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.geteuid() != 0:
        raise RuntimeError("Use a disposable GitHub Actions runner as root")
    if APP.exists() or DATA.exists():
        raise RuntimeError("Refusing to touch an existing node")
    with tempfile.TemporaryDirectory(prefix="node-runtime-integration-") as temp:
        work = Path(temp)
        cert, key = work / "client.pem", work / "client-key.pem"
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=DisposableNodeIntegration", "-keyout", str(key), "-out", str(cert)])
        bin_dir = work / "bin"
        bin_dir.mkdir()
        # Mirror only the CLI download to the checkout under test. All Docker work is real.
        (bin_dir / "curl").write_text("""#!/usr/bin/env python3
import os,sys,shutil
a=sys.argv[1:]
if any('/Marzban-scripts/' in x and x.endswith('/marzban-node.sh') for x in a):
 if '-o' in a: shutil.copyfile(os.environ['NODE_TEST_SCRIPT'],a[a.index('-o')+1])
 else: sys.stdout.write(open(os.environ['NODE_TEST_SCRIPT']).read())
 sys.exit(0)
if any('ifconfig.io' in x for x in a):
 print('127.0.0.1');sys.exit(0)
os.execv(os.environ['NODE_TEST_REAL_CURL'],[os.environ['NODE_TEST_REAL_CURL']]+a)
""")
        (bin_dir / "docker").write_text("""#!/usr/bin/env python3
import os,sys,pathlib,subprocess
a=sys.argv[1:];marker=os.environ.get('NODE_TEST_FAIL_UP')
if marker and a and a[0]=='compose' and 'up' in a and not pathlib.Path(marker).exists():
 pathlib.Path(marker).touch()
 subprocess.run([os.environ['NODE_TEST_REAL_DOCKER'],'rm','-f','master'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 print('Injected deployment failure after removing the old node',file=sys.stderr);sys.exit(42)
os.execv(os.environ['NODE_TEST_REAL_DOCKER'],[os.environ['NODE_TEST_REAL_DOCKER']]+a)
""")
        for path in bin_dir.iterdir():
            path.chmod(0o755)
        env = command_env(bin_dir)
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", str(len(PAYLOAD)))
                self.end_headers()
                self.wfile.write(PAYLOAD)
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        origin = "http://127.0.0.1:" + str(server.server_address[1]) + "/payload"
        install_log = work / "install.log"
        try:
            print("Testing fresh install with the original command arguments", flush=True)
            with install_log.open("w+") as log:
                process = subprocess.Popen(["bash", str(SCRIPT), "install", "--name", "master"], stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT, text=True, env=env, start_new_session=True)
                process.stdin.write(cert.read_text() + "\nY\n62050\n62051\n")
                process.stdin.close()
                try:
                    wait_port(62050, timeout=240)
                    time.sleep(5)
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGINT)
                    process.wait(timeout=20)
                if process.returncode not in (0, 130, -signal.SIGINT):
                    log.seek(0)
                    raise RuntimeError(log.read()[-6000:])
            assert (APP / "docker-compose.runtime.json").is_file()
            check_runtime_and_data(cert, key, origin)

            print("Creating a legacy node with custom ports, a pinned core and a sidecar", flush=True)
            base = json.loads(docker("compose", "-f", str(APP / "docker-compose.yml"), "config", "--format", "json"))
            node = base["services"]["marzban-node"]
            node["environment"].update(SERVICE_PORT="61050", XRAY_API_PORT="61051", XRAY_EXECUTABLE_PATH="/var/lib/marzban-node/xray-core/xray", CUSTOM_EXISTING_SETTING="keep-me")
            base["services"]["fixture-sidecar"] = {"image": node["image"], "container_name": "master-sidecar", "entrypoint": ["python", "-c", "import time; time.sleep(3600)"], "network_mode": "none"}
            (DATA / "xray-core").mkdir()
            docker("cp", "master:/usr/local/bin/xray", str(DATA / "xray-core/xray"))
            (DATA / "xray-core/xray").chmod(0o755)
            (APP / "docker-compose.yml").write_text("# Existing administrator comment\n" + json.dumps(base, indent=2) + "\n")
            (APP / ".env").write_text("EXISTING_NODE_SENTINEL=keep-me\n")
            (DATA / "keep-this-file").write_text("existing node data\n")
            (APP / "docker-compose.runtime.json").unlink()
            docker("compose", "-f", str(APP / "docker-compose.yml"), "-p", "master", "up", "-d", "--force-recreate")
            (DATA / "node-runtime-patch/xray.py").unlink()
            before = snapshot()
            sidecar_id = inspect("master-sidecar")["Id"]
            # No certificate, port, protocol, or overwrite answers are supplied for migration.
            run(["bash", str(SCRIPT), "install", "--name", "master"], input="", text=True, env=env)
            assert snapshot() == before, "Legacy inputs or data were rewritten"
            assert inspect("master-sidecar")["Id"] == sidecar_id, "Unrelated sidecar was recreated"
            current_env = dict(value.split("=", 1) for value in inspect()["Config"]["Env"] if "=" in value)
            assert current_env["CUSTOM_EXISTING_SETTING"] == "keep-me"
            assert current_env["SERVICE_PORT"] == "61050"
            assert current_env["XRAY_API_PORT"] == "61051"
            check_runtime_and_data(cert, key, origin, service_port=61050)
            print("PASS: legacy install command upgrades in place without stdin or changed inputs", flush=True)

            print("Testing repeated migration and the existing management commands", flush=True)
            run(["bash", str(SCRIPT), "install", "--name", "master"], input="", text=True, env=env)
            run(["/usr/local/bin/master", "update"], input="", text=True, env=env)
            run(["/usr/local/bin/master", "status"], text=True, env=env)
            with (work / "logs.log").open("w") as output:
                logs = subprocess.Popen(["/usr/local/bin/master", "logs"], stdout=output, stderr=subprocess.STDOUT, env=env, start_new_session=True)
                time.sleep(2)
                if logs.poll() is None:
                    os.killpg(logs.pid, signal.SIGINT)
                assert logs.wait(timeout=15) in (0, 130, -signal.SIGINT)
            assert snapshot() == before
            assert inspect("master-sidecar")["Id"] == sidecar_id

            print("Testing recovery from a failed deployment with real Docker", flush=True)
            old_overlay = (APP / "docker-compose.runtime.json").read_bytes()
            old_module = (DATA / "node-runtime-patch/xray.py").read_bytes()
            marker = work / "failed-once"
            failure = subprocess.run(["bash", str(SCRIPT), "install", "--name", "master"], input="", text=True, env=command_env(bin_dir, marker), capture_output=True, timeout=300)
            assert failure.returncode != 0, "Injected failure was incorrectly reported as success"
            assert marker.exists()
            assert (APP / "docker-compose.runtime.json").read_bytes() == old_overlay
            assert (DATA / "node-runtime-patch/xray.py").read_bytes() == old_module
            assert snapshot() == before
            check_runtime_and_data(cert, key, origin, service_port=61050)
            print("PASS: failed deployment restored a working previous node", flush=True)

            print("Testing a legacy RPyC node without changing its protocol", flush=True)
            base["services"]["marzban-node"]["environment"]["SERVICE_PROTOCOL"] = "rpyc"
            (APP / "docker-compose.yml").write_text(json.dumps(base, indent=2) + "\n")
            (APP / "docker-compose.runtime.json").unlink()
            docker("compose", "-f", str(APP / "docker-compose.yml"), "-p", "master", "up", "-d", "--force-recreate", "marzban-node")
            before_rpyc = snapshot()
            run(["bash", str(SCRIPT), "install", "--name", "master"], input="", text=True, env=env)
            assert snapshot() == before_rpyc
            check_runtime_and_data(cert, key, origin, protocol="rpyc", service_port=61050)
            print("ALL REAL INSTALLATION AND MIGRATION CHECKS PASSED", flush=True)
        except BaseException:
            if install_log.exists():
                print(install_log.read_text()[-6000:], flush=True)
            subprocess.run([REAL_DOCKER, "logs", "--tail", "60", "master"], check=False)
            raise
        finally:
            server.shutdown()
            server.server_close()
            subprocess.run([REAL_DOCKER, "rm", "-f", "master", "master-sidecar"], capture_output=True)
            shutil.rmtree(APP, ignore_errors=True)
            shutil.rmtree(DATA, ignore_errors=True)
            Path("/usr/local/bin/master").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
