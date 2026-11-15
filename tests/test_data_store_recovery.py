import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROLE = ROOT / 'ansible/roles/rclone-backup'


class RecoverySafetyTests(unittest.TestCase):
    def test_backup_timer_requires_explicit_change_and_trash_cleanup_is_disabled(self):
        defaults = yaml.safe_load((ROLE / 'defaults/main.yml').read_text())
        self.assertIsNone(defaults.get('backup_timers_enabled'))
        tasks = yaml.safe_load((ROLE / 'tasks/main.yml').read_text())
        timer_task = next(t for t in tasks if t.get('name') == 'Configure backup timers')
        self.assertIn('backup_timers_enabled', str(timer_task['ansible.builtin.systemd_service']))
        self.assertEqual(timer_task['ansible.builtin.systemd_service']['name'], 'garage-backup.timer')
        self.assertIn('backup_timers_enabled is not none', timer_task['when'])
        cleanup_task = next(t for t in tasks if t.get('name') == 'Disable automatic backup trash cleanup')
        self.assertEqual(cleanup_task['ansible.builtin.systemd_service']['name'], 'garage-trash-cleanup.timer')
        self.assertFalse(cleanup_task['ansible.builtin.systemd_service']['enabled'])
        self.assertEqual(cleanup_task['ansible.builtin.systemd_service']['state'], 'stopped')

    def test_backup_preserves_destination_objects(self):
        unit = (ROLE / 'templates/garage-backup.service.j2').read_text()
        self.assertIn(' copy ', unit)
        self.assertIn('--immutable', unit)
        self.assertNotIn('--backup-dir', unit)

    def test_rclone_passwords_are_not_command_line_arguments(self):
        tasks = yaml.safe_load((ROLE / 'tasks/main.yml').read_text())
        for name in ('Obscure rclone crypt password', 'Obscure rclone crypt salt'):
            task = next(t for t in tasks if t.get('name') == name)
            command = task['ansible.builtin.command']
            self.assertEqual(command['argv'], ['rclone', 'obscure', '-'])
            self.assertIn('vault_rclone_crypt_', command['stdin'])
            self.assertTrue(task['no_log'])

    def test_existing_crypt_key_is_checked_before_config_replacement(self):
        tasks = yaml.safe_load((ROLE / 'tasks/main.yml').read_text())
        guard = next(i for i, t in enumerate(tasks) if t.get('name') == 'Verify existing rclone crypt key before replacement')
        render = next(i for i, t in enumerate(tasks) if t.get('name') == 'Render rclone.conf')
        self.assertLess(guard, render)
        task = tasks[guard]
        self.assertIn('always', task)
        self.assertTrue(any(x.get('name') == 'Reject changed crypt keys' for x in task['block']))

    def test_legacy_metadata_tar_timer_is_disabled(self):
        tasks = yaml.safe_load((ROLE / 'tasks/main.yml').read_text())
        task = next(t for t in tasks if t.get('name') == 'Disable legacy metadata tar timer')
        self.assertEqual(task['ansible.builtin.systemd_service']['name'], 'garage-meta-snapshot.timer')
        self.assertEqual(task['ansible.builtin.systemd_service']['state'], 'stopped')
        self.assertFalse(task['ansible.builtin.systemd_service']['enabled'])

    def test_garage_config_enables_daily_metadata_snapshots(self):
        garage = ROOT / 'ansible/roles/garage'
        defaults = yaml.safe_load((garage / 'defaults/main.yml').read_text())
        self.assertEqual(defaults['garage_metadata_snapshot_interval'], '24h')
        self.assertIn('metadata_auto_snapshot_interval = "{{ garage_metadata_snapshot_interval }}"',
                      (garage / 'templates/garage.toml.j2').read_text())
        tasks = yaml.safe_load((garage / 'tasks/main.yml').read_text())
        self.assertTrue(any(t.get('name') == 'Create initial Garage metadata snapshot' for t in tasks))

    def test_cloudflared_repository_works_across_debian_releases(self):
        tasks = yaml.safe_load((ROOT / 'ansible/roles/cloudflared/tasks/main.yml').read_text())
        task = next(t for t in tasks if t.get('name') == 'Add cloudflared apt repository')
        content = task['ansible.builtin.copy']['content']
        self.assertIn('cloudflared_repo_url }} any main', content)
        self.assertNotIn('ansible_distribution_release', content)

    def test_qemu_agent_is_installed_and_started_only_when_port_exists(self):
        plays = yaml.safe_load((ROOT / 'ansible/setup-data-store.yml').read_text())
        tasks = plays[0]['tasks']
        packages = next(t for t in tasks if t.get('name') == 'Install common base packages')
        self.assertIn('qemu-guest-agent', packages['ansible.builtin.apt']['name'])
        start = next(t for t in tasks if t.get('name') == 'Start QEMU guest agent when available')
        self.assertEqual(start['ansible.builtin.systemd_service']['state'], 'started')
        self.assertIn('qemu_guest_agent_port.stat.exists', start['when'])

    def test_garage_check_mode_runs_read_only_queries(self):
        tasks = yaml.safe_load((ROOT / 'ansible/roles/garage/tasks/bootstrap.yml').read_text())
        names = {'Wait until garage RPC is ready and report node id', 'Show current cluster layout',
                 'Re-read layout to find current and staged versions', 'List existing buckets',
                 'List existing access keys', 'Retrieve key info (with secret)'}
        selected = [task for task in tasks if task.get('name') in names]
        self.assertEqual(len(selected), len(names))
        self.assertTrue(all(task.get('check_mode') is False for task in selected))
        mutate = next(task for task in tasks if task.get('name') == 'Apply staged layout')
        self.assertNotEqual(mutate.get('check_mode'), False)

    def test_backup_records_success_only_after_successful_copy(self):
        unit = (ROLE / 'templates/garage-backup.service.j2').read_text()
        self.assertIn('StateDirectory=garage-backup', unit)
        self.assertIn('ExecStartPost=/usr/bin/touch /var/lib/garage-backup/last-success', unit)


if __name__ == '__main__':
    unittest.main()
