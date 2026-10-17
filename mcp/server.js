// DG Bank MCP server: banking tools for C-3PO over MCP Streamable HTTP at /mcp.
//
// The demo reaches it two ways:
//   - directly from the DG Bank app (Test 3: no gateway, every tool call runs)
//   - as an MCP upstream of the TrendAI AI Gateway (Test 4: the gateway discovers the tools
//     and applies access rules and guardrails to every call)
//
// Stateless: each request gets its own server and transport, so any replica can answer.
// When MCP_TOKEN is set, callers must send "Authorization: Bearer <MCP_TOKEN>" — the
// "Secret token" auth option in the gateway's MCP upstream form.

const express = require('express');
const { McpServer } = require('@modelcontextprotocol/sdk/server/mcp.js');
const { StreamableHTTPServerTransport } = require('@modelcontextprotocol/sdk/server/streamableHttp.js');
const { z } = require('zod');
const { CUSTOMER, ACCOUNTS, TRANSACTIONS, ALL_CUSTOMERS } = require('./data');

const PORT      = process.env.PORT || 8080;
const MCP_TOKEN = (process.env.MCP_TOKEN || '').trim();

const result = (obj) => ({ content: [{ type: 'text', text: JSON.stringify(obj, null, 2) }] });

function buildServer() {
  const server = new McpServer({ name: 'dgbank-mcp', version: '1.0.0' });

  server.registerTool('get_balance', {
    title: 'Get balance',
    description: "Return the customer's account balances.",
    inputSchema: {},
  }, async () => result({ customerId: CUSTOMER.customerId, accounts: ACCOUNTS }));

  server.registerTool('list_transactions', {
    title: 'List transactions',
    description: "Return the customer's most recent transactions, newest first.",
    inputSchema: { limit: z.number().int().min(1).max(20).optional().describe('How many to return (default 5)') },
  }, async ({ limit = 5 }) => result({ transactions: TRANSACTIONS.slice(0, limit) }));

  server.registerTool('freeze_card', {
    title: 'Freeze card',
    description: "Temporarily freeze the customer's card.",
    inputSchema: { reason: z.string().max(200).optional() },
  }, async ({ reason }) => result({
    card: `${CUSTOMER.card.product} •••• ${CUSTOMER.card.last4}`, status: 'frozen',
    reason: reason || 'customer request', reference: `FRZ-${Date.now().toString(36).toUpperCase()}`,
  }));

  server.registerTool('transfer_funds', {
    title: 'Transfer funds',
    description: 'Transfer money from the customer\'s checking account to another account (mock: nothing moves).',
    inputSchema: {
      toAccount: z.string().min(3).max(34).describe('Destination account number'),
      amount:    z.number().positive().max(1000000).describe('Amount in USD'),
      memo:      z.string().max(140).optional(),
    },
  }, async ({ toAccount, amount, memo }) => result({
    status: 'completed', from: 'CHK-4521', to: toAccount, amount, currency: 'USD', memo: memo || '',
    reference: `TRF-${Date.now().toString(36).toUpperCase()}`,
  }));

  server.registerTool('get_customer_profile', {
    title: 'Get customer profile',
    description: "Return the customer's contact and identity details.",
    inputSchema: {},
  }, async () => result(CUSTOMER));

  server.registerTool('export_customer_records', {
    title: 'Export customer records',
    description: 'Bulk export of every customer record in the bank (back-office use only).',
    inputSchema: {},
  }, async () => result({ exported: ALL_CUSTOMERS.length, records: ALL_CUSTOMERS }));

  return server;
}

const app = express();
app.use(express.json({ limit: '1mb' }));

app.get('/health', (_req, res) => res.json({ ok: true }));

app.use('/mcp', (req, res, next) => {
  if (MCP_TOKEN && req.headers.authorization !== `Bearer ${MCP_TOKEN}`) {
    return res.status(401).json({ jsonrpc: '2.0', error: { code: -32001, message: 'Unauthorized' }, id: null });
  }
  next();
});

app.post('/mcp', async (req, res) => {
  const server    = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on('close', () => { transport.close(); server.close(); });
  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
    const call = req.body?.method === 'tools/call' ? ` ${req.body.params?.name}` : '';
    console.log(`[MCP] ${req.body?.method || '?'}${call}`);
  } catch (e) {
    console.error('[MCP] error:', e.message);
    if (!res.headersSent) {
      res.status(500).json({ jsonrpc: '2.0', error: { code: -32603, message: 'Internal error' }, id: null });
    }
  }
});

// Stateless server: no SSE stream or session to resume or delete
const methodNotAllowed = (_req, res) =>
  res.status(405).json({ jsonrpc: '2.0', error: { code: -32000, message: 'Method not allowed' }, id: null });
app.get('/mcp', methodNotAllowed);
app.delete('/mcp', methodNotAllowed);

app.listen(PORT, () => console.log(`dgbank-mcp listening on :${PORT}${MCP_TOKEN ? ' (token required)' : ''}`));
