import base64
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

SCRIPT = Path(__file__).resolve().parents[1] / 'tools/codex-account'
loader = importlib.machinery.SourceFileLoader('accounts', str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)


def auth(user, version=1):
    claims = base64.urlsafe_b64encode(json.dumps({'sub': user, 'email': user + '@example.test'}).encode()).decode().rstrip('=')
    return json.dumps({'tokens': {'id_token': 'x.' + claims + '.x', 'access_token': 'fake-' + str(version), 'account_id': 'workspace'}}).encode()


class AccountsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.addCleanup(patch.stopall)
        patch.object(m, 'ROOT', self.base / '.codex-accounts').start()
        patch.object(m, 'CURRENT', m.ROOT / 'current').start()
        patch.object(m, 'APP', self.base / 'MissingChatGPT.app').start()
        patch.object(m.Path, 'home', return_value=self.base).start()
        patch.object(m.shutil, 'which', return_value='/fake/codex').start()
        patch('builtins.print').start()
        legacy = self.base / '.codex'
        legacy.mkdir()
        (legacy / 'auth.json').write_bytes(auth('original'))
        m.initialize()
        m.save('1')

    def fake_login(self, raw=None, code=0):
        def run(argv, env):
            staging = Path(env['CODEX_HOME'])
            self.assertNotEqual(staging, m.home('1'))
            self.assertFalse((staging / 'auth.json').exists())
            self.assertIn('cli_auth_credentials_store="file"', argv)
            if raw is not None:
                (staging / 'auth.json').write_bytes(raw)
            return SimpleNamespace(returncode=code)
        return patch.object(m.subprocess, 'run', side_effect=run)

    def test_original_account_uses_live_original_store(self):
        (self.base / '.codex/auth.json').write_bytes(auth('changed'))
        m.initialize()
        self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('changed'))
        self.assertEqual(m.home('1'), self.base / '.codex')
        self.assertFalse((m.home('1') / 'auth.json').is_symlink())
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in (m.ROOT / '.backups/1').glob('*.json')))

    def test_add_preserves_all_existing(self):
        with self.fake_login(auth('second')) as run:
            m.add('second')
        self.assertIn('--device-auth', run.call_args.args[0])
        self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('original'))
        self.assertEqual((m.home('second') / 'auth.json').read_bytes(), auth('second'))
        self.assertEqual(m.current(), 'second')

    def test_failed_add_leaves_no_account_or_selection_change(self):
        with self.fake_login(auth('partial'), 1), self.assertRaises(SystemExit):
            m.add('failed')
        self.assertEqual(m.accounts(), ['1'])
        self.assertEqual(m.current(), '1')
        self.assertEqual(list(m.ROOT.glob('.login-*')), [])

    def test_failed_relogin_retains_original(self):
        with self.fake_login(auth('partial'), 1), self.assertRaises(SystemExit):
            m.launch('1', ['login'])
        self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('original'))

    def test_cancel_retains_original(self):
        with patch.object(m.subprocess, 'run', side_effect=KeyboardInterrupt), self.assertRaises(KeyboardInterrupt):
            m.launch('1', ['login'])
        self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('original'))
        self.assertEqual(list(m.ROOT.glob('.login-*')), [])

    def test_missing_or_malformed_auth_is_not_committed(self):
        for raw in (None, b'not json', b'{}', b'[]'):
            with self.fake_login(raw), self.assertRaises(ValueError):
                m.add('bad')
            self.assertFalse(m.home('bad').exists())
            self.assertEqual(m.current(), '1')

    def test_other_user_relogin_creates_separate_account(self):
        with self.fake_login(auth('second')):
            m.launch('1', ['login'])
        self.assertNotEqual(m.current(), '1')
        self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('original'))
        self.assertEqual((m.home(m.current()) / 'auth.json').read_bytes(), auth('second'))

    def test_same_user_add_updates_existing_with_backup(self):
        with self.fake_login(auth('original', 2)):
            m.add('duplicate')
        self.assertEqual(m.accounts(), ['1'])
        self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('original', 2))
        copies = [p.read_bytes() for p in (m.ROOT / '.backups/1').glob('*.json')]
        self.assertIn(auth('original'), copies)
        self.assertIn(auth('original', 2), copies)

    def test_restore_missing_only(self):
        with self.assertRaises(ValueError):
            m.restore('1')
        (m.home('1') / 'auth.json').unlink()
        m.restore('1')
        self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('original'))

    def test_all_launches_use_separate_file_store(self):
        with patch.object(m.os, 'execv') as execute, patch.dict(m.os.environ):
            m.launch('1', ['login', 'status'])
            self.assertEqual(m.os.environ['CODEX_HOME'], str(m.home('1')))
            self.assertEqual(execute.call_args.args[1], ['/fake/codex', '-c', 'cli_auth_credentials_store="file"', 'login', 'status'])

    def test_duplicate_name_does_not_start_login(self):
        with patch.object(m.subprocess, 'run') as run, self.assertRaises(ValueError):
            m.add('1')
        run.assert_not_called()

    def test_picker_only_selects_without_launch_or_login(self):
        m.atomic_write(m.home('second') / 'auth.json', auth('second'))
        with patch.object(m.sys, 'argv', ['codex-account']), patch.object(m, 'picker', return_value='second'), patch.object(m, 'launch') as launch, patch.object(m.subprocess, 'run') as run:
            m.main()
        self.assertEqual(m.current(), 'second')
        launch.assert_not_called()
        run.assert_not_called()
        self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('original'))

    def test_plain_codex_routes_to_selected_account(self):
        m.atomic_write(m.home('second') / 'auth.json', auth('second'))
        m.save('second')
        with patch.object(m.sys, 'argv', ['codex', '--version']), patch.object(m, 'launch') as launch:
            m.main()
        launch.assert_called_once_with('second', ['--version'])

    def test_switch_back_retains_refreshed_credentials(self):
        m.atomic_write(m.home('second') / 'auth.json', auth('second'))
        observed = []
        def execute(binary, args):
            path = Path(m.os.environ['CODEX_HOME']) / 'auth.json'
            observed.append(path.read_bytes())
            if path.parent == m.home('1'):
                path.write_bytes(auth('original', 2))
            else:
                path.write_bytes(auth('second', 2))
        with patch.object(m.os, 'execv', side_effect=execute), patch.dict(m.os.environ):
            for name in ('1', 'second', '1', 'second'):
                m.save(name)
                m.launch(m.current(), [])
        self.assertEqual(observed, [auth('original'), auth('second'), auth('original', 2), auth('second', 2)])

    def test_duplicate_migration_has_one_live_home(self):
        (m.ROOT / '.switcher-v2').unlink()
        m.atomic_write(m.ROOT / '1/auth.json', auth('original'))
        m.atomic_write(m.ROOT / 'duplicate/auth.json', auth('original', 2))
        m.save('duplicate')
        m.initialize()
        self.assertEqual(m.accounts(), ['1'])
        self.assertEqual(m.home('duplicate'), m.home('1'))
        self.assertEqual(m.current(), '1')
        (m.home('1') / 'auth.json').write_bytes(auth('original', 3))
        m.initialize()
        self.assertEqual((m.home('duplicate') / 'auth.json').read_bytes(), auth('original', 3))

    def test_migration_preserves_different_default_accounts(self):
        (m.ROOT / '.switcher-v2').unlink()
        m.atomic_write(m.ROOT / '1/auth.json', auth('another'))
        m.initialize()
        identities = {m.identity((m.home(name) / 'auth.json').read_bytes()) for name in m.accounts()}
        self.assertEqual(identities, {m.identity(auth('original')), m.identity(auth('another'))})

    def test_binary_resolution_skips_switcher(self):
        shim = self.base / 'shim'
        shim.mkdir()
        (shim / 'codex').symlink_to(SCRIPT)
        with patch.object(m.os, 'get_exec_path', return_value=[str(shim), '/usr/bin']), patch.object(m.shutil, 'which', return_value='/usr/bin/codex') as which:
            m.codex_binary()
        self.assertNotIn(str(shim), which.call_args.kwargs['path'].split(':'))

    def test_real_shim_switches_and_reuses_each_live_store(self):
        bin_dir = self.base / 'bin'
        real_dir = self.base / 'real-bin'
        bin_dir.mkdir()
        real_dir.mkdir()
        wrapper = bin_dir / 'codex-account'
        wrapper.write_text(SCRIPT.read_text().replace("APP = Path('/Applications/ChatGPT.app')", "APP = Path('/nonexistent-test-ChatGPT.app')"))
        wrapper.chmod(0o700)
        (bin_dir / 'codex').symlink_to(wrapper)
        real = real_dir / 'codex'
        real.write_text('#!' + m.sys.executable + '\n' +
            'import json, os\nfrom pathlib import Path\n' +
            'p = Path(os.environ["CODEX_HOME"]) / "auth.json"\n' +
            'd = json.loads(p.read_bytes())\n' +
            'n = d.get("fake_refresh_count", 0) + 1\n' +
            'd["fake_refresh_count"] = n\np.write_text(json.dumps(d))\nprint(n)\n')
        real.chmod(0o700)
        m.atomic_write(m.home('second') / 'auth.json', auth('second'))
        env = dict(m.os.environ, HOME=str(self.base), PATH=str(bin_dir) + ':' + str(real_dir) + ':' + m.os.environ['PATH'])
        counts = []
        for name in ('1', 'second', '1', 'second'):
            m.subprocess.run([str(wrapper), 'switch', name], env=env, check=True, capture_output=True)
            result = m.subprocess.run([str(bin_dir / 'codex')], env=env, check=True, capture_output=True, text=True)
            counts.append(result.stdout.strip())
        self.assertEqual(counts, ['1', '1', '2', '2'])

    def test_list_json_reports_accounts_and_auth_paths(self):
        m.atomic_write(m.home('second') / 'auth.json', auth('second'))
        with patch.object(m.sys, 'argv', ['codex-account', 'list', '--json']), patch('builtins.print') as output:
            m.main()
        accounts = json.loads(output.call_args.args[0])
        self.assertEqual([(a['name'], a['label'], a['current']) for a in accounts],
                         [('1', 'original@example.test', True), ('second', 'second@example.test', False)])
        self.assertEqual(accounts[0]['auth'], str(self.base / '.codex/auth.json'))

    def test_status_checks_the_account_returned_by_codex(self):
        with patch.object(m, 'account_info', return_value={'type': 'chatgpt', 'email': 'original@example.test'}) as read:
            m.status()
        read.assert_called_once_with('1')

    def test_status_rejects_a_different_actual_account(self):
        with patch.object(m, 'account_info', return_value={'type': 'chatgpt', 'email': 'wrong@example.test'}), self.assertRaises(ValueError):
            m.status()

    def test_status_reports_missing_actual_login(self):
        with patch.object(m, 'account_info', return_value=None), self.assertRaises(ValueError):
            m.status()

    def test_desktop_roundtrip_preserves_app_refresh_and_shared_settings(self):
        config = self.base / '.codex/config.toml'
        config.write_text('model = "example"\n[features]\nexample = true\n')
        session = self.base / '.codex/sessions/keep.jsonl'
        session.parent.mkdir()
        session.write_text('keep')
        m.atomic_write(m.home('second') / 'auth.json', auth('second'))
        with patch.object(m, 'stop_desktop', return_value=True), patch.object(m, 'start_desktop') as start:
            m.switch_desktop('second')
            self.assertEqual(m.home('second'), self.base / '.codex')
            self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('original'))
            (self.base / '.codex/auth.json').write_bytes(auth('second', 2))
            m.switch_desktop('1')
            self.assertEqual((self.base / '.codex/auth.json').read_bytes(), auth('original'))
            m.switch_desktop('second')
        self.assertEqual((self.base / '.codex/auth.json').read_bytes(), auth('second', 2))
        self.assertEqual(start.call_count, 3)
        self.assertEqual(session.read_text(), 'keep')
        self.assertIn('model = "example"\n[features]\nexample = true\n', config.read_text())
        self.assertEqual(config.read_text().count('cli_auth_credentials_store'), 1)

    def test_desktop_quit_failure_does_not_change_selection_or_auth(self):
        m.atomic_write(m.home('second') / 'auth.json', auth('second'))
        with patch.object(m, 'stop_desktop', side_effect=ValueError('quit failed')), self.assertRaises(ValueError):
            m.switch_desktop('second')
        self.assertEqual(m.current(), '1')
        self.assertIsNone(m.desktop_account())
        self.assertEqual((self.base / '.codex/auth.json').read_bytes(), auth('original'))

    def test_desktop_failed_probe_rolls_back_and_reopens(self):
        binary = m.APP / 'Contents/Resources/codex'
        binary.parent.mkdir(parents=True)
        binary.touch()
        m.atomic_write(m.home('second') / 'auth.json', auth('second'))
        with patch.object(m, 'stop_desktop', return_value=True), patch.object(m, 'start_desktop') as start, patch.object(m, 'account_info', return_value={'type': 'chatgpt', 'email': 'wrong@example.test'}), self.assertRaises(ValueError):
            m.switch_desktop('second')
        start.assert_called_once()
        self.assertEqual(m.current(), '1')
        self.assertIsNone(m.desktop_account())
        self.assertFalse((self.base / '.codex/config.toml').exists())
        self.assertEqual((self.base / '.codex/auth.json').read_bytes(), auth('original'))
        self.assertEqual((m.home('second') / 'auth.json').read_bytes(), auth('second'))

    def test_app_side_login_preserves_previous_account_and_tracks_new_one(self):
        m.switch_desktop('1')
        (self.base / '.codex/auth.json').write_bytes(auth('app-login'))
        m.initialize()
        self.assertNotEqual(m.current(), '1')
        self.assertEqual((m.home('1') / 'auth.json').read_bytes(), auth('original'))
        self.assertEqual((m.home(m.current()) / 'auth.json').read_bytes(), auth('app-login'))
        m.switch_desktop('1')
        self.assertEqual((self.base / '.codex/auth.json').read_bytes(), auth('original'))

    def test_missing_live_auth_does_not_resurrect_archived_login(self):
        m.switch_desktop('1')
        (self.base / '.codex/auth.json').unlink()
        m.initialize()
        self.assertFalse((self.base / '.codex/auth.json').exists())
        with self.assertRaises(FileNotFoundError):
            m.switch_desktop('1')

    def test_newer_cli_refresh_is_preserved_during_reconciliation(self):
        m.atomic_write(m.home('second') / 'auth.json', auth('second'))
        m.switch_desktop('second')
        refreshed = json.loads(auth('second', 3))
        refreshed['last_refresh'] = '2099-01-01T00:00:00Z'
        raw = json.dumps(refreshed).encode()
        (m.ROOT / 'second/auth.json').write_bytes(raw)
        m.initialize()
        self.assertEqual((m.ROOT / 'second/auth.json').read_bytes(), raw)
        m.switch_desktop('second')
        self.assertEqual((self.base / '.codex/auth.json').read_bytes(), raw)

    def test_file_store_configuration_preserves_tables_and_comments(self):
        import tomllib
        for original in (b'', b'# comment\n[features]\nx = true\n',
                         b'cli_auth_credentials_store = "keyring" # old\n[features]\nx = true\n',
                         b'"cli_auth_credentials_store" = "auto"\n'):
            result = m.file_store_config(original)
            self.assertEqual(tomllib.loads(result.decode())['cli_auth_credentials_store'], 'file')
            self.assertEqual(m.file_store_config(result), result)


if __name__ == '__main__':
    unittest.main()
