// Owned loopback fixture only. No database, external provider, or real account.
import http from 'node:http';
import { createPublicKey, verify } from 'node:crypto';
import { writeFileSync } from 'node:fs';
const owner = '01J00000000000000000000001';
const device = '01J00000000000000000000002';
let flags, counts, enrolled, refresh, tokens, nonces, serial, home, events;
function reset() {
  flags = {}; counts = {}; enrolled = null; refresh = 'legacy-fixture-refresh'; tokens = new Map();
  nonces = new Map(); serial = 0; home = 'fixture-home'; events = [];
}
reset();
function json(res, value, status = 200) { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(value)); }
function fail(res, code, status = 401) { json(res, { error: { code } }, status); }
function exact(value, keys) { return Object.keys(value).sort().join(',') === keys.sort().join(','); }
function proof(publicKey, signature, message) {
  const der = Buffer.from(publicKey, 'base64'); const sig = Buffer.from(signature, 'base64');
  if (der.length !== 91 || sig.length !== 64 || der.toString('base64') !== publicKey) throw Error('encoding');
  const key = createPublicKey({ key: der, format: 'der', type: 'spki' });
  if (key.asymmetricKeyDetails.namedCurve !== 'prime256v1' || !verify('sha256', Buffer.from(message), { key, dsaEncoding: 'ieee-p1363' }, sig)) throw Error('proof');
}
function answer(isLegacy = false, isLogin = false) {
  const accessToken = `fixture-access-${++serial}`; tokens.set(accessToken, true);
  return { accessToken, accessExpiresIn: 3600, user: { id: flags.wrongOwner ? 'other-owner' : owner, email: 'fixture@example.invalid', displayName: 'Fixture' },
    ...(isLegacy ? { refreshToken: refresh, deviceId: device } : isLogin ? { deviceId: device } : {}) };
}
const leakServer = http.createServer((_req, res) => { counts.leaks = (counts.leaks ?? 0) + 1; json(res, {}); });
await new Promise(resolve => leakServer.listen(0, '127.0.0.1', resolve));
const server = http.createServer(async (req, res) => {
  try {
    const path = new URL(req.url, 'http://fixture').pathname;
    const bytes = []; for await (const chunk of req) bytes.push(chunk);
    const body = bytes.length ? JSON.parse(Buffer.concat(bytes).toString()) : {};
    if (path === '/fixture/reset') { reset(); json(res, {}); return; }
    if (path === '/fixture/configure') { Object.assign(flags, body); if (body.expireAccess) tokens.clear(); if ('home' in body) home = body.home; json(res, {}); return; }
    if (path === '/fixture/status') { json(res, { counts, events, enrolled: !!enrolled, refreshActive: !!refresh }); return; }
    counts[path] = (counts[path] ?? 0) + 1; events.push(path);
    if (flags.refuseAll) { fail(res, 'server.offline', 503); return; }
    if (req.headers.cookie) throw Error('unexpected cookie');
    if (path === '/api/v1/auth/native/login/start') {
      if (!exact(body, ['email'])) throw Error('start shape');
      json(res, { challenge: { kind: 'email_code', state: `fixture-state-${++serial}`, email: 'fixture@example.invalid', expiresAt: new Date(Date.now()+60000).toISOString() } }); return;
    }
    if (path === '/api/v1/auth/native/login/complete') {
      if (!exact(body, ['state', 'email', 'code', 'device']) || !exact(body.device, ['kind', 'label', 'publicKey', 'keyProof']) || body.device.kind !== 'desktop') throw Error('login shape');
      proof(body.device.publicKey, body.device.keyProof, `${body.state}|${body.email}|${body.device.publicKey}`);
      if (body.code !== '123456') { fail(res, 'auth.code_invalid'); return; }
      if (enrolled) { fail(res, 'validation.conflict', 409); return; }
      enrolled = body.device.publicKey;
      const value = answer(false, true);
      if (flags.loginDisconnected) { req.socket.destroy(); return; }
      if (flags.loginLost) { fail(res, 'fixture.committed_response_lost', 503); return; }
      res.setHeader('Set-Cookie', 'must-not-be-replayed=1'); json(res, value); return;
    }
    if (path === '/api/v1/auth/native/refresh') {
      if (!exact(body, ['deviceId', 'refreshToken']) || body.deviceId !== device) throw Error('refresh shape');
      if (body.refreshToken !== refresh || !refresh) { fail(res, 'auth.token_invalid'); return; }
      refresh = `rotated-fixture-${++serial}`;
      const value = answer(true);
      if (flags.refreshLost) { fail(res, 'fixture.committed_response_lost', 503); return; }
      json(res, value); return;
    }
    if (path === '/api/v1/auth/device/challenge') {
      if (!exact(body, ['deviceId']) || body.deviceId !== device) throw Error('challenge shape');
      if (flags.terminal) { fail(res, flags.terminal, flags.terminal === 'auth.user_disabled' ? 403 : 401); return; }
      const nonce = `nonce-${++serial}`, sentAt = '2026-09-22T10:11:12.123Z'; nonces.set(nonce, sentAt);
      json(res, { nonce, sentAt, expiresInSec: 60 }); return;
    }
    if (path === '/api/v1/auth/device/token') {
      if (!exact(body, ['deviceId', 'nonce', 'signature']) || body.deviceId !== device) throw Error('token shape');
      const sentAt = nonces.get(body.nonce); nonces.delete(body.nonce);
      if (!sentAt || !enrolled) { fail(res, 'auth.device_challenge_expired', 409); return; }
      proof(enrolled, body.signature, `${body.nonce}|${body.deviceId}|${sentAt}`);
      if (flags.challengeExpired) { flags.challengeExpired = false; fail(res, 'auth.device_challenge_expired', 409); return; }
      if (flags.terminal) { fail(res, flags.terminal, flags.terminal === 'auth.user_disabled' ? 403 : 401); return; }
      refresh = null; // real gateway revokes all legacy refresh tokens here
      const value = answer();
      if (flags.delayToken) await new Promise(resolve => setTimeout(resolve, flags.delayToken));
      if (flags.proofLost) { fail(res, 'fixture.committed_response_lost', 503); return; }
      json(res, value); return;
    }
    if (!tokens.has(req.headers.authorization?.replace(/^Bearer /, ''))) { fail(res, 'auth.token_expired'); return; }
    if (flags.terminal) { fail(res, flags.terminal, flags.terminal === 'auth.user_disabled' ? 403 : 401); return; }
    if (path === '/api/v1/auth/device/key') {
      if (!exact(body, ['publicKey', 'keyProof'])) throw Error('enroll shape');
      proof(body.publicKey, body.keyProof, `${device}|${body.publicKey}`);
      if (enrolled && enrolled !== body.publicKey) { fail(res, 'validation.conflict', 409); return; }
      enrolled = body.publicKey;
      if (flags.enrollLost) { fail(res, 'fixture.committed_response_lost', 503); return; }
      json(res, { deviceId: device, keyEnrolledAt: new Date().toISOString() }); return;
    }
    if (path === '/api/v1/me/homes/continuable') { json(res, { ...(home ? { serving: { homeId: home, label: 'Fixture home' } } : {}), continuable: [], notOffered: [] }); return; }
    if (path === `/api/v1/me/devices/${device}` && req.method === 'DELETE') { tokens.clear(); enrolled = null; json(res, { deviceId: device, reason: 'signed_out', revokedAt: new Date().toISOString() }); return; }
    if (path === '/api/v1/sync') {
      if (flags.redirect) { res.writeHead(302, { location: `http://127.0.0.1:${leakServer.address().port}/leak` }); res.end(); return; }
      json(res, { protocolVersion: 1, supportsBlobs: false }); return;
    }
    fail(res, 'fixture.route_missing', 404);
  } catch (error) {
    events.push(`INVALID:${error.message}`); fail(res, 'fixture.invalid_request', 400);
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
writeFileSync(process.argv[2], JSON.stringify({ origin: `http://127.0.0.1:${server.address().port}` }));
