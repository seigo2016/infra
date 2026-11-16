import { evaluate, transition } from './monitor.mjs';
import * as researchOpsCp from './research_ops_cp.mjs';

// Each target keeps its own D1 rows (Garage's are unprefixed, as before) and its own reachability.
// A target whose URL is not configured is skipped.
const TARGETS = [
  { prefix: '', label: 'Garage 監視', url: 'METRICS_URL', id: 'ACCESS_CLIENT_ID', secret: 'ACCESS_CLIENT_SECRET', evaluate,
    conditions: ['metrics', 'garage', 'capacity', 'backup', 'zfs', 'zfs_capacity'] },
  { prefix: 'cp_', label: 'research-ops-cp 監視', url: 'CP_METRICS_URL', id: 'CP_ACCESS_CLIENT_ID', secret: 'CP_ACCESS_CLIENT_SECRET',
    evaluate: researchOpsCp.evaluate, conditions: researchOpsCp.CONDITIONS },
];

async function send(webhook, message, fetcher) {
  const url = new URL(webhook);
  if (url.protocol !== 'https:' || !['discord.com', 'discordapp.com'].includes(url.hostname)) throw new Error('Invalid Discord webhook');
  url.searchParams.set('wait', 'true');
  const response = await fetcher(url.toString(), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: message, allowed_mentions: { parse: [] } }),
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`Discord HTTP ${response.status}`);
}

async function observe(target, env, fetcher, now) {
  try {
    const response = await fetcher(env[target.url], {
      headers: { 'CF-Access-Client-Id': env[target.id], 'CF-Access-Client-Secret': env[target.secret] },
      redirect: 'manual', signal: AbortSignal.timeout(15000),
    });
    if (response.status !== 200) throw new Error(`HTTP ${response.status}`);
    const values = target.evaluate(await response.text(), now);
    return { values, keys: ['reachability', ...target.conditions] };
  } catch (error) {
    console.error('Metrics request failed', target.label, error.name);
    return { values: { reachability: '監視先に到達できません（VM、回線、Tunnel または認証を確認）' }, keys: ['reachability'] };
  }
}

export async function check(env, fetcher = fetch, now = Date.now() / 1000) {
  const targets = TARGETS.filter(t => env[t.url]);
  const observed = await Promise.all(targets.map(t => observe(t, env, fetcher, now)));
  const stored = await env.DB.prepare('SELECT name, failures, notified FROM monitor_state').all();
  const previous = new Map(stored.results.map(row => [row.name, row]));
  const pending = [];
  const updates = [];
  for (const [i, target] of targets.entries()) for (const name of observed[i].keys) {
    const values = observed[i].values;
    const key = target.prefix + name;
    const prior = previous.get(key);
    const { state, action } = transition(prior || {}, !!values[name]);
    if (!prior || prior.failures !== state.failures || !!prior.notified !== state.notified) {
      updates.push(env.DB.prepare('INSERT INTO monitor_state (name, failures, notified) VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET failures = excluded.failures, notified = excluded.notified').bind(key, state.failures, Number(state.notified)));
    }
    pending.push({ key, action, label: target.label, name, message: values[name] });
  }
  if (updates.length) await env.DB.batch(updates);
  for (const { key, action, label, name, message } of pending) {
    if (!action) continue;
    try {
      await send(env.DISCORD_WEBHOOK, action === 'alert' ? `⚠️ ${label}: ${message}` : `✅ ${label}: ${name} が復旧しました`, fetcher);
      await env.DB.prepare('UPDATE monitor_state SET notified = ? WHERE name = ?').bind(Number(action === 'alert'), key).run();
    } catch (error) {
      console.error('Discord notification failed', key, error.name);
    }
  }
}

export default { async scheduled(_event, env, ctx) { ctx.waitUntil(check(env)); } };
