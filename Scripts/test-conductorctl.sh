#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build --product conductorctl

python3 - <<'PY'
import http.client
import json
import os
import socket
import subprocess
import threading
import time

ROOT = os.getcwd()
BIN = os.path.join(ROOT, ".build/debug/conductorctl")


def response(req, result):
    return json.dumps(
        {"id": req.get("id"), "ok": True, "result": result},
        separators=(",", ":"),
    ).encode() + b"\n"


def error_response(req, code, message):
    return json.dumps(
        {"id": req.get("id"), "ok": False, "error": {"code": code, "message": message}},
        separators=(",", ":"),
    ).encode() + b"\n"


class FakeAppSocket:
    def __init__(self, name, expected, handler):
        self.path = f"/tmp/{name}-{os.getpid()}-{id(self)}.sock"
        self.expected = expected
        self.handler = handler
        self.ready = threading.Event()
        self.errors = []
        self.requests = []
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        self.thread = threading.Thread(target=self._run, daemon=True)

    def __enter__(self):
        self.thread.start()
        if not self.ready.wait(2):
            raise RuntimeError("fake app socket did not start")
        return self

    def __exit__(self, exc_type, exc, tb):
        deadline = time.time() + 2
        while self.thread.is_alive() and time.time() < deadline:
            time.sleep(0.02)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        if self.errors and exc_type is None:
            raise AssertionError(self.errors)

    def _run(self):
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            srv.bind(self.path)
            srv.listen(16)
            self.ready.set()
            while len(self.requests) < self.expected:
                conn, _ = srv.accept()
                with conn:
                    data = b""
                    while not data.endswith(b"\n"):
                        chunk = conn.recv(4096)
                        if not chunk:
                            break
                        data += chunk
                    req = json.loads(data.decode())
                    self.requests.append(req)
                    conn.sendall(self.handler(req, len(self.requests)))
        except Exception as exc:
            self.errors.append(repr(exc))
        finally:
            srv.close()
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass


def run_cli(args, app, *, input_text=None, timeout=5):
    env = os.environ.copy()
    env["CONDUCTOR_SOCKET_PATH"] = app.path
    proc = subprocess.run(
        [BIN] + args,
        cwd=ROOT,
        env=env,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise AssertionError(f"{args} failed: {proc.stderr}")
    return proc.stdout


def run_cli_first_line(args, app, *, timeout=5):
    env = os.environ.copy()
    env["CONDUCTOR_SOCKET_PATH"] = app.path
    proc = subprocess.Popen(
        [BIN] + args,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        deadline = time.time() + timeout
        line = ""
        while time.time() < deadline:
            line = proc.stdout.readline()
            if line:
                return line
        stderr = proc.stderr.read() if proc.stderr else ""
        raise AssertionError(f"{args} emitted no line; stderr={stderr}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)


def free_port():
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def wait_port(port):
    deadline = time.time() + 5
    while True:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            if time.time() > deadline:
                raise RuntimeError("bridge did not listen in time")
            time.sleep(0.05)


def test_run_wait():
    status_calls = {"count": 0}

    def handler(req, _count):
        method = req["method"]
        if method == "agent.run":
            return response(req, {"pane": "p-wait", "jobId": "p-wait", "agent": "codex"})
        if method == "agent.status":
            status_calls["count"] += 1
            status = "running" if status_calls["count"] == 1 else "completed"
            return response(req, {"jobId": "p-wait", "pane": "p-wait", "agent": "codex", "status": status})
        if method == "agent.result":
            return response(req, {
                "jobId": "p-wait",
                "pane": "p-wait",
                "agent": "codex",
                "status": "completed",
                "summary": "done",
                "markdown": "done markdown",
            })
        return error_response(req, "unexpected", method)

    with FakeAppSocket("conductorctl-run-wait", 4, handler) as app:
        out = run_cli(["run", "codex", "--prompt", "hello", "--wait", "--poll", "0.25", "--timeout", "3", "--json"], app)
        payload = json.loads(out)
        assert payload["markdown"] == "done markdown", payload
        assert [req["method"] for req in app.requests] == [
            "agent.run", "agent.status", "agent.status", "agent.result"
        ]


def test_stdin_and_batch():
    def handler(req, _count):
        method = req["method"]
        params = req.get("params") or {}
        if method == "agent.run":
            assert params["prompt"] == "prompt from stdin\n", params
            return response(req, {"pane": "p-stdin", "jobId": "p-stdin", "agent": "codex"})
        if method == "agent.send":
            assert params["text"] == "send from stdin\n", params
            return response(req, True)
        if method == "app.ping":
            return response(req, {"pong": True})
        if method == "missing.method":
            return error_response(req, "unknown-method", "nope")
        return error_response(req, "unexpected", method)

    with FakeAppSocket("conductorctl-stdin-batch", 4, handler) as app:
        run_cli(["run", "codex", "--stdin", "--json"], app, input_text="prompt from stdin\n")
        run_cli(["send", "--stdin"], app, input_text="send from stdin\n")
        batch = '{"id":1,"method":"app.ping"}\n{"id":2,"method":"missing.method"}\n'
        out = run_cli(["batch"], app, input_text=batch)
        lines = [json.loads(line) for line in out.splitlines() if line.strip()]
        assert lines[0]["ok"] is True, lines
        assert lines[1]["error"]["code"] == "unknown-method", lines


def test_bridge_http():
    def handler(req, _count):
        method = req["method"]
        if method == "app.methods":
            return response(req, ["app.ping", "agent.run"])
        if method == "app.ping":
            return response(req, {"pong": True})
        if method == "missing.method":
            return error_response(req, "unknown-method", "nope")
        if method == "events.recent":
            params = req.get("params") or {}
            assert params.get("limit") == 7, params
            return response(req, [{"id": "evt-1", "type": "agent.completed", "payload": {"message": "hello"}}])
        return error_response(req, "unexpected", method)

    with FakeAppSocket("conductorctl-bridge", 4, handler) as app:
        port = free_port()
        env = os.environ.copy()
        env["CONDUCTOR_SOCKET_PATH"] = app.path
        bridge = subprocess.Popen(
            [BIN, "bridge", "--host", "127.0.0.1", "--port", str(port), "--interval", "0.25"],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            wait_port(port)

            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("OPTIONS", "/rpc", headers={"Origin": "http://localhost:3000"})
            resp = conn.getresponse()
            assert resp.status == 204, resp.status
            assert resp.getheader("Access-Control-Allow-Origin") == "*", resp.getheaders()
            assert resp.read() == b""

            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("GET", "/methods")
            resp = conn.getresponse()
            methods = json.loads(resp.read().decode())
            assert methods["result"] == ["app.ping", "agent.run"], methods

            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("GET", "/openapi.json")
            resp = conn.getresponse()
            spec = json.loads(resp.read().decode())
            assert spec["openapi"] == "3.1.0", spec
            assert "/batch" in spec["paths"], spec["paths"]

            body = '{"id":21,"method":"app.ping"}\n{"id":22,"method":"missing.method"}\n'
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("POST", "/batch", body=body.encode(), headers={"Content-Type": "application/x-ndjson"})
            resp = conn.getresponse()
            lines = [json.loads(line) for line in resp.read().decode().splitlines() if line.strip()]
            assert lines[0]["result"]["pong"] is True, lines
            assert lines[1]["error"]["code"] == "unknown-method", lines

            sock = socket.create_connection(("127.0.0.1", port), timeout=5)
            sock.sendall(
                b"GET /events?limit=7&interval=0.25 HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\n"
                b"Accept: text/event-stream\r\n\r\n"
            )
            data = b""
            deadline = time.time() + 5
            while b"\n\n" not in data:
                if time.time() > deadline:
                    raise AssertionError("timed out waiting for SSE")
                data += sock.recv(4096)
            text = data.decode(errors="replace")
            assert "Content-Type: text/event-stream\r\n" in text, text
            assert "id: evt-1\n" in text, text
            sock.close()
        finally:
            bridge.terminate()
            try:
                bridge.wait(timeout=3)
            except subprocess.TimeoutExpired:
                bridge.kill()
                bridge.wait(timeout=3)


def test_resource_commands():
    expected = [
        "workspace.create",
        "workspace.rename",
        "workspace.tree",
        "tab.rename",
        "pane.split",
        "pane.close",
        "workspace.status.set",
        "workspace.progress.set",
        "workspace.log.append",
    ]

    def handler(req, _count):
        method = req["method"]
        params = req.get("params") or {}
        if method == "workspace.create":
            assert params == {"path": "/tmp/proj", "name": "Proj"}, params
            return response(req, {"id": "w1", "name": "Proj", "path": "/tmp/proj", "active": True, "tabs": 1})
        if method == "workspace.rename":
            assert params == {"workspace": "w1", "name": "Renamed"}, params
            return response(req, True)
        if method == "workspace.tree":
            assert params == {"workspace": "w1"}, params
            return response(req, {"workspace": "w1", "tabs": []})
        if method == "tab.rename":
            assert params == {"tab": "t1", "title": "Build", "workspace": "w1"}, params
            return response(req, True)
        if method == "pane.split":
            assert params == {"pane": "p1", "direction": "down", "cwd": "/tmp/proj"}, params
            return response(req, {"pane": "p2"})
        if method == "pane.close":
            assert params == {"pane": "p2"}, params
            return response(req, True)
        if method == "workspace.status.set":
            assert params == {
                "workspace": "w1",
                "key": "build",
                "text": "Building now",
                "color": "#00ff00",
                "icon": "hammer",
            }, params
            return response(req, True)
        if method == "workspace.progress.set":
            assert params == {"workspace": "w1", "value": 0.5, "label": "half"}, params
            return response(req, True)
        if method == "workspace.log.append":
            assert params == {"workspace": "w1", "text": "hello logs", "level": "warn", "source": "test"}, params
            return response(req, True)
        return error_response(req, "unexpected", method)

    with FakeAppSocket("conductorctl-resources", len(expected), handler) as app:
        run_cli(["workspace", "create", "/tmp/proj", "--name", "Proj", "--json"], app)
        run_cli(["workspace", "rename", "w1", "Renamed"], app)
        run_cli(["workspace", "tree", "w1"], app)
        run_cli(["tab", "rename", "t1", "Build", "--workspace", "w1"], app)
        run_cli(["pane", "split", "--pane", "p1", "--direction", "down", "--cwd", "/tmp/proj", "--json"], app)
        run_cli(["pane", "close", "p2"], app)
        run_cli([
            "workspace", "status", "set", "build", "Building", "now",
            "--workspace", "w1", "--color", "#00ff00", "--icon", "hammer",
        ], app)
        run_cli(["workspace", "progress", "set", "0.5", "--workspace", "w1", "--label", "half"], app)
        run_cli([
            "workspace", "log", "append", "hello", "logs",
            "--workspace", "w1", "--level", "warn", "--source", "test",
        ], app)
        assert [req["method"] for req in app.requests] == expected


def test_cli_command_surface():
    methods = []

    def handler(req, _count):
        method = req["method"]
        methods.append(method)
        params = req.get("params") or {}
        if method == "app.ping":
            return response(req, {"pong": True, "protocol": 1, "socket": "/tmp/fake.sock"})
        if method == "app.status":
            return response(req, {
                "app": "Conductor",
                "version": "test",
                "protocol": 1,
                "active": {"workspace": "w1", "tab": "t1", "pane": "p1"},
                "counts": {"workspaces": 1, "tabs": 1, "panes": 1, "runningAgents": 0, "activities": 1},
                "methods": ["app.ping", "agent.run"],
            })
        if method == "app.methods":
            return response(req, ["app.ping", "app.status", "agent.run"])
        if method == "workspace.list":
            return response(req, [{"id": "w1", "name": "Main", "path": "/tmp/main", "active": True, "tabs": 1}])
        if method == "workspace.current":
            return response(req, {"id": "w1", "name": "Main", "path": "/tmp/main", "active": True, "tabs": 1})
        if method == "workspace.select":
            assert params == {"workspace": "w1"}, params
            return response(req, True)
        if method == "workspace.close":
            assert params == {"workspace": "w-close"}, params
            return response(req, True)
        if method == "workspace.status.clear":
            assert params == {"workspace": "w1", "key": "build"}, params
            return response(req, True)
        if method == "workspace.status.list":
            assert params == {"workspace": "w1"}, params
            return response(req, [{"key": "build", "text": "ok", "color": "#00ff00", "icon": "checkmark"}])
        if method == "workspace.progress.clear":
            assert params == {"workspace": "w1"}, params
            return response(req, True)
        if method == "workspace.log.list":
            assert params == {"workspace": "w1", "limit": 2}, params
            return response(req, [{"time": 1.0, "level": "info", "source": "test", "text": "log"}])
        if method == "workspace.log.clear":
            assert params == {"workspace": "w1"}, params
            return response(req, True)
        if method == "tab.list":
            assert params == {"workspace": "w1"}, params
            return response(req, [{"id": "t1", "index": 1, "title": "Main", "active": True, "panes": []}])
        if method == "tab.select":
            assert params == {"tab": "t1", "workspace": "w1"}, params
            return response(req, True)
        if method == "tab.close":
            assert params == {"tab": "t-close", "workspace": "w1"}, params
            return response(req, True)
        if method == "pane.list":
            return response(req, [{"id": "p1", "title": "shell", "cwd": "/tmp/main", "active": True, "thinking": False}])
        if method == "pane.create":
            assert params == {"cwd": "/tmp/main"}, params
            return response(req, {"tab": "t-new", "pane": "p-new"})
        if method == "pane.focus":
            assert params == {"pane": "p1"}, params
            return response(req, True)
        if method == "pane.read":
            assert params == {"pane": "p1", "scrollback": True}, params
            return response(req, {"text": "screen text"})
        if method == "agent.send":
            assert params == {"pane": "p1", "text": "hello", "submit": True}, params
            return response(req, True)
        if method == "agent.run":
            assert params == {"agent": "codex", "command": "printf hi", "cwd": "/tmp/main", "prompt": "prompt", "submit": False}, params
            return response(req, {"pane": "p-run", "jobId": "p-run", "agent": "codex"})
        if method == "agent.status":
            assert params == {"job": "p-run"}, params
            return response(req, {"jobId": "p-run", "pane": "p-run", "agent": "codex", "status": "completed"})
        if method == "agent.result":
            assert params == {"job": "p-run"}, params
            return response(req, {"jobId": "p-run", "pane": "p-run", "agent": "codex", "status": "completed", "summary": "ok", "markdown": "ok"})
        if method == "activity.list":
            assert params == {"limit": 1} or params == {"limit": 20}, params
            return response(req, [{"id": "act1", "time": 1.0, "title": "Done", "message": "activity", "status": "completed"}])
        if method == "events.recent":
            assert params == {"limit": 1}, params
            return response(req, [{"id": "evt1", "type": "agent.completed", "topic": "agent.completed", "time": 1.0, "payload": {"message": "event"}}])
        if method == "custom.echo":
            assert params == {"hello": "world"}, params
            return response(req, {"echo": True})
        return error_response(req, "unexpected", method)

    expected_calls = 27
    with FakeAppSocket("conductorctl-surface", expected_calls, handler) as app:
        assert "conductorctl:" in subprocess.check_output([BIN, "--help"], cwd=ROOT, text=True)
        assert "Conductor OK" in run_cli(["ping"], app)
        run_cli(["status", "--json"], app)
        run_cli(["methods"], app)
        raw = run_cli(["raw", "custom.echo", '{"hello":"world"}'], app)
        assert json.loads(raw)["echo"] is True
        run_cli(["workspace", "list"], app)
        run_cli(["workspace", "current"], app)
        run_cli(["workspace", "select", "w1"], app)
        run_cli(["workspace", "close", "w-close"], app)
        run_cli(["workspace", "status", "list", "--workspace", "w1"], app)
        run_cli(["workspace", "status", "clear", "build", "--workspace", "w1"], app)
        run_cli(["workspace", "progress", "clear", "--workspace", "w1"], app)
        run_cli(["workspace", "log", "list", "--workspace", "w1", "--limit", "2"], app)
        run_cli(["workspace", "log", "clear", "--workspace", "w1"], app)
        run_cli(["tab", "list", "--workspace", "w1"], app)
        run_cli(["tab", "select", "t1", "--workspace", "w1"], app)
        run_cli(["tab", "close", "t-close", "--workspace", "w1"], app)
        run_cli(["pane", "list"], app)
        run_cli(["pane", "create", "--cwd", "/tmp/main", "--json"], app)
        run_cli(["pane", "focus", "p1"], app)
        assert "screen text" in run_cli(["screen", "--pane", "p1", "--scrollback"], app)
        run_cli(["send", "--pane", "p1", "hello"], app)
        run_cli(["run", "codex", "--command", "printf hi", "--cwd", "/tmp/main", "--prompt", "prompt", "--no-submit", "--json"], app)
        run_cli(["agent", "status", "p-run", "--json"], app)
        run_cli(["agent", "result", "p-run", "--json"], app)
        run_cli(["activity", "--limit", "1", "--json"], app)
        event_line = run_cli_first_line(["events", "--limit", "1", "--interval", "0.25", "--jsonl"], app)
        assert json.loads(event_line)["id"] == "evt1"
        watch_line = run_cli_first_line(["watch", "--interval", "0.25", "--jsonl"], app)
        assert json.loads(watch_line)["id"] == "act1"
        assert len(app.requests) >= expected_calls, len(app.requests)


def main():
    test_run_wait()
    print("run-wait ok")
    test_stdin_and_batch()
    print("stdin-batch ok")
    test_bridge_http()
    print("bridge-http ok")
    test_resource_commands()
    print("resource-commands ok")
    test_cli_command_surface()
    print("cli-command-surface ok")


main()
PY
