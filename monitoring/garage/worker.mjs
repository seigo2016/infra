import { evaluate, transition } from './monitor.mjs';

const CONDITIONS = ['reachability', 'metrics', 'garage', 'capacity', 'backup', 'zfs', 'zfs_capacity'];

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

export async function check(env, fetcher = fetch, now = Date.now() / 1000) {
  let values;
  try {
    const response = await fetcher(env.METRICS_URL, {
      headers: { 'CF-Access-Client-Id': env.ACCESS_CLIENT_ID, 'CF-Access-Client-Secret': env.ACCESS_CLIENT_SECRET },
      redirect: 'manual', signal: AbortSignal.timeout(15000),
    });
    if (response.status !== 200) throw new Error(`HTTP ${response.status}`);
    values = evaluate(await response.text(), now);
  } catch (error) {
    console.error('Metrics request failed', error.name);
    values = { reachability: '監視先に到達できません（VM、回線、Tunnel または認証を確認）' };
  }
  const keys = values.reachability ? ['reachability'] : CONDITIONS;
  const stored = await env.DB.prepare('SELECT name, failures, notified FROM monitor_state').all();
  const previous = new Map(stored.results.map(row => [row.name, row]));
  const pending = [];
  const updates = [];
  for (const key of keys) {
    const prior = previous.get(key);
    const { state, action } = transition(prior || {}, !!values[key]);
    if (!prior || prior.failures !== state.failures || !!prior.notified !== state.notified) {
      updates.push(env.DB.prepare('INSERT INTO monitor_state (name, failures, notified) VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET failures = excluded.failures, notified = excluded.notified').bind(key, state.failures, Number(state.notified)));
    }
    pending.push({ key, action });
  }
  if (updates.length) await env.DB.batch(updates);
  for (const { key, action } of pending) {
    if (!action) continue;
    try {
      await send(env.DISCORD_WEBHOOK, action === 'alert' ? `⚠️ Garage 監視: ${values[key]}` : `✅ Garage 監視: ${key} が復旧しました`, fetcher);
      await env.DB.prepare('UPDATE monitor_state SET notified = ? WHERE name = ?').bind(Number(action === 'alert'), key).run();
    } catch (error) {
      console.error('Discord notification failed', key, error.name);
    }
  }
}

export default { async scheduled(_event, env, ctx) { ctx.waitUntil(check(env)); } };
