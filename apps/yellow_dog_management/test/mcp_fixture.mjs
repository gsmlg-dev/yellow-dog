// Disposable external OAuth issuer used only by the real-client integration gate.
import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export const scopes = 'config:read nodes:write data:write targets:publish sync:run sync:settings audit:read ui:admin';
const directory = process.env.MANAGEMENT_INTEGRATION_DIR;
export async function fixture() {
  assert.ok(directory?.startsWith('/tmp/yellow-dog-management-integration.'), 'Use the disposable integration shell');
  return JSON.parse(await readFile(join(directory, 'issuer.json'), 'utf8'));
}
export function jwt(config, profile = 'access', claims = {}) {
  const gateway = profile === 'gateway';
  const now = Math.floor(Date.now() / 1000);
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: gateway ? 'yd-gateway+jwt' : 'at+jwt', kid: profile })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ iss: gateway ? `${config.issuer}/gateway` : config.issuer,
    sub: 'integration-operator', client_id: 'integration-client', aud: gateway ? 'management-ui-fixture' : config.resource,
    iat: now, exp: now + (gateway ? 300 : 1800), scope: scopes, ...claims })).toString('base64url');
  const input = `${header}.${payload}`;
  return `${input}.${sign('RSA-SHA256', Buffer.from(input), config[`${profile}Private`]).toString('base64url')}`;
}

if (process.argv[2] === 'prepare') {
  assert.ok(directory?.startsWith('/tmp/yellow-dog-management-integration.'));
  const config = { issuer: process.env.MANAGEMENT_OAUTH_FIXTURE_URL, resource: process.env.MANAGEMENT_UI_URL,
    secret: randomBytes(32).toString('hex') };
  for (const profile of ['access', 'gateway']) {
    const keys = generateKeyPairSync('rsa', { modulusLength: 2048 });
    config[`${profile}Private`] = keys.privateKey.export({ type: 'pkcs8', format: 'pem' });
    const jwk = { ...keys.publicKey.export({ format: 'jwk' }), kid: profile, alg: 'RS256', use: 'sig' };
    await writeFile(join(directory, `${profile}-jwks.json`), JSON.stringify({ keys: [jwk] }), { mode: 0o600 });
  }
  await writeFile(join(directory, 'issuer.json'), JSON.stringify(config), { mode: 0o600 });
} else if (process.argv[2] === 'serve') {
  const config = await fixture();
  const publicJwks = JSON.parse(await readFile(join(directory, 'access-jwks.json'), 'utf8'));
  const server = createServer(async (request, response) => {
    const json = (status, data) => { response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); response.end(JSON.stringify(data)); };
    if (request.url === '/.well-known/oauth-authorization-server') {
      return json(200, { issuer: config.issuer, authorization_endpoint: `${config.issuer}/authorize`, token_endpoint: `${config.issuer}/token`, jwks_uri: `${config.issuer}/jwks`,
        response_types_supported: [], grant_types_supported: ['client_credentials'], token_endpoint_auth_methods_supported: ['client_secret_basic'], scopes_supported: scopes.split(' ') });
    }
    if (request.url === '/jwks') return json(200, publicJwks);
    if (request.url?.split('?')[0] === '/authorize') return json(400, { error: 'unsupported_response_type', error_description: 'This fixture supports client_credentials only' });
    if (request.url === '/token' && request.method === 'POST') {
      let body = ''; for await (const chunk of request) body += chunk;
      const params = new URLSearchParams(body);
      const clientId = ['integration-client', 'integration-reader'].find(id =>
        request.headers.authorization === `Basic ${Buffer.from(`${id}:${config.secret}`).toString('base64')}`);
      if (!clientId ||
          params.get('grant_type') !== 'client_credentials' || params.get('resource') !== config.resource) {
        return json(401, { error: 'invalid_client' });
      }
      const requested = params.get('scope') || scopes;
      if (requested.split(' ').some(value => !scopes.split(' ').includes(value))) return json(400, { error: 'invalid_scope' });
      // The external issuer grants only the client's registered permission set,
      // independently of the SDK's metadata-based requested-scope selection.
      const permitted = clientId === 'integration-reader' ? ['config:read'] : scopes.split(' ');
      const scope = requested.split(' ').filter(value => permitted.includes(value)).join(' ');
      return json(200, { access_token: jwt(config, 'access', { scope, client_id: clientId }), token_type: 'Bearer', expires_in: 1800, scope });
    }
    return json(404, { error: 'not_found' });
  });
  server.listen(Number(new URL(config.issuer).port), '127.0.0.1');
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
}
