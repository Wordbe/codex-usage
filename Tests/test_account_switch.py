"""Exercise the real CLI against a local, deterministic app-server fixture.

Run after swift build: python3 -m unittest discover -s Tests -p 'test_*.py'
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / '.build/debug/codexusage'
SERVER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if '--version' in sys.argv:
    print('codex-cli test')
    raise SystemExit()
assert os.environ['CODEX_HOME'] == os.environ['HOME'] + '/.codex'
state = json.loads((Path(os.environ['HOME']) / 'server.json').read_text())
initialized = False
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method == 'initialize':
        if state.get('init_error'):
            print(json.dumps({'id': request['id'], 'error': {'message': 'initialization rejected'}}), flush=True)
            continue
        result = {}
    elif method == 'initialized':
        initialized = True
        continue
    elif method == 'account/read':
        assert initialized
        result = {'account': {'type': 'chatgpt', 'email': state['email'], 'planType': 'pro'}}
    elif method == 'account/rateLimits/read':
        if state.get('switch_to'):
            (Path(os.environ['CODEX_HOME']) / 'auth.json').write_text(json.dumps(state['switch_to']))
        if state.get('error'):
            print(json.dumps({'id': request['id'], 'error': {'message': 'quota unavailable'}}), flush=True)
            continue
        result = {'rateLimits': {'limitId': 'codex', 'primary': state.get('primary'), 'secondary': None}}
    else:
        raise RuntimeError(method)
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
'''


def auth(user, workspace='workspace'):
    payload = base64.urlsafe_b64encode(json.dumps({'sub': user, 'email': user + '@example.test'}).encode()).decode().rstrip('=')
    return {'tokens': {'id_token': 'x.' + payload + '.x', 'access_token': 'fake', 'account_id': workspace}}


class AccountSwitchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / '.codex').mkdir()
        server = self.home / 'codex-fixture'
        server.write_text(SERVER)
        server.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), CODEX_HOME='/ignored/inherited/home', CODEXUSAGE_CODEX_PATH=str(server))
        self.select('a')

    def select(self, user, workspace='workspace', **overrides):
        (self.home / '.codex/auth.json').write_text(json.dumps(auth(user, workspace)))
        state = {'email': user + '@example.test', 'primary': {'usedPercent': 23, 'windowDurationMins': 300, 'resetsAt': 4102444800}}
        state.update(overrides)
        (self.home / 'server.json').write_text(json.dumps(state))

    def run_status(self, *args):
        return subprocess.run([str(BINARY), 'status', '--json', *args], env=self.env, capture_output=True, text=True, timeout=12)

    def test_fresh_read_ignores_session_and_legacy_cache(self):
        sessions = self.home / '.codex/sessions'
        sessions.mkdir()
        (sessions / 'old.jsonl').write_text(json.dumps({'type': 'event_msg', 'timestamp': '2099-01-01T00:00:00Z', 'payload': {'type': 'token_count', 'rate_limits': {'primary': {'used_percent': 99, 'window_minutes': 300, 'resets_at': 4102444800}}}}) + '\n')
        result = self.run_status('--refresh')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['usedPercent'], 23)
        self.assertEqual(data['accountEmail'], 'a@example.test')
        self.assertEqual(data['dataSource'], 'fresh')

    def test_new_account_does_not_use_old_cache_on_failure(self):
        self.assertEqual(self.run_status().returncode, 0)
        self.select('b', error=True)
        result = self.run_status()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('quota unavailable', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_same_email_different_workspace_has_separate_cache(self):
        self.assertEqual(self.run_status().returncode, 0)
        self.select('a', workspace='other-workspace', error=True)
        self.assertNotEqual(self.run_status().returncode, 0)

    def test_late_response_is_discarded_after_switch(self):
        self.select('a', switch_to=auth('b'))
        result = self.run_status('--refresh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('changed', result.stderr)
        self.assertEqual(list((self.home / '.codexusage').glob('cache/accounts/*.json')), [])

    def test_refresh_bypasses_cache_and_stale_fallback_stays_same_account(self):
        first = self.run_status()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.select('a', primary={'usedPercent': 57, 'windowDurationMins': 300})
        self.assertEqual(json.loads(self.run_status().stdout)['usedPercent'], 23)
        self.assertEqual(json.loads(self.run_status('--refresh').stdout)['usedPercent'], 57)
        self.select('a', error=True)
        data = json.loads(self.run_status('--refresh').stdout)
        self.assertEqual(data['dataSource'], 'stale-cache')
        self.assertEqual(data['usedPercent'], 57)

    def test_missing_quota_is_null_not_zero(self):
        self.select('a', primary=None)
        result = self.run_status('--refresh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)['usedPercent'])
        self.assertIsNone(json.loads(result.stdout)['remainingPercent'])

    def test_logout_does_not_reuse_cache(self):
        self.assertEqual(self.run_status().returncode, 0)
        (self.home / '.codex/auth.json').unlink()
        self.assertNotEqual(self.run_status().returncode, 0)

    def test_initialization_error_is_reported(self):
        self.select('a', init_error=True)
        result = self.run_status('--refresh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('initialization rejected', result.stderr)


if __name__ == '__main__':
    unittest.main()
