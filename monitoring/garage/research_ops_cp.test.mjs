import { test } from 'node:test';
import assert from 'node:assert/strict';
import { evaluate } from './research_ops_cp.mjs';
import { check } from './worker.mjs';

const now = 1_800_000_000;
// Trimmed from the VM's real /metrics (2026-11-17), with times moved relative to `now`.
const metrics = `node_filesystem_avail_bytes{device="/dev/sda1",device_error="",fstype="ext4",mountpoint="/"} 6.1199724544e+10
node_filesystem_size_bytes{device="/dev/sda1",device_error="",fstype="ext4",mountpoint="/"} 6.7422650368e+10
node_scrape_collector_success{collector="filesystem"} 1
node_scrape_collector_success{collector="systemd"} 1
node_scrape_collector_success{collector="textfile"} 1
node_textfile_mtime_seconds{file="/var/lib/prometheus/node-exporter/postgres-backup.prom"} ${now - 120}
node_textfile_scrape_error 0
pg_archive_failed_total 0
pg_archive_last_failure_timestamp_seconds 0
pg_archive_last_success_timestamp_seconds ${now - 3 * 86400}
pg_archive_pending_segments 0
pg_dump_last_success_timestamp_seconds ${now - 2 * 86400}
pgbackrest_last_success_timestamp_seconds{type="diff"} 0
pgbackrest_last_success_timestamp_seconds{type="full"} ${now - 20 * 3600}
postgres_backup_up 1
research_ops_runner_last_report_timestamp_seconds{host="bridge-1"} ${now - 120}
${['cloudflared', 'postgresql@18-main', 'research-ops-api', 'research-ops-engine'].map(u =>
  `node_systemd_unit_state{name="${u}.service",state="active",type="simple"} 1\nnode_systemd_unit_state{name="${u}.service",state="failed",type="simple"} 0`).join('\n')}
${['pg-dump-backup', 'pgbackrest-diff', 'pgbackrest-full'].map(u =>
  `node_systemd_unit_state{name="${u}.service",state="active",type="oneshot"} 0\nnode_systemd_unit_state{name="${u}.service",state="failed",type="oneshot"} 0`).join('\n')}
`;

test('healthy VM, with no diff yet and an idle WAL archive, has no alarms', () => {
  assert.deepEqual(evaluate(metrics, now), {});
});
test('the newer of full and diff decides the backup age', () => {
  const stale = metrics.replace(`type="full"} ${now - 20 * 3600}`, `type="full"} ${now - 6 * 86400}`);
  assert.match(evaluate(stale, now).backup, /時間経過/);
  assert.deepEqual(evaluate(stale.replace('type="diff"} 0', `type="diff"} ${now - 3600}`), now), {});
  assert.match(evaluate(stale.replace(/.*type="diff".*\n/, ''), now).backup, /未確認/);
});
test('missing pg_dump marker is unconfirmed, an old one is stale', () => {
  assert.match(evaluate(metrics.replace(`pg_dump_last_success_timestamp_seconds ${now - 2 * 86400}`, 'pg_dump_last_success_timestamp_seconds 0'), now).pg_dump, /未確認/);
  assert.match(evaluate(metrics.replace(`pg_dump_last_success_timestamp_seconds ${now - 2 * 86400}`, `pg_dump_last_success_timestamp_seconds ${now - 8 * 86400}`), now).pg_dump, /経過/);
});
test('WAL alarms on a backlog or a failure newer than the last success, not on idleness', () => {
  assert.match(evaluate(metrics.replace('pg_archive_pending_segments 0', 'pg_archive_pending_segments 3'), now).wal, /溜まっている/);
  assert.match(evaluate(metrics.replace('pg_archive_last_failure_timestamp_seconds 0', `pg_archive_last_failure_timestamp_seconds ${now - 60}`), now).wal, /失敗/);
});
test('a stopped service or a failed backup unit is reported, an idle oneshot is not', () => {
  const stopped = metrics.replace('name="research-ops-api.service",state="active",type="simple"} 1', 'name="research-ops-api.service",state="active",type="simple"} 0');
  assert.match(evaluate(stopped, now).services, /research-ops-api.service 停止/);
  const failed = metrics.replace('name="pgbackrest-diff.service",state="failed",type="oneshot"} 0', 'name="pgbackrest-diff.service",state="failed",type="oneshot"} 1');
  assert.match(evaluate(failed, now).services, /pgbackrest-diff.service 失敗/);
});
test('a frozen collector file or unreadable archiver is not healthy', () => {
  assert.match(evaluate(metrics.replace(`postgres-backup.prom"} ${now - 120}`, `postgres-backup.prom"} ${now - 3600}`), now).metrics, /止まっている/);
  assert.ok(evaluate(metrics.replace('postgres_backup_up 1', 'postgres_backup_up 0'), now).metrics);
  assert.ok(evaluate(metrics.replace('mountpoint="/"} 6.1199724544e+10', 'mountpoint="/"} 1e+9'), now).capacity);
});

test('both targets keep separate rows and labels; Garage rows stay unprefixed', async () => {
  const rows = new Map();
  const db = { prepare(sql) { const stmt = { bind(...args) { return {
    async run() {
      if (sql.startsWith('INSERT')) rows.set(args[0], { failures: args[1], notified: args[2] });
      else rows.get(args[1]).notified = args[0];
    } }; }, async all() { return { results: [...rows].map(([name, row]) => ({ name, ...row })) }; } }; return stmt; },
    async batch(statements) { for (const s of statements) await s.run(); } };
  const posts = [];
  const fetcher = async (url, init) => {
    if (String(url).startsWith('https://discord.com/')) { posts.push(JSON.parse(init.body).content); return new Response(''); }
    if (String(url).includes('garage')) return new Response('', { status: 503 });
    return new Response(metrics.replace('pg_archive_pending_segments 0', 'pg_archive_pending_segments 9'));
  };
  const env = { DB: db, DISCORD_WEBHOOK: 'https://discord.com/api/webhooks/example/token',
    METRICS_URL: 'https://garage.example.com/metrics', ACCESS_CLIENT_ID: 'g', ACCESS_CLIENT_SECRET: 'g',
    CP_METRICS_URL: 'https://cp.example.com/metrics', CP_ACCESS_CLIENT_ID: 'c', CP_ACCESS_CLIENT_SECRET: 'c' };
  for (let i = 0; i < 3; i++) await check(env, fetcher, now);
  assert.ok(rows.has('reachability') && rows.has('cp_wal') && rows.has('cp_reachability'));
  assert.ok(!rows.has('metrics'), 'an unreachable Garage only records reachability');
  assert.deepEqual(posts.sort(), ['⚠️ Garage 監視: 監視先に到達できません（VM、回線、Tunnel または認証を確認）', '⚠️ research-ops-cp 監視: WAL が 9 個送れずに溜まっている'].sort());
});
test('a Bridge silent for more than 15 minutes, or no Bridge metric at all, is reported', () => {
  assert.match(evaluate(metrics.replace(`host="bridge-1"} ${now - 120}`, `host="bridge-1"} ${now - 17 * 3600}`), now).bridge, /bridge-1 1020 分/);
  assert.match(evaluate(metrics.replace(/research_ops_runner.*\n/, ''), now).bridge, /未確認/);
});
