// Synthetic, loopback-only integration host for the native clients. It uses
// the actual Atika auth + metadata routers and a disposable test database.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { writeFile } from 'node:fs/promises';
const atika = process.env.ATIKA_REPO;
const database = process.env.DATABASE_URL;
const output = process.env.CLOUD_SYNC_FIXTURE;
if (!atika || !database || !output || !/^postgres:\/\/atika:atika@127\.0\.0\.1:55433\//.test(database)) {
  throw new Error('Use the explicit isolated local database and fixture output path');
}
const require = createRequire(resolve(atika, 'gateway/package.json'));
const { Hono } = await import(require.resolve('hono'));
const { serve } = await import(require.resolve('@hono/node-server'));
const { AuthService, createAuthRouter, generateKeySet } = await import(require.resolve('@atika/auth'));
const { createClient, runMigrations, schema } = await import(require.resolve('@atika/db'));
const { newUserId } = await import(require.resolve('@atika/ids'));
const { eq, inArray } = await import(require.resolve('drizzle-orm'));
const { SyncService } = await import(pathToFileURL(resolve(atika, 'gateway/src/sync/service.ts')).href);
const { createSyncRouter } = await import(pathToFileURL(resolve(atika, 'gateway/src/sync/routes.ts')).href);
const client = createClient(database);
await runMigrations(database);
const owners = [newUserId(), newUserId()];
const emails = owners.map((id: string) => `${id.toLowerCase()}@native-sync.fixture`);
for (let index = 0; index < owners.length; index++) {
  await client.db.insert(schema.users).values({ id: owners[index], email: emails[index], displayName: 'Synthetic native sync owner' });
}
const codes = new Map<string, string>();
const auth = new AuthService({
  client,
  jwt: { keySet: await generateKeySet(), options: { issuer: 'native-sync-fixture', audience: 'fixture', ttlSec: 900 } },
  signInCode: { sender: { send: async (email: any) => {
    if (!emails.includes(email.to)) throw new Error('Fixture accepts synthetic email recipients only');
    const match = email.text.match(/\n\n(\d{4}) (\d{4})\n/);
    if (!match) throw new Error('Cannot read synthetic email code');
    codes.set(email.to, match[1] + match[2]);
  } }, fromAddress: 'synthetic@native-sync.fixture', baseLoginUrl: 'http://localhost/login', secret: 'synthetic-native-sync-fixture' },
});
const app = new Hono();
let dropNext = false;
let redirectNext = false;
let refreshes = 0;
let leakedRequests = 0;
app.use('*', async (c: any, next: () => Promise<void>) => {
  if (c.req.path === '/api/v1/auth/native/refresh') refreshes++;
  if (redirectNext && c.req.path.startsWith('/api/v1/sync')) {
    redirectNext = false;
    return c.redirect('/fixture/redirect-sink', 302);
  }
  await next();
  if (dropNext && c.req.path === '/api/v1/sync/mutations' && c.res.status === 200) {
    dropNext = false;
    c.res = new Response(JSON.stringify({ error: { code: 'internal' } }), { status: 503, headers: { 'content-type': 'application/json' } });
  }
});
app.route('/', createAuthRouter(auth, { nativeAuthEnabled: () => true }));
app.route('/api/v1/sync', createSyncRouter({ auth, service: new SyncService(client), enabled: () => true, writesEnabled: () => true }));
app.get('/fixture/code', (c: any) => {
  const email = c.req.query('email');
  if (!emails.includes(email) || !codes.has(email)) return c.json({}, 404);
  return c.json({ code: codes.get(email) });
});
app.get('/fixture/status', (c: any) => c.json({ refreshes, leakedRequests }));
app.post('/fixture/drop-next', (c: any) => { dropNext = true; return c.json({ ok: true }); });
app.post('/fixture/redirect-next', (c: any) => { redirectNext = true; return c.json({ ok: true }); });
app.get('/fixture/redirect-sink', (c: any) => { leakedRequests++; return c.json({}); });
app.post('/fixture/revoke', async (c: any) => {
  const { deviceId } = await c.req.json();
  const [device] = await client.db.select().from(schema.devices).where(eq(schema.devices.id, deviceId));
  if (!device || !owners.includes(device.userId)) return c.json({}, 404);
  await auth.devices.revoke(device.userId, device.id);
  return c.json({ ok: true });
});
const server = serve({ fetch: app.fetch, hostname: '127.0.0.1', port: 0 }, async (address: any) => {
  await writeFile(output, JSON.stringify({ origin: `http://127.0.0.1:${address.port}`, emails }));
  process.stdout.write('Native sync fixture ready on loopback with synthetic owners\n');
});
let closing = false;
async function cleanup() {
  if (closing) return;
  closing = true;
  await new Promise<void>(done => server.close(() => done()));
  await client.db.delete(schema.syncSpaces).where(inArray(schema.syncSpaces.ownerId, owners));
  await client.db.delete(schema.signInCodes).where(inArray(schema.signInCodes.email, emails));
  await client.db.delete(schema.securityEvents).where(inArray(schema.securityEvents.targetUserId, owners));
  await client.db.delete(schema.refreshTokens).where(inArray(schema.refreshTokens.userId, owners));
  await client.db.delete(schema.devices).where(inArray(schema.devices.userId, owners));
  await client.db.delete(schema.users).where(inArray(schema.users.id, owners));
  await client.close();
}
process.on('SIGTERM', () => { void cleanup().then(() => process.exit(0)); });
process.on('SIGINT', () => { void cleanup().then(() => process.exit(0)); });
