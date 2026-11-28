"""The release controller derives only explicit, local project bindings."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

FILES = Path(__file__).resolve().parents[1] / 'ansible/files'
sys.path.insert(0, str(FILES))
import research_ops_overview_roots as derive

PROJECT = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'


def invocation(*args):
    # The remaining D-Bus tuple fields are execution timestamps and status, not configuration.
    return {'data': [['/usr/bin/python3', ['/usr/bin/python3', '/app/control-plane/bridge/observe.py',
                    '--credentials', '/not-a-source-of-bindings.env', *args], False, 0, 0, 0, 0, 0, 0, 0]]}


class OverviewRootsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.base = Path(directory.name).resolve()

    def config(self, name, content):
        root = self.base / name
        (root / '.claude').mkdir(parents=True)
        (root / '.claude/research-ops.toml').write_text(content)
        return root

    def test_resolves_actual_roots_and_does_not_read_credentials(self):
        root = self.config("quote ' and spaces", f'[control_plane]\nproject="{PROJECT}"\nbridge="local"\ncredentials="/not-readable"')
        also = self.base / 'symlink'
        also.symlink_to(root, target_is_directory=True)
        self.assertEqual(derive.bindings(invocation('--project-root', str(root), f'--project-root={also}'), 'local'),
                         [{'host':'local', 'root':str(root), 'project_id':PROJECT}])

    def test_unregistered_remains_unmapped(self):
        root = self.config('no-project', '[recording]\nmode="on"')
        plain = self.base / 'absent-config'
        plain.mkdir()
        self.assertEqual(derive.bindings(invocation('--project-root', str(plain), '--project-root', str(root)), 'local'), [])

    def test_malformed_conflicting_or_missing_source_fails_closed(self):
        wrong = self.config('wrong-bridge', f'[control_plane]\nproject="{PROJECT}"\nbridge="remote"')
        bad = self.config('bad-project', '[control_plane]\nproject="not-a-uuid"\nbridge="local"')
        for root in (wrong, bad):
            with self.assertRaises(ValueError):
                derive.bindings(invocation('--project-root', str(root)), 'local')
        for data in ({'data': []}, invocation('--project-root'), invocation('--project-root', 'relative')):
            with self.assertRaises(ValueError):
                derive.bindings(data, 'local')
        with self.assertRaises(FileNotFoundError):
            derive.bindings(invocation('--project-root', str(self.base / 'vanished')), 'local')

    def test_user_bus_failure_returns_error_not_an_empty_map(self):
        bad = subprocess.CalledProcessError(1, ['busctl'], stderr=b'a value this must not print')
        with patch.object(sys, 'argv', ['derive', 'local']), patch.object(derive.subprocess, 'run', side_effect=bad), \
                patch('builtins.print') as output:
            self.assertEqual(derive.main(), 1)
            printed = ' '.join(str(call.args) for call in output.call_args_list)
            self.assertNotIn('this must not print', printed)
            self.assertNotIn('[]', printed)


if __name__ == '__main__':
    unittest.main()
