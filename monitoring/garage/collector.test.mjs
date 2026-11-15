import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

test('exports only a real backup marker and removes stale metrics if it disappears', () => {
  const dir = mkdtempSync(join(tmpdir(), 'garage-collector-'));
  try {
    const marker = join(dir, 'last-success'), output = join(dir, 'metrics');
    mkdirSync(output);
    const run = () => execFileSync('bash', ['ansible/roles/garage-monitor/files/garage-backup-metrics', marker, output]);
    run();
    assert.equal(existsSync(join(output, 'garage-backup.prom')), false);
    writeFileSync(marker, '');
    utimesSync(marker, 1700000000, 1700000000);
    run();
    assert.match(readFileSync(join(output, 'garage-backup.prom'), 'utf8'), /garage_backup_last_success_timestamp_seconds 1700000000/);
    rmSync(marker);
    run();
    assert.equal(existsSync(join(output, 'garage-backup.prom')), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
