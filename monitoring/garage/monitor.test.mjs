import { test } from 'node:test';
import assert from 'node:assert/strict';
import { evaluate, transition } from './monitor.mjs';
import { check } from './worker.mjs';

const now = 1_800_000_000;
const metrics = `node_filesystem_size_bytes{device="/dev/vda1",fstype="ext4",mountpoint="/"} 100
node_filesystem_avail_bytes{device="/dev/vda1",fstype="ext4",mountpoint="/"} 30
node_systemd_unit_state{name="garage.service",state="active",type="simple"} 1
garage_backup_last_success_timestamp_seconds 1799990000
garage_pve_zpool_healthy 1
garage_pve_storage_total_bytes 1000
garage_pve_storage_available_bytes 300
garage_pve_last_success_timestamp_seconds 1799999999
node_scrape_collector_success{collector="filesystem"} 1
node_scrape_collector_success{collector="systemd"} 1
node_scrape_collector_success{collector="textfile"} 1
node_textfile_scrape_error 0
`;

test('healthy metrics yield no alarms', () => {
  assert.deepEqual(evaluate(metrics, now), {});
});
test('missing backup record and missing service are unknown', () => {
  const alarms = evaluate(metrics.replace(/.*garage_backup.*\n/, '').replace(/.*node_systemd_unit_state.*\n/, ''), now);
  assert.match(alarms.backup, /未確認/);
  assert.match(alarms.garage, /未確認/);
});
test('detects low free space, stopped Garage and stale backup', () => {
  const bad = metrics.replace('mountpoint="/"} 30', 'mountpoint="/"} 10')
    .replace('type="simple"} 1', 'type="simple"} 0')
    .replace('1799990000', String(now - 7.5 * 86400 - 1));
  const alarms = evaluate(bad, now);
  assert.ok(alarms.capacity && alarms.garage && alarms.backup);
});
test('collector errors cannot be read as healthy', () => {
  assert.ok(evaluate(metrics.replace('collector="systemd"} 1', 'collector="systemd"} 0'), now).metrics);
});
test('detects degraded or stale Proxmox storage metrics', () => {
  assert.match(evaluate(metrics.replace('garage_pve_zpool_healthy 1', 'garage_pve_zpool_healthy 0'), now).zfs, /劣化/);
  assert.match(evaluate(metrics.replace('garage_pve_last_success_timestamp_seconds 1799999999', 'garage_pve_last_success_timestamp_seconds 1'), now).zfs, /未確認/);
  assert.ok(evaluate(metrics.replace('garage_pve_storage_available_bytes 300', 'garage_pve_storage_available_bytes 100'), now).zfs_capacity);
});
test('only alerts after three observations and reports recovery', () => {
  let state = { failures: 0, notified: false };
  for (let i = 0; i < 2; i++) {
    const result = transition(state, true);
    assert.equal(result.action, null);
    state = result.state;
  }
  const failure = transition(state, true);
  assert.equal(failure.action, 'alert');
  assert.equal(transition({ ...failure.state, notified: true }, false).action, 'recovery');
});

test('failed Discord delivery is retried and recovery is sent once', async () => {
  const rows = new Map();
  let selects = 0, batches = 0;
  const db = { prepare(sql) { return { bind(...args) { return {
    async first() { selects++; return rows.get(args[0]) || null; },
    async all() { selects++; return { results: [...rows].map(([name, row]) => ({ name, ...row })) }; },
    async run() {
      if (sql.startsWith('INSERT')) rows.set(args[0], { failures: args[1], notified: args[2] });
      else rows.get(args[1]).notified = args[0];
    },
  }; }, async all() { selects++; return { results: [...rows].map(([name, row]) => ({ name, ...row })) }; } }; },
    async batch(statements) { batches++; for (const statement of statements) await statement.run(); } };
  let unhealthy = true, discordOK = false, posts = 0;
  const fetcher = async (url) => {
    if (String(url).startsWith('https://discord.com/')) { posts++; return new Response('', { status: discordOK ? 200 : 500 }); }
    return unhealthy ? new Response('', { status: 503 }) : new Response(metrics);
  };
  const env = { DB: db, METRICS_URL: 'https://metrics.example.com/metrics', ACCESS_CLIENT_ID: 'id', ACCESS_CLIENT_SECRET: 'secret', DISCORD_WEBHOOK: 'https://discord.com/api/webhooks/example/token' };
  for (let i = 0; i < 3; i++) await check(env, fetcher, now);
  assert.equal(posts, 1);
  assert.equal(rows.get('reachability').notified, 0);
  discordOK = true;
  await check(env, fetcher, now);
  assert.equal(posts, 2);
  assert.equal(rows.get('reachability').notified, 1);
  unhealthy = false;
  await check(env, fetcher, now);
  await check(env, fetcher, now);
  assert.equal(posts, 3);
  assert.equal(rows.get('reachability').notified, 0);
  assert.equal(selects, 6);
  assert.equal(batches, 4);
});
