// Run against wrangler's LOCAL runtime only, with the documented fixture key.
// npx wrangler dev --local --config cloudflare/wrangler.local.toml --port 8789 --var ADMIN_KEY:LocalFixtureOnly-123456789
// node tests/relay/runtime.mjs
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
const base = 'http://127.0.0.1:8789';
const code = randomBytes(4).toString('hex').toUpperCase();
const call = (path, method, headers = {}, body) => fetch(`${base}${path}?code=${code}`, { method, headers, body });
const opens = await Promise.all(Array.from({ length: 20 }, () => call('/open', 'POST', { 'X-Access-Key': 'LocalFixtureOnly-123456789' })));
assert.equal(opens.filter(r => r.status === 200).length, 1, 'one open wins');
assert.equal(opens.filter(r => r.status === 409).length, 19);
const { session } = await opens.find(r => r.status === 200).json();
const sends = await Promise.all(Array.from({ length: 20 }, (_, i) => call('/submit', 'POST', {}, JSON.stringify({ fixture: i }))));
assert.equal(sends.filter(r => r.status === 200).length, 1, 'one submit wins');
assert.equal(sends.filter(r => r.status === 409).length, 19);
assert.equal((await call('/poll', 'GET', { 'X-Session': 'incorrect' })).status, 401);
const polls = await Promise.all(Array.from({ length: 20 }, () => call('/poll', 'GET', { 'X-Session': session })));
assert.equal(polls.filter(r => r.status === 200).length, 1, 'one poll consumes');
assert.equal(polls.filter(r => r.status === 404).length, 19);
const result = await polls.find(r => r.status === 200).json();
assert.equal(typeof result.fixture, 'number');
assert.equal((await call('/submit', 'POST', {}, '{}')).status, 404, 'late submit cannot refill');
assert.equal((await call('/open', 'POST', { 'X-Access-Key': 'LocalFixtureOnly-123456789' })).status, 409, 'consumed code cannot reopen before expiry');
console.log('LOCAL CLOUDFLARE RUNTIME: concurrency and one-time consumption passed');
