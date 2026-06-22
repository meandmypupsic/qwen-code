/**
 * @license
 * Copyright 2025 Qwen Team
 * SPDX-License-Identifier: Apache-2.0
 */

import { describe, expect, it } from 'vitest';
import { AuthType } from '@qwen-code/qwen-code-core';
import {
  buildAuthMethods,
  pickAuthMethodsForAuthRequired,
} from './authMethods.js';

describe('ACP auth methods', () => {
  it('does not advertise discontinued Qwen OAuth', () => {
    const authMethods = buildAuthMethods();

    expect(authMethods.map((method) => method.id)).toEqual([
      AuthType.DP_AUTH,
      AuthType.USE_OPENAI,
    ]);
  });

  it('falls back to working methods for a stored discontinued Qwen OAuth selection', () => {
    const authMethods = pickAuthMethodsForAuthRequired('qwen-oauth');

    expect(authMethods.map((method) => method.id)).toEqual([
      AuthType.DP_AUTH,
      AuthType.USE_OPENAI,
    ]);
  });

  it('returns only DP auth when DP auth is already selected', () => {
    const authMethods = pickAuthMethodsForAuthRequired(AuthType.DP_AUTH);

    expect(authMethods.map((method) => method.id)).toEqual([
      AuthType.DP_AUTH,
    ]);
  });
});
