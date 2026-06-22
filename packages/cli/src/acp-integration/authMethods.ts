/**
 * @license
 * Copyright 2025 Qwen Team
 * SPDX-License-Identifier: Apache-2.0
 */

import { AuthType } from '@qwen-code/qwen-code-core';
import type { AuthMethod } from '@agentclientprotocol/sdk';

export function buildAuthMethods(): AuthMethod[] {
  return [
    {
      id: AuthType.DP_AUTH,
      name: 'Use Nestor / DP auth',
      description:
        'Requires BLAZE_DP_TOKEN/DP_TOKEN for Nestor token exchange, or BLAZE_DP_JWT/NESSY_CLI_DP_AUTH_TOKEN for delegated JWT auth',
      _meta: {
        type: 'terminal',
        args: ['--auth-type=dp-auth'],
      },
    },
    {
      id: AuthType.USE_OPENAI,
      name: 'Use OpenAI API key',
      description: 'Requires setting the `OPENAI_API_KEY` environment variable',
      _meta: {
        type: 'terminal',
        args: ['--auth-type=openai'],
      },
    },
  ];
}

export function pickAuthMethodsForAuthRequired(
  selectedType?: AuthType | string,
): AuthMethod[] {
  const authMethods = buildAuthMethods();
  if (selectedType) {
    const matched = authMethods.filter((method) => method.id === selectedType);
    return matched.length ? matched : authMethods;
  }

  return authMethods;
}
