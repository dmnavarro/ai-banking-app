#!/usr/bin/env node
// Latency check: the same prompts, direct vs through the AI Gateway, several times each.
//
//   node scripts/latency-check.js https://your-dgbank-url [runs]
//
// Calls the app's /api/chat exactly as the demo view does (Tests 1, 3 and 4 routes; Test 2's
// AI Guard scan runs in the browser, so it isn't measured here). Runs are interleaved so a slow
// minute affects every route alike. Prints median and slowest time per route, and the gateway's
// extra time over direct.

const base = (process.argv[2] || '').replace(/\/+$/, '');
const runs = Number(process.argv[3] || 5);
if (!base) {
  console.error('Usage: node scripts/latency-check.js <app base URL> [runs]');
  process.exit(1);
}

const CASES = [
  { name: 'Chat, direct (Test 1)',          route: 'direct',  tools: false, message: 'What is my current account balance?' },
  { name: 'Chat, gateway',                  route: 'gateway', tools: false, message: 'What is my current account balance?' },
  { name: 'MCP tools, direct (Test 3)',     route: 'direct',  tools: true,  message: 'Show me my recent transactions' },
  { name: 'MCP tools, gateway (Test 4)',    route: 'gateway', tools: true,  message: 'Show me my recent transactions' },
];

async function once(c) {
  const t0 = performance.now();
  try {
    const r = await fetch(`${base}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: c.message, history: [], route: c.route, identity: 'assistant', tools: c.tools }),
    });
    const data = await r.json().catch(() => ({}));
    const ms = performance.now() - t0;
    const ok = r.ok && !data.error && !data.gatewayError && !!data.reply;
    return { ms, ok, why: ok ? '' : (data.error || data.gatewayError?.message || `HTTP ${r.status}`) };
  } catch (e) {
    return { ms: performance.now() - t0, ok: false, why: e.message };
  }
}

const pct = (xs, p) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
};
const sec = ms => `${(ms / 1000).toFixed(2)} s`;

(async () => {
  console.log(`${runs} runs per route against ${base}\n`);
  await Promise.all(CASES.map(once));   // warm-up: connections, caches; not counted

  const results = CASES.map(() => []);
  for (let i = 0; i < runs; i++) {
    for (const [j, c] of CASES.entries()) {
      const r = await once(c);
      results[j].push(r);
      process.stdout.write(r.ok ? '.' : 'x');
    }
  }
  console.log('\n');

  const medians = {};
  for (const [j, c] of CASES.entries()) {
    const ok = results[j].filter(r => r.ok).map(r => r.ms);
    const failed = results[j].filter(r => !r.ok);
    medians[c.name] = ok.length ? pct(ok, 50) : null;
    const line = ok.length
      ? `median ${sec(pct(ok, 50))}   slowest ${sec(Math.max(...ok))}`
      : 'no successful runs';
    console.log(`${c.name.padEnd(30)} ${line}${failed.length ? `   (${failed.length} failed: ${failed[0].why})` : ''}`);
  }

  const extra = (gw, direct) => (medians[gw] != null && medians[direct] != null)
    ? `+${sec(medians[gw] - medians[direct])}` : 'n/a';
  console.log(`\nGateway extra time (median): chat ${extra('Chat, gateway', 'Chat, direct (Test 1)')}, ` +
              `MCP tools ${extra('MCP tools, gateway (Test 4)', 'MCP tools, direct (Test 3)')}`);
})();
