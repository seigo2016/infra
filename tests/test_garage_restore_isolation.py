from pathlib import Path
import unittest
import yaml


PLAYBOOK = Path(__file__).resolve().parents[1] / 'ansible/setup-garage-restore-test.yml'


class RestoreIsolationTests(unittest.TestCase):
    def test_restore_does_not_install_tunnel_and_disables_backups(self):
        play = yaml.safe_load(PLAYBOOK.read_text())[0]
        roles = [entry if isinstance(entry, str) else entry['role'] for entry in play['roles']]
        self.assertEqual(play['hosts'], 'garage-restore-test')
        self.assertIn('garage', roles)
        self.assertIn('rclone-backup', roles)
        self.assertNotIn('cloudflared', roles)
        self.assertNotIn('caddy', roles)
        self.assertFalse(play['vars']['backup_timers_enabled'])

    def test_refuses_existing_cloudflare_connector(self):
        play = yaml.safe_load(PLAYBOOK.read_text())[0]
        check = next(task for task in play['pre_tasks'] if task['name'] == 'Refuse hosts with Cloudflare Tunnel installed')
        self.assertIn('not restore_cloudflared_unit.stat.exists', check['ansible.builtin.assert']['that'])
        guard = next(task for task in play['pre_tasks'] if task['name'] == 'Require an explicitly marked restore test VM')
        self.assertIn('restore_test_marker.stat.exists', guard['ansible.builtin.assert']['that'])
        self.assertIn('not (backup_timers_enabled | bool)', guard['ansible.builtin.assert']['that'])


if __name__ == '__main__':
    unittest.main()
