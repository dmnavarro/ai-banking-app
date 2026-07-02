const express = require('express');
const path    = require('path');

const app = express();
app.use(express.json());
app.use(express.static(__dirname));

const REGIONS = {
  us: 'https://api.xdr.trendmicro.com',
  eu: 'https://api.eu.xdr.trendmicro.com',
  jp: 'https://api.jp.xdr.trendmicro.com',
  sg: 'https://api.sg.xdr.trendmicro.com',
  au: 'https://api.au.xdr.trendmicro.com',
  in: 'https://api.in.xdr.trendmicro.com',
  ca: 'https://api.ca.xdr.trendmicro.com',
};

// Transparent proxy — forwards Authorization + V1 headers to bypass browser CORS
app.post('/api/aiguard/scan', async (req, res) => {
  const region  = req.headers['x-v1-region'] || 'sg';
  const baseUrl = REGIONS[region] || REGIONS['sg'];
  const url     = baseUrl + '/v3.0/aiSecurity/applyGuardrails?detailedResponse=true';

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10000);

  try {
    const upstream = await fetch(url, {
      method:  'POST',
      headers: {
        'Authorization':         req.headers['authorization']          || '',
        'Content-Type':          'application/json',
        'TMV1-Application-Name': req.headers['tmv1-application-name'] || 'trend-bank-chatbot',
        'Prefer':                'return=representation',
      },
      body: JSON.stringify(req.body),
      signal: controller.signal,
    });

    clearTimeout(timer);
    const text = await upstream.text();
    console.log(`[AI Guard] ${upstream.status} ← ${url}`);
    console.log(`[AI Guard] body: ${text.slice(0, 400)}`);
    res.status(upstream.status).set('Content-Type', 'application/json').send(text);
  } catch (e) {
    clearTimeout(timer);
    const msg = e.name === 'AbortError' ? 'Vision One request timed out' : e.message;
    console.error('[AI Guard] proxy error:', msg);
    res.status(502).json({ error: msg });
  }
});

// AI Scanner — sends a single attack prompt to the configured target and reports blocked/passed
app.post('/api/scanner/run', async (req, res) => {
  const { target, prompt } = req.body || {};
  if (!target || !target.url || !prompt) {
    return res.status(400).json({ error: 'target.url and prompt are required' });
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);

  try {
    const headers = { 'Content-Type': 'application/json' };
    if (target.apiKey) {
      headers['Authorization'] = target.apiKey.startsWith('Bearer ') ? target.apiKey : `Bearer ${target.apiKey}`;
    }

    // Detect endpoint type: if it targets our own aiguard proxy, use Vision One format
    const isAIGuardProxy = target.url.includes('/api/aiguard/scan');

    let body;
    if (isAIGuardProxy) {
      body = JSON.stringify({ prompt });
      headers['TMV1-Application-Name'] = 'ai-scanner';
      headers['Prefer'] = 'return=representation';
    } else {
      body = JSON.stringify({ model: target.model || 'gpt-4o', messages: [{ role: 'user', content: prompt }] });
    }

    const upstream = await fetch(target.url, { method: 'POST', headers, body, signal: controller.signal });
    clearTimeout(timer);

    const text = await upstream.text();
    console.log(`[AI Scanner] ${upstream.status} ← ${target.url}`);

    let data;
    try { data = JSON.parse(text); } catch { data = {}; }

    // Blocked if: HTTP 403, or Vision One action=block, or explicit blocked flag
    const blocked = upstream.status === 403 ||
                    (data.action === 'Block') ||
                    (data.blocked === true);

    res.json({ blocked, status: upstream.status, raw: text.slice(0, 500) });
  } catch (e) {
    clearTimeout(timer);
    const msg = e.name === 'AbortError' ? 'Request timed out' : e.message;
    console.error('[AI Scanner] error:', msg);
    res.status(502).json({ error: msg, blocked: false });
  }
});

// Serve the app at root
app.get('/', (_req, res) => {
  res.sendFile(path.join(__dirname, 'trend-bank.html'));
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`\n  Trend Bank running → http://localhost:${PORT}\n`);
});
