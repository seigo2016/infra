"""Isolation invariants of the research-ops-cp restore rehearsal.

The rehearsal VM restores the production pgBackRest repository. It must never
write to that repository (WAL, stanza, backup, expire), never reach the public
edge, and never run the engine that dispatches work.
"""
from pathlib import Path
import re
import unittest

import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[1]
ANSIBLE = ROOT / 'ansible'
REHEARSAL = ANSIBLE / 'restore-test-research-ops-cp.yml'
PROD_RESTORE = ANSIBLE / 'restore-research-ops-cp.yml'
SETUP = ANSIBLE / 'setup-research-ops-cp.yml'
OVERRIDES = ANSIBLE / 'vars/research-ops-cp-restore-test.yml'
ROLES = ANSIBLE / 'roles'


def load(path):
    return yaml.safe_load(path.read_text())


def role_names(play):
    return [entry if isinstance(entry, str) else entry['role'] for entry in play['roles']]


def task(tasks, name):
    return next(t for t in tasks if t.get('name') == name)


def asserts(play, name):
    return task(play['pre_tasks'], name)['ansible.builtin.assert']['that']


class RehearsalPlaybookTests(unittest.TestCase):
    def setUp(self):
        self.play = load(REHEARSAL)[0]

    def test_targets_only_the_rehearsal_group(self):
        self.assertEqual(self.play['hosts'], 'research-ops-cp-restore-test')

    def test_installs_no_edge_application_or_backup_roles(self):
        roles = role_names(self.play)
        self.assertEqual(roles, ['host_baseline', 'postgresql', 'pgbackrest', 'pgbackrest_restore'])
        for forbidden in ('cloudflared', 'caddy', 'bun_service', 'research_ops_release',
                          'pg_dump_backup', 'postgres_backup_monitor', 'rclone'):
            self.assertNotIn(forbidden, roles)

    def test_overrides_load_after_production_vars(self):
        files = self.play['vars_files']
        self.assertEqual(files[0], 'group_vars/research-ops-cp/vars.yml')
        self.assertEqual(files[-1], 'vars/research-ops-cp-restore-test.yml')

    def test_overrides_disable_every_write_to_the_repository(self):
        o = load(OVERRIDES)
        self.assertIs(o['pgbackrest_archive_enabled'], False)
        self.assertIs(o['postgresql_archive_enabled'], False)
        self.assertIs(o['pgbackrest_install_backup_units'], False)
        self.assertIs(o['backup_timers_enabled'], False)
        self.assertEqual(o['pgbackrest_restore_archive_mode'], 'off')
        self.assertIn('vault_pgbackrest_restore_s3_key', o['pgbackrest_s3_key'])
        self.assertIn('vault_pgbackrest_restore_s3_key_secret', o['pgbackrest_s3_key_secret'])
        self.assertEqual(o['postgresql_databases'], [])

    def test_refuses_production_hosts(self):
        that = asserts(self.play, 'Require the rehearsal VM')
        self.assertIn("ansible_facts['hostname'] == 'research-ops-cp-restore-test'", that)
        self.assertIn("ansible_host != lookup('env', 'TF_VAR_research_ops_cp_ip')", that)
        self.assertIn('not restore_cloudflared_unit.stat.exists',
                      asserts(self.play, 'Refuse hosts with Cloudflare Tunnel installed'))
        self.assertIn("restore_app_units.results | selectattr('stat.exists') | list | length == 0",
                      asserts(self.play, 'Refuse hosts with the API or engine installed'))

    def test_asserts_effective_isolation_values(self):
        that = asserts(self.play, 'Require isolation settings')
        for expected in ('not (pgbackrest_archive_enabled | bool)',
                         'not (postgresql_archive_enabled | bool)',
                         'not (pgbackrest_install_backup_units | bool)',
                         'not (backup_timers_enabled | bool)',
                         "pgbackrest_restore_archive_mode == 'off'",
                         'pgbackrest_s3_key == vault_pgbackrest_restore_s3_key',
                         'vault_pgbackrest_restore_s3_key != vault_pgbackrest_s3_key'):
            self.assertIn(expected, that)


class RoleGuardTests(unittest.TestCase):
    def test_stanza_changes_require_archiving_enabled(self):
        tasks = load(ROLES / 'pgbackrest/tasks/main.yml')
        for name in ('Create or validate the stanza', 'Check WAL archiving end to end'):
            self.assertIn('pgbackrest_archive_enabled | bool', task(tasks, name)['when'])

    def test_backup_units_require_explicit_install(self):
        tasks = load(ROLES / 'pgbackrest/tasks/main.yml')
        block = task(tasks, 'Install backup units')
        self.assertEqual(block['when'], 'pgbackrest_install_backup_units | bool')
        names = [t['name'] for t in block['block']]
        self.assertIn('Install backup services', names)
        self.assertIn('Configure backup timers', names)

    def test_timers_default_to_unchanged(self):
        for role in ('pgbackrest', 'pg_dump_backup'):
            self.assertIsNone(load(ROLES / role / 'defaults/main.yml')['backup_timers_enabled'])
        self.assertFalse(load(ROLES / 'pgbackrest/defaults/main.yml')['pgbackrest_archive_enabled'])

    def test_postgres_archive_off_renders_no_archive_command(self):
        env = jinja2.Environment()
        env.filters['bool'] = bool
        template = env.from_string((ROLES / 'postgresql/templates/managed.conf.j2').read_text())
        off = template.render(postgresql_listen_addresses='localhost', postgresql_port=5432,
                              postgresql_archive_enabled=False, postgresql_archive_command='pgbackrest archive-push %p',
                              postgresql_archive_timeout='60s')
        self.assertIn('archive_mode = off', off)
        self.assertNotIn('archive_command', off)

    def test_restore_passes_archive_mode_and_checks_it(self):
        tasks = load(ROLES / 'pgbackrest_restore/tasks/main.yml')
        self.assertIn("'--archive-mode=' ~ pgbackrest_restore_archive_mode",
                      task(tasks, 'Restore the stanza')['ansible.builtin.command']['argv'])
        check = task(tasks, 'Require archiving off on a rehearsal and on otherwise')['ansible.builtin.assert']['that']
        self.assertIn("pgbackrest_restore_archive_mode != 'off' or pgbackrest_restore_archive_mode_now.stdout == 'off'", check)

    def test_reconciliation_is_rolled_back(self):
        sql = (ROLES / 'pgbackrest_restore/files/reconcile-dry-run.sql').read_text()
        statements = re.sub(r'--[^\n]*', '', sql).upper()
        self.assertIn('ROLLBACK;', statements)
        self.assertIsNone(re.search(r'\b(COMMIT|END)\s*;', statements))


class ProductionGuardTests(unittest.TestCase):
    def test_groups_are_disjoint(self):
        children = load(ANSIBLE / 'inventory.research-ops-cp.yml')['all']['children']
        self.assertNotIn('children', children['research-ops-cp'])
        self.assertNotIn('research-ops-cp-restore-test', children['research-ops-cp']['hosts'])

    def test_setup_refuses_the_rehearsal_host_and_engine_honours_suspension(self):
        play = load(SETUP)[0]
        self.assertEqual(play['hosts'], 'research-ops-cp')
        self.assertIn("ansible_facts['hostname'] == 'research-ops-cp'",
                      asserts(play, 'Refuse the restore rehearsal VM'))
        engine = next(r for r in play['roles'] if isinstance(r, dict)
                      and r.get('vars', {}).get('bun_service_name') == 'research-ops-engine')
        self.assertEqual(engine['vars']['bun_service_skip_if_exists'], '{{ research_ops_dispatch_suspended_marker }}')

    def test_production_restore_needs_confirmation_and_suspends_dispatch_first(self):
        play = load(PROD_RESTORE)[0]
        names = [t['name'] for t in play['pre_tasks']]
        self.assertEqual(names[0], 'Require explicit confirmation')
        stop = 'Stop the API, the engine and the backup timers'
        self.assertLess(names.index('Suspend dispatch before anything else'), names.index(stop))
        self.assertIn("research_ops_cp_confirm_restore | default('') == 'research-ops-cp'",
                      asserts(play, 'Require explicit confirmation'))
        self.assertIs(play['vars']['pgbackrest_archive_enabled'], False)
        stopped = next(t for t in play['pre_tasks'] if t['name'] == stop)
        self.assertNotIn('failed_when', stopped)
        for unit in ('pgbackrest-full.timer', 'pgbackrest-diff.timer', 'pg-dump-backup.timer'):
            self.assertIn(unit, stopped['loop'])

    def test_production_restore_keeps_archiving_so_the_new_timeline_is_kept(self):
        play = load(PROD_RESTORE)[0]
        self.assertIs(play['vars']['postgresql_archive_enabled'], True)
        self.assertEqual(play['vars']['pgbackrest_restore_archive_mode'], 'preserve')
        check = task(load(ROLES / 'pgbackrest_restore/tasks/main.yml'),
                     'Require archiving off on a rehearsal and on otherwise')['ansible.builtin.assert']['that']
        self.assertIn("pgbackrest_restore_archive_mode != 'preserve' or pgbackrest_restore_archive_mode_now.stdout == 'on'", check)

    def test_rebuild_procedure_turns_the_backup_timers_on(self):
        doc = (ROOT / 'docs/standards/research-ops-cp-restore.md').read_text()
        section = doc[doc.index('## 本番を復元する、作り直す'):doc.index('## 限界')]
        self.assertIn('setup-research-ops-cp.yml --ask-vault-pass -e backup_timers_enabled=true', section)

    def test_rehearsal_vm_is_opt_in_and_not_started_with_the_node(self):
        tf = (ROOT / 'terraform/prod/research-ops-cp.tf').read_text()
        block = tf[tf.index('module "research_ops_cp_restore_test"'):]
        self.assertIn('count  = var.research_ops_cp_restore_test_enabled ? 1 : 0', block)
        self.assertIn('vm_name            = "research-ops-cp-restore-test"', block)
        self.assertIn('start_at_node_boot = false', block)
        self.assertIn('ip_address     = var.research_ops_cp_restore_test_ip', block)


if __name__ == '__main__':
    unittest.main()
