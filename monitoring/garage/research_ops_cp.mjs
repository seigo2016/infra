// research-ops Control Plane VM (second target of this Worker). Thresholds follow the VM's
// timers: pgBackRest full on Sunday and diff Mon..Sat at 02:30, pg_dump on Sunday at 04:30,
// and the textfile collector every few minutes. A missing marker reads 0 and is "unconfirmed".
const MAX_PGBACKREST_AGE = 30 * 3600;     // newest of full and diff; the diff runs daily
const MAX_PG_DUMP_AGE = 7.5 * 86400;
const MAX_TEXTFILE_AGE = 20 * 60;         // the collector's own file, so a dead timer is caught
const MAX_PENDING_WAL = 3;
const MAX_RUNNER_SILENCE = 15 * 60;   // a Bridge reports every 5 minutes; the screen also calls 15 minutes stale
const LONG_RUNNING = ['postgresql@18-main.service', 'research-ops-api.service', 'research-ops-engine.service', 'cloudflared.service'];
const ONESHOT = ['pgbackrest-full.service', 'pgbackrest-diff.service', 'pg-dump-backup.service'];
const TEXTFILE = '/var/lib/prometheus/node-exporter/postgres-backup.prom';

export const CONDITIONS = ['metrics', 'capacity', 'services', 'backup', 'pg_dump', 'wal', 'bridge'];

function parse(text) {
  const out = [];
  for (const line of text.split('\n')) {
    const m = line.match(/^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+([^\s]+)(?:\s+\d+)?\s*$/);
    if (!m) continue;
    const labels = {};
    for (const l of (m[2] ?? '').matchAll(/([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"(?:,|$)/g)) labels[l[1]] = l[2];
    const value = Number(m[3]);
    if (Number.isFinite(value)) out.push({ name: m[1], labels, value });
  }
  return out;
}

export function evaluate(text, now) {
  const all = parse(text);
  const one = (name, labels = {}) => {
    const found = all.filter(s => s.name === name && Object.entries(labels).every(([k, v]) => s.labels[k] === v));
    return found.length === 1 ? found[0].value : null;
  };
  const alarms = {};
  const fresh = t => t !== null && t > 0 && t <= now + 300;

  for (const collector of ['filesystem', 'systemd', 'textfile']) {
    if (one('node_scrape_collector_success', { collector }) !== 1) alarms.metrics = 'メトリクス収集失敗または未確認';
  }
  if (one('node_textfile_scrape_error') !== 0 || one('postgres_backup_up') !== 1) alarms.metrics = 'backup のメトリクスが読めないか未確認';
  const written = one('node_textfile_mtime_seconds', { file: TEXTFILE });
  if (!fresh(written) || now - written > MAX_TEXTFILE_AGE) alarms.metrics = 'backup のメトリクスの更新が止まっている';

  const size = one('node_filesystem_size_bytes', { mountpoint: '/' });
  const avail = one('node_filesystem_avail_bytes', { mountpoint: '/' });
  if (size === null || avail === null || size <= 0 || avail < 0) alarms.capacity = 'VM 容量が未確認';
  else if (avail / size < 0.15) alarms.capacity = `VM の空き容量 ${Math.round(avail / 1024 ** 3)} GiB (${Math.round(avail / size * 100)}%)`;

  const problems = [];
  for (const name of LONG_RUNNING) {
    const active = one('node_systemd_unit_state', { name, state: 'active' });
    if (active !== 1) problems.push(`${name} ${active === null ? '未確認' : '停止'}`);
  }
  for (const name of ONESHOT) {
    const failed = one('node_systemd_unit_state', { name, state: 'failed' });
    if (failed === null) problems.push(`${name} 未確認`);
    else if (failed !== 0) problems.push(`${name} 失敗`);
  }
  if (problems.length) alarms.services = problems.join('、');

  const full = one('pgbackrest_last_success_timestamp_seconds', { type: 'full' });
  const diff = one('pgbackrest_last_success_timestamp_seconds', { type: 'diff' });
  const newest = Math.max(full ?? 0, diff ?? 0);
  if (full === null || diff === null || !fresh(newest)) alarms.backup = 'pgBackRest の成功時刻が未確認';
  else if (now - newest > MAX_PGBACKREST_AGE) alarms.backup = `pgBackRest の最終成功から ${Math.floor((now - newest) / 3600)} 時間経過`;

  const dump = one('pg_dump_last_success_timestamp_seconds');
  if (!fresh(dump)) alarms.pg_dump = 'pg_dump の成功時刻が未確認';
  else if (now - dump > MAX_PG_DUMP_AGE) alarms.pg_dump = `pg_dump の最終成功から ${Math.floor((now - dump) / 3600)} 時間経過`;

  // The last-archived time stops moving whenever nothing writes, which is not a fault; look at
  // segments waiting and at a failure newer than the last success instead.
  const pending = one('pg_archive_pending_segments');
  const lastOk = one('pg_archive_last_success_timestamp_seconds');
  const lastFail = one('pg_archive_last_failure_timestamp_seconds');
  if (pending === null || lastOk === null || lastFail === null) alarms.wal = 'WAL の送り出しが未確認';
  else if (pending >= MAX_PENDING_WAL) alarms.wal = `WAL が ${pending} 個送れずに溜まっている`;
  else if (lastFail > lastOk) alarms.wal = 'WAL の送り出しが失敗している';

  // A Bridge that stops reporting leaves the pages silently out of date (2026-11-19: WSL's user
  // systemd was OOM-killed and the Bridge stayed down 17 hours with nobody told).
  const runners = all.filter(s => s.name === 'research_ops_runner_last_report_timestamp_seconds');
  if (!runners.length) alarms.bridge = 'Bridge の報告時刻が未確認';
  else {
    const silent = runners.filter(s => now - s.value > MAX_RUNNER_SILENCE)
      .map(s => `${s.labels.host} ${s.value > 0 ? `${Math.floor((now - s.value) / 60)} 分` : '報告なし'}`);
    if (silent.length) alarms.bridge = `Bridge の報告が途絶えている（${silent.join('、')}）`;
  }
  return alarms;
}
