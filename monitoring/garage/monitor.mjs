const MAX_BACKUP_AGE = 7.5 * 86400;
const MONITORED_METRICS = new Set([
  'node_scrape_collector_success', 'node_textfile_scrape_error',
  'node_filesystem_size_bytes', 'node_filesystem_avail_bytes',
  'node_systemd_unit_state', 'garage_backup_last_success_timestamp_seconds',
  'garage_pve_zpool_healthy', 'garage_pve_storage_total_bytes',
  'garage_pve_storage_available_bytes', 'garage_pve_last_success_timestamp_seconds',
]);

function parseMetrics(text) {
  const metrics = new Map();
  for (const line of text.split('\n')) {
    const match = line.match(/^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(.*)\})?\s+([^\s]+)(?:\s+\d+)?\s*$/);
    if (!match || !MONITORED_METRICS.has(match[1])) continue;
    const parsed = {};
    const raw = match[2] ?? '';
    for (const label of raw.matchAll(/([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"(?:,|$)/g)) {
      parsed[label[1]] = label[2].replace(/\\([\\"n])/g, (_, c) => c === 'n' ? '\n' : c);
    }
    const value = Number(match[3]);
    if (!Number.isFinite(value)) continue;
    if (!metrics.has(match[1])) metrics.set(match[1], []);
    metrics.get(match[1]).push({ labels: parsed, value });
  }
  return metrics;
}

function samples(metrics, name, labels = {}) {
  const result = (metrics.get(name) ?? [])
    .filter(sample => Object.entries(labels).every(([key, value]) => sample.labels[key] === value))
    .map(sample => sample.value);
  return result.length === 1 ? result[0] : null;
}

export function evaluate(text, now) {
  const alarms = {};
  const metrics = parseMetrics(text);
  for (const collector of ['filesystem', 'systemd', 'textfile']) {
    if (samples(metrics, 'node_scrape_collector_success', { collector }) !== 1) alarms.metrics = 'メトリクス収集失敗または未確認';
  }
  if (samples(metrics, 'node_textfile_scrape_error') !== 0) alarms.metrics = 'textfile メトリクスの取得失敗または未確認';
  const size = samples(metrics, 'node_filesystem_size_bytes', { mountpoint: '/' });
  const avail = samples(metrics, 'node_filesystem_avail_bytes', { mountpoint: '/' });
  if (size === null || avail === null || size <= 0 || avail < 0) alarms.capacity = 'VM 容量が未確認';
  else if (avail / size < 0.15) alarms.capacity = `VM の空き容量 ${Math.round(avail / 1024 ** 3)} GiB (${Math.round(avail / size * 100)}%)`;
  const active = samples(metrics, 'node_systemd_unit_state', { name: 'garage.service', state: 'active' });
  if (active === null) alarms.garage = 'Garage の状態が未確認';
  else if (active !== 1) alarms.garage = 'Garage が停止しています';
  const last = samples(metrics, 'garage_backup_last_success_timestamp_seconds');
  if (last === null || last <= 0 || last > now + 300) alarms.backup = 'バックアップ成功時刻が未確認';
  else if (now - last > MAX_BACKUP_AGE) alarms.backup = `バックアップの最終成功から ${Math.floor((now - last) / 3600)} 時間経過`;
  // The run itself failed: report it now instead of waiting for the age limit.
  if (samples(metrics, 'node_systemd_unit_state', { name: 'garage-backup.service', state: 'failed' }) === 1) {
    alarms.backup = 'バックアップが失敗しました（journalctl -u garage-backup.service）';
  }
  const pveTime = samples(metrics, 'garage_pve_last_success_timestamp_seconds');
  const poolHealthy = samples(metrics, 'garage_pve_zpool_healthy');
  const poolTotal = samples(metrics, 'garage_pve_storage_total_bytes');
  const poolAvail = samples(metrics, 'garage_pve_storage_available_bytes');
  if (pveTime === null || pveTime > now + 300 || now - pveTime > 1200 || poolHealthy === null) alarms.zfs = 'Proxmox ストレージの状態が未確認';
  else if (poolHealthy !== 1) alarms.zfs = 'ZFS pool が劣化しています';
  if (poolTotal === null || poolAvail === null || poolTotal <= 0 || poolAvail < 0 || poolAvail > poolTotal || pveTime === null || pveTime > now + 300 || now - pveTime > 1200) alarms.zfs_capacity = 'Proxmox ストレージ容量が未確認';
  else if (poolAvail / poolTotal < 0.15) alarms.zfs_capacity = `Proxmox ストレージの空き容量 ${Math.round(poolAvail / 1024 ** 3)} GiB (${Math.round(poolAvail / poolTotal * 100)}%)`;
  return alarms;
}

const REMIND_AFTER = 86400;

// `notified` holds when the alert was last sent (0 = not alerted). While the condition stays bad,
// the alert is sent again once a day so a failure does not go quiet after one message.
export function transition(previous, failed, now = Date.now() / 1000) {
  const notified = Number(previous.notified) || 0;
  if (failed) {
    const failures = Math.min((previous.failures || 0) + 1, 3);
    const due = failures >= 3 && (!notified || now - notified >= REMIND_AFTER);
    return { state: { failures, notified }, action: due ? (notified ? 'remind' : 'alert') : null };
  }
  return { state: { failures: 0, notified }, action: notified ? 'recovery' : null };
}
