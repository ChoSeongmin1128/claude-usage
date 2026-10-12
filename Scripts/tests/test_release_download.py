import importlib.util
import os
import socket
import ssl
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import threading
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location('release_download', Path(__file__).parents[1] / 'lib/release_download.py')
download = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = download
SPEC.loader.exec_module(download)


class ReleaseDownloadTests(unittest.TestCase):
    def test_reap_waits_share_one_finite_termination_deadline(self):
        process = Mock(pid=123)
        process.wait.side_effect = subprocess.TimeoutExpired('fixture', 0)
        started = time.monotonic()
        with patch.object(download.os, 'killpg'):
            with self.assertRaises(download.DownloadTimeout):
                download.stop_transfer(process, 0.1)
        self.assertLess(time.monotonic() - started, 0.2)
        self.assertEqual(process.wait.call_count, 2)
        for call in process.wait.call_args_list:
            self.assertGreaterEqual(call.kwargs['timeout'], 0)
            self.assertLessEqual(call.kwargs['timeout'], 0.1)

    def test_stalled_transfer_and_owned_descendant_are_stopped(self):
        with tempfile.TemporaryDirectory() as directory:
            child_pid = Path(directory) / 'child'
            program = (
                'import subprocess,sys,time\n'
                'p=subprocess.Popen([sys.executable,"-c","import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)"])\n'
                'open(sys.argv[1],"w").write(str(p.pid))\n'
                'time.sleep(30)\n')
            policy = download.DownloadPolicy(attempt_seconds=0.2, total_seconds=0.3, termination_seconds=0.1)
            started = time.monotonic()
            result = download.run_transfer([sys.executable, '-c', program, str(child_pid)], dict(os.environ),
                                           started + policy.total_seconds, policy)
            self.assertEqual(result, 124)
            self.assertLess(time.monotonic() - started, 2)
            pid = int(child_pid.read_text())
            status = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
            self.assertEqual(status.stderr, "")
            self.assertTrue(status.returncode != 0 or status.stdout.strip().startswith('Z'), status.stdout)

    def test_deadline_is_shared_between_github_and_direct_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'gh').write_text('#!/bin/sh\nsleep 30\n')
            (root / 'curl').write_text('#!/bin/sh\nsleep 30\n')
            for executable in [root / 'gh', root / 'curl']:
                executable.chmod(0o700)
            policy = download.DownloadPolicy(attempt_seconds=0.2, total_seconds=0.3, termination_seconds=0.1)
            with patch.dict(os.environ, {'PATH': str(root) + os.pathsep + os.environ['PATH']}):
                started = time.monotonic()
                with self.assertRaises(download.DownloadTimeout):
                    download.download_asset('Fixture/Repo', 'v1', 'app.zip', root / 'out/app.zip', policy=policy)
                self.assertLess(time.monotonic() - started, 2)
            self.assertFalse((root / 'out/app.zip').exists())
            self.assertEqual(list((root / 'out').iterdir()), [])

    def test_fallback_never_receives_github_token_or_keeps_failed_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'gh').write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
assert os.environ['GH_TOKEN']=='fixture-token'
destination=Path(sys.argv[sys.argv.index('--dir')+1])
(destination/'app.zip').write_bytes(b'partial')
raise SystemExit(1)
''')
            (root / 'curl').write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
assert 'GH_TOKEN' not in os.environ and 'GITHUB_TOKEN' not in os.environ
Path(sys.argv[sys.argv.index('--output')+1]).write_bytes(b'verified-download')
''')
            for executable in [root / 'gh', root / 'curl']:
                executable.chmod(0o700)
            with patch.dict(os.environ, {'PATH': str(root) + os.pathsep + os.environ['PATH'],
                                         'GH_TOKEN': 'ambient-token', 'GITHUB_TOKEN': 'ambient-other'}):
                download.download_asset('Fixture/Repo', 'v1', 'app.zip', root / 'out/app.zip', token='fixture-token')
            self.assertEqual((root / 'out/app.zip').read_bytes(), b'verified-download')
            self.assertEqual([p.name for p in (root / 'out').iterdir()], ['app.zip'])

    def test_failed_curl_does_not_publish_partial_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'curl').write_text('''#!/usr/bin/env python3
import sys
from pathlib import Path
Path(sys.argv[sys.argv.index('--output')+1]).write_bytes(b'partial')
raise SystemExit(18)
''')
            (root / 'curl').chmod(0o700)
            with patch.dict(os.environ, {'PATH': str(root) + os.pathsep + os.environ['PATH']}):
                with self.assertRaises(RuntimeError):
                    download.download_asset('Fixture/Repo', 'v1', 'app.zip', root / 'out/app.zip', stale_index=True)
            self.assertFalse((root / 'out/app.zip').exists())

    def test_actual_curl_stalled_tls_body_obeys_shared_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            certificate, key = root / 'certificate.pem', root / 'key.pem'
            subprocess.run(
                ['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                 '-subj', '/CN=localhost', '-addext', 'subjectAltName=IP:127.0.0.1',
                 '-keyout', str(key), '-out', str(certificate)], capture_output=True, check=True)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)
            stop = threading.Event()
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            listener.settimeout(0.1)
            port = listener.getsockname()[1]

            def serve():
                while not stop.is_set():
                    try:
                        connection, _ = listener.accept()
                        with context.wrap_socket(connection, server_side=True) as secure:
                            secure.recv(4096)
                            secure.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n')
                            stop.wait(2)
                    except (OSError, ssl.SSLError):
                        pass

            server = threading.Thread(target=serve)
            server.start()
            wrapper = root / 'curl'
            wrapper.write_text('''#!/usr/bin/env python3
import os,sys
args=sys.argv[1:-1]+['--cacert',os.environ['FIXTURE_CERT'],'--noproxy','*',os.environ['FIXTURE_URL']]
os.execv('/usr/bin/curl',['curl',*args])
''')
            wrapper.chmod(0o700)
            try:
                with patch.dict(os.environ, {'PATH': str(root) + os.pathsep + os.environ['PATH'],
                                             'FIXTURE_CERT': str(certificate),
                                             'FIXTURE_URL': f'https://127.0.0.1:{port}/asset'}):
                    started = time.monotonic()
                    with self.assertRaises(download.DownloadTimeout):
                        download.download_asset(
                            'Fixture/Repo', 'v1', 'app.zip', root / 'out/app.zip', stale_index=True,
                            policy=download.DownloadPolicy(attempt_seconds=0.4, total_seconds=0.5,
                                                           termination_seconds=0.1))
                    self.assertLess(time.monotonic() - started, 2)
                    self.assertFalse((root / 'out/app.zip').exists())
            finally:
                stop.set()
                listener.close()
                server.join(timeout=2)
                self.assertFalse(server.is_alive())


if __name__ == '__main__':
    unittest.main()
