// Gr3yLabs Support - pairing relay test harness.
//
// Runs the REAL Worker source (../../cloudflare/export-relay-worker.js) against an
// in-memory stand-in for Workers KV, so the relay's routes can be tested without Cloudflare.
//
//   node tests/relay/harness.mjs test           -> route assertions, prints ALL WORKER TESTS PASSED
//   node tests/relay/harness.mjs serve <port>    -> local HTTP relay for PowerShell end-to-end tests
//
// "serve" prints a throwaway test admin key on start - a fixed local fixture, not a secret.
// Point Export-InstalledApps.ps1 at it with -RelayUrl http://127.0.0.1:<port>.
//
// WHAT THIS CANNOT TEST: a plain Map is strongly consistent with no edge cache. Real
// Workers KV is eventually consistent and caches "not found" reads, so the timing between
// /open, /submit and /poll must be confirmed against the live deployed relay. Needs Node 18+
// (global fetch/Request/Response/crypto). The Worker is an ES module with no imports, so it
// is loaded from a data: URL - no temp files are written.

import http from 'node:http';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const WORKER_URL = new URL('../../cloudflare/export-relay-worker.js', import.meta.url);
const src = readFileSync(WORKER_URL, 'utf8');
const worker = (await import('data:text/javascript;base64,' + Buffer.from(src).toString('base64'))).default;

function makeKv() {
  const store = new Map();
  return {
    store,
    async get(k) { return store.has(k) ? store.get(k).value : null; },
    async put(k, value, opts = {}) { store.set(k, { value, metadata: opts.metadata ?? null, ttl: opts.expirationTtl }); },
    async delete(k) { store.delete(k); },
    async list({ prefix = '', cursor } = {}) {
      const names = [...store.keys()].filter(n => n.startsWith(prefix)).sort();
      // Page size 2 so the cursor loop in the Worker actually gets exercised.
      const start = cursor ? Number(cursor) : 0;
      const page = names.slice(start, start + 2);
      const done = start + 2 >= names.length;
      return { keys: page.map(n => ({ name: n, metadata: store.get(n).metadata })), list_complete: done, cursor: done ? undefined : String(start + 2) };
    },
  };
}

const ADMIN = 'AdminCode-Long-Enough-123';
const env = { EXPORT_RELAY_KV: makeKv(), ADMIN_KEY: ADMIN };
const call = (method, path, headers = {}, body) =>
  worker.fetch(new Request('https://relay.test' + path, { method, headers, body }), env);

async function runTests() {
  let r;
  // --- admin auth ---
  r = await call('GET', '/admin/keys'); assert.equal(r.status, 401, 'no key');
  r = await call('GET', '/admin/keys', { 'X-Access-Key': 'wrong' }); assert.equal(r.status, 401, 'wrong admin');
  r = await call('GET', '/admin/keys', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 200);
  assert.match(r.headers.get('Content-Type'), /charset=utf-8/, 'json has charset');
  assert.equal(r.headers.get('Cache-Control'), 'no-store', 'no-store header');
  assert.equal(r.headers.get('X-Content-Type-Options'), 'nosniff', 'nosniff header');
  assert.deepEqual(await r.json(), []);
  r = await call('POST', '/admin/keys', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, 'label required');
  r = await call('POST', '/admin/keys?label=Mike', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 200);
  const mike = await r.json();
  assert.match(mike.key, /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/);
  assert.equal(mike.enabled, true); assert.equal(mike.label, 'Mike');
  r = await call('POST', '/admin/keys?label=Zed', { 'X-Access-Key': ADMIN }); const zed = await r.json();
  r = await call('POST', '/admin/keys?label=Amy', { 'X-Access-Key': ADMIN }); await r.json();
  // hand-added dashboard entry: no metadata, custom code, enabled stored as a boolean
  await env.EXPORT_RELAY_KV.put('guest:HANDMADE1', JSON.stringify({ label: 'Dash', enabled: true }));
  r = await call('GET', '/admin/keys', { 'X-Access-Key': ADMIN });
  const list = await r.json();
  assert.deepEqual(list.map(k => k.label), ['Amy', 'Dash', 'Mike', 'Zed'], 'sorted + paged + hand-added');
  assert.equal(list.find(k => k.label === 'Dash').key, 'HAND-MADE-1');

  // --- pairing with a guest code (lowercase, no dashes still matches) ---
  const guestLoose = mike.key.replace(/-/g, '').toLowerCase();
  r = await call('POST', '/open?code=ABC234', { 'X-Access-Key': guestLoose }); assert.equal(r.status, 200);
  const open = await r.json(); assert.equal(open.label, 'Mike'); assert.ok(open.session);
  r = await call('POST', '/open?code=ABC234', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 409, 'code in use');
  r = await call('GET', '/poll?code=ABC234', { 'X-Session': open.session }); assert.equal(r.status, 404, 'nothing yet');
  r = await call('POST', '/submit?code=ZZZ999'); assert.equal(r.status, 404, 'submit to unopened code');
  r = await call('POST', '/submit?code=ABC234', {}, ''); assert.equal(r.status, 400, 'empty body');
  r = await call('POST', '/submit?code=ABC234', {}, '{"hostname":"OLD"}'); assert.equal(r.status, 200);
  r = await call('POST', '/submit?code=ABC234', {}, '{"hostname":"EVIL"}'); assert.equal(r.status, 409, 'one-time submit');
  r = await call('GET', '/poll?code=ABC234'); assert.equal(r.status, 401, 'no session');
  r = await call('GET', '/poll?code=ABC234', { 'X-Session': 'nope' }); assert.equal(r.status, 401, 'wrong session');
  r = await call('GET', '/poll?code=ABC234', { 'X-Session': open.session }); assert.equal(r.status, 200);
  assert.match(r.headers.get('Content-Type'), /application\/json; charset=utf-8/, 'poll body has charset');
  assert.equal(await r.text(), '{"hostname":"OLD"}');
  r = await call('GET', '/poll?code=ABC234', { 'X-Session': open.session }); assert.equal(r.status, 404, 'claimed once');
  assert.equal(env.EXPORT_RELAY_KV.store.has('slot:ABC234'), false, 'slot cleaned up');

  // --- non-ASCII round-trips intact (byte-for-byte) ---
  r = await call('POST', '/open?code=UTF234', { 'X-Access-Key': ADMIN }); const u = await r.json();
  const unicodeBody = JSON.stringify({ installedProgramNames: ['Café ™ 日本 – x'] });
  r = await call('POST', '/submit?code=UTF234', {}, unicodeBody); assert.equal(r.status, 200);
  r = await call('GET', '/poll?code=UTF234', { 'X-Session': u.session });
  assert.equal(await r.text(), unicodeBody, 'unicode export round-trips intact');

  // --- /close drops the slot (idempotent) ---
  r = await call('POST', '/open?code=CLS234', { 'X-Access-Key': ADMIN }); const cl = await r.json();
  r = await call('POST', '/close?code=CLS234', { 'X-Session': 'wrong' }); assert.equal(r.status, 200, 'close is always 200');
  assert.equal(env.EXPORT_RELAY_KV.store.has('slot:CLS234'), true, 'wrong session does not close');
  r = await call('POST', '/close?code=CLS234', { 'X-Session': cl.session }); assert.equal(r.status, 200);
  assert.equal(env.EXPORT_RELAY_KV.store.has('slot:CLS234'), false, 'right session closes');
  r = await call('POST', '/submit?code=CLS234', {}, '{"x":1}'); assert.equal(r.status, 404, 'submit after close -> 404');

  // --- disable / enable / delete ---
  r = await call('POST', `/admin/keys/${mike.key}/disable`, { 'X-Access-Key': ADMIN }); assert.equal(r.status, 200);
  assert.equal((await r.json()).enabled, false);
  r = await call('POST', '/open?code=DEF345', { 'X-Access-Key': mike.key }); assert.equal(r.status, 401, 'disabled guest');
  r = await call('GET', '/admin/keys', { 'X-Access-Key': mike.key }); assert.equal(r.status, 401, 'guest is not admin');
  r = await call('POST', `/admin/keys/${mike.key}/enable`, { 'X-Access-Key': ADMIN }); assert.equal((await r.json()).enabled, true);
  r = await call('POST', '/open?code=DEF345', { 'X-Access-Key': mike.key }); assert.equal(r.status, 200, 're-enabled guest');
  r = await call('DELETE', `/admin/keys/${zed.key}`, { 'X-Access-Key': ADMIN }); assert.equal(r.status, 200);
  r = await call('POST', '/open?code=GHJ456', { 'X-Access-Key': zed.key }); assert.equal(r.status, 401, 'deleted guest');
  r = await call('DELETE', `/admin/keys/${zed.key}`, { 'X-Access-Key': ADMIN }); assert.equal(r.status, 404, 'already deleted');
  r = await call('POST', '/open?code=HAND22', { 'X-Access-Key': 'handmade1' }); assert.equal(r.status, 200, 'hand-added guest works');

  // --- enabled:"false" (a string) counts as OFF ---
  await env.EXPORT_RELAY_KV.put('guest:STRFALSE1', JSON.stringify({ label: 'Str', enabled: 'false' }));
  r = await call('POST', '/open?code=STR234', { 'X-Access-Key': 'strfalse1' }); assert.equal(r.status, 401, 'enabled string false is off');
  r = await call('GET', '/admin/keys', { 'X-Access-Key': ADMIN });
  assert.equal((await r.json()).find(k => k.label === 'Str').enabled, false, 'list shows string-false as off');

  // --- admin code can pair; a short/whitespace ADMIN_KEY disables admin (503) ---
  r = await call('POST', '/open?code=KMN567', { 'X-Access-Key': ADMIN }); assert.equal((await r.json()).label, 'admin');
  const weakEnv = { EXPORT_RELAY_KV: makeKv(), ADMIN_KEY: 'short' };
  r = await worker.fetch(new Request('https://relay.test/admin/keys', { headers: { 'X-Access-Key': 'short' } }), weakEnv);
  assert.equal(r.status, 503, 'short admin key -> admin not configured');
  // A correct key saved with a trailing newline still matches (trimmed both sides).
  const trimEnv = { EXPORT_RELAY_KV: makeKv(), ADMIN_KEY: ADMIN + '\n' };
  r = await worker.fetch(new Request('https://relay.test/admin/keys', { headers: { 'X-Access-Key': ADMIN } }), trimEnv);
  assert.equal(r.status, 200, 'trailing-newline ADMIN_KEY still matches');

  // --- code pattern: reject 4-5 chars and non-ASCII before upper-casing ---
  r = await call('POST', '/open?code=ABCD', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, '4-char code rejected');
  r = await call('POST', '/open?code=ABCDE', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, '5-char code rejected');
  r = await call('POST', '/open?code=ſſſſſſ', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, 'U+017F code rejected');

  // --- body-size: 413 not 400, and Content-Length short-circuit ---
  r = await call('POST', '/open?code=BIG234', { 'X-Access-Key': ADMIN }); await r.json();
  r = await call('POST', '/submit?code=BIG234', {}, 'x'.repeat(1024 * 1024 + 1)); assert.equal(r.status, 413, 'oversize -> 413');
  r = await call('POST', '/submit?code=BIG234', { 'Content-Length': String(1024 * 1024 + 5) }, 'xxxxx'); assert.equal(r.status, 413, 'declared oversize -> 413');

  // --- malformed %-escape in an admin path -> 400, not a crash ---
  r = await call('DELETE', '/admin/keys/ABC%', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 400, 'bad percent-escape -> 400');

  // --- misc ---
  r = await call('GET', '/poll'); assert.equal(r.status, 400);
  r = await call('GET', '/whatever?code=ABC234'); assert.equal(r.status, 404);
  r = await call('PUT', '/admin/keys', { 'X-Access-Key': ADMIN }); assert.equal(r.status, 405);

  // guest codes: only alphabet characters, no duplicates across 2000 generated
  const seen = new Set();
  for (let i = 0; i < 2000; i++) {
    const g = await (await call('POST', '/admin/keys?label=x' + i, { 'X-Access-Key': ADMIN })).json();
    assert.match(g.key, /^[A-HJ-NP-Z2-9-]{14}$/); assert.ok(!seen.has(g.key)); seen.add(g.key);
  }
  console.log('ALL WORKER TESTS PASSED');
}

const mode = process.argv[2];
if (mode === 'test') {
  await runTests();
} else if (mode === 'serve') {
  const port = Number(process.argv[3] || 8787);
  // --no-admin-key starts the relay with ADMIN_KEY unset, to exercise the 503 "admin not
  // configured" path the way a freshly deployed Worker without the secret behaves.
  const noAdminKey = process.argv.includes('--no-admin-key');
  if (noAdminKey) env.ADMIN_KEY = '';
  http.createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = chunks.length ? Buffer.concat(chunks) : undefined;
    const request = new Request(`http://127.0.0.1:${port}${req.url}`, {
      method: req.method, headers: req.headers,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : body,
    });
    const response = await worker.fetch(request, env);
    console.log(`${req.method} ${req.url} -> ${response.status}`);
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
  }).listen(port, '127.0.0.1', () => console.log(`relay on ${port}, admin=${noAdminKey ? '(none)' : ADMIN}`));
} else {
  console.error('Usage: node tests/relay/harness.mjs test | serve <port> [--no-admin-key]');
  process.exit(2);
}
