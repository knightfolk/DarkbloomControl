#!/usr/bin/env python3
"""Synthetic byte/EOF process protocol smoke; native TLS is checked separately."""
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import threading
import time

script = Path(__file__).with_name("run.sh")
with socket.socket() as target:
    target.bind(("127.0.0.1", 0))
    target.listen(1)
    target.settimeout(20)
    failures = []

    def echo():
        try:
            conn, _ = target.accept()
            with conn:
                conn.settimeout(5)
                data = conn.recv(4096)
                conn.sendall(data[::-1])
        except Exception as error:
            failures.append(str(error))

    worker = threading.Thread(target=echo, daemon=True)
    worker.start()
    environment = dict(os.environ, SPIKE_TARGET_PORT=str(target.getsockname()[1]))
    process = subprocess.Popen([str(script)], env=environment, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(20), "readiness deadline exceeded"
        ready = json.loads(process.stdout.readline())
        with socket.create_connection(("127.0.0.1", ready["port"]), timeout=5) as client:
            client.sendall(b"opaque-process-check")
            assert client.recv(4096) == b"kcehc-ssecorp-euqapo"
        start = time.monotonic()
        process.stdin.close()
        process.wait(timeout=10)
        elapsed = time.monotonic() - start
        assert process.returncode == 0, process.stderr.read()
        assert process.stdout.read() == "", "extra protocol stdout"
        worker.join(timeout=1)
        assert not failures, failures
        print(json.dumps({"processRoundTrip": "pass", "stdinEOFCleanup": "pass",
                          "shutdownSeconds": round(elapsed, 3), "extraStdoutBytes": 0}))
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
