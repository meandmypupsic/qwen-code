import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  hasDpAuthCredentials,
  loadCachedCredentials,
  resolveDpCredentials,
  saveCredentials,
} from './dpTokenManager.js';

function fakeJwt(payload: Record<string, unknown>): string {
  const header = Buffer.from(
    JSON.stringify({ alg: 'none', typ: 'JWT' }),
  ).toString('base64url');
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  return `${header}.${body}.signature`;
}

describe('dpTokenManager', () => {
  let tempDir: string | undefined;

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    if (tempDir) {
      fs.rmSync(tempDir, { recursive: true, force: true });
      tempDir = undefined;
    }
  });

  function useTempCredentialsPath(): string {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'blaze-dp-auth-'));
    const filePath = path.join(tempDir, 'dp_auth_creds.json');
    vi.stubEnv('BLAZE_DP_CREDENTIALS_PATH', filePath);
    return filePath;
  }

  it('resolves delegated JWT from Blaze env', async () => {
    useTempCredentialsPath();
    const jwt = fakeJwt({
      exp: Math.floor(Date.now() / 1000) + 3600,
      sub: 'user-1',
      preferred_username: 'sergey',
    });
    vi.stubEnv('BLAZE_DP_JWT', jwt);

    const credentials = await resolveDpCredentials();

    expect(credentials.jwt).toBe(jwt);
    expect(credentials.source).toBe('env-jwt');
    expect(credentials.sourceEnvKey).toBe('BLAZE_DP_JWT');
    expect(credentials.username).toBe('sergey');
    expect(hasDpAuthCredentials()).toBe(true);
  });

  it('loads valid Blaze Runtime cache from disk', () => {
    useTempCredentialsPath();
    const jwt = fakeJwt({
      exp: Math.floor(Date.now() / 1000) + 3600,
      sub: 'cached-user',
    });
    saveCredentials({
      jwt,
      expiresAt: Date.now() + 3600_000,
      username: 'cached',
      userId: 'cached-user',
    });

    const cached = loadCachedCredentials();

    expect(cached?.source).toBe('cache');
    expect(cached?.jwt).toBe(jwt);
    expect(hasDpAuthCredentials()).toBe(true);
  });

  it('ignores stale non-JWT explicit apiKey when BLAZE_DP_TOKEN can be exchanged', async () => {
    useTempCredentialsPath();
    const jwt = fakeJwt({
      exp: Math.floor(Date.now() / 1000) + 3600,
      sub: 'env-token-user',
    });
    vi.stubEnv('BLAZE_DP_TOKEN', 'ory_at_from_env');
    const fetchMock = vi.fn(async (_url: string, init?: RequestInit) => {
      expect(init?.headers).toMatchObject({
        Authorization: 'Bearer ory_at_from_env',
      });
      return new Response(JSON.stringify({ jwt }), { status: 200 });
    });
    vi.stubGlobal('fetch', fetchMock);

    const credentials = await resolveDpCredentials('stale-openai-key');

    expect(credentials.jwt).toBe(jwt);
    expect(credentials.source).toBe('dp-token');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('can exchange an explicit raw DP token when it looks like an Ory access token', async () => {
    useTempCredentialsPath();
    const jwt = fakeJwt({
      exp: Math.floor(Date.now() / 1000) + 3600,
      sub: 'explicit-token-user',
    });
    const fetchMock = vi.fn(async (_url: string, init?: RequestInit) => {
      expect(init?.headers).toMatchObject({
        Authorization: 'Bearer ory_at_explicit',
      });
      return new Response(JSON.stringify({ jwt }), { status: 200 });
    });
    vi.stubGlobal('fetch', fetchMock);

    const credentials = await resolveDpCredentials('ory_at_explicit');

    expect(credentials.jwt).toBe(jwt);
    expect(credentials.source).toBe('dp-token');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('rejects a non-JWT explicit apiKey when no DP token, JWT, or cache exists', async () => {
    useTempCredentialsPath();

    await expect(resolveDpCredentials('stale-openai-key')).rejects.toThrow(
      'DP auth received a non-JWT apiKey value',
    );
  });
});
