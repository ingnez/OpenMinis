#!/usr/bin/env python3
"""Diagnose only the CI Agent child process using fake data and loopback."""
from collections import deque
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.request import ProxyHandler, build_opener

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'cloud-agent'))
from test_phase1_support import FakeModelHandler, _serve


def clean(text):
    return re.sub(r'/Users/[^/\s]+', '/Users/[redacted]', text)


def main():
    lines = deque(maxlen=120)
    model, _ = _serve(FakeModelHandler)
    try:
        with tempfile.TemporaryDirectory(prefix='openminis-startup-', dir=os.environ.get('RUNNER_TEMP')) as folder:
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            env = dict(os.environ, OPENMINIS_HOST='127.0.0.1', OPENMINIS_PORT=str(port),
                       OPENMINIS_DB=str(Path(folder) / 'agent.db'),
                       OPENMINIS_WORKSPACE=str(Path(folder) / 'workspace'),
                       OPENMINIS_MASTER_KEY_FILE=str(Path(folder) / 'master.key'),
                       OPENMINIS_TOKEN='ci-startup-fake-token', no_proxy='localhost,127.0.0.1,::1')
            args = [sys.executable, '-u', '-X', 'importtime', str(ROOT / 'cloud-agent/cloud_agent_server.py')]
            started = time.monotonic()
            process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            def read():
                for line in process.stdout:
                    lines.append(clean(line.rstrip()))
            reader = threading.Thread(target=read, daemon=True)
            reader.start()
            opener = build_opener(ProxyHandler({}))
            sampled = False
            try:
                while time.monotonic() - started < 60:
                    elapsed = time.monotonic() - started
                    try:
                        with opener.open(f'http://127.0.0.1:{port}/health', timeout=1) as response:
                            result = json.load(response)
                        print(f'AGENT_READY elapsed={elapsed:.3f}s status={response.status}', flush=True)
                        return
                    except OSError:
                        pass
                    if process.poll() is not None:
                        raise RuntimeError(f'Agent exited with code {process.returncode}')
                    if elapsed >= 10 and not sampled:
                        sampled = True
                        if sys.platform == 'darwin':
                            try:
                                sample = subprocess.run(['sample', str(process.pid), '1', '1', '-file', '/dev/stdout'],
                                                        capture_output=True, text=True, timeout=10)
                                text = sample.stdout
                                if 'Call graph:' in text:
                                    text = text.split('Call graph:', 1)[1].split('Binary Images:', 1)[0]
                                print('CHILD_STACK\n' + clean(text[:12000]), flush=True)
                            except subprocess.TimeoutExpired:
                                print('Child stack capture timed out.', flush=True)
                    print(f'STARTUP_WAIT elapsed={elapsed:.1f}s output_lines={len(lines)}', flush=True)
                    time.sleep(1)
                raise RuntimeError('Agent did not become ready within 60 seconds')
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                reader.join(timeout=2)
                print('CHILD_IMPORT_TAIL\n' + '\n'.join(lines), flush=True)
    finally:
        model.shutdown()
        model.server_close()


if __name__ == '__main__':
    main()
