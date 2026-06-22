# Blaze Runtime Sandbox Final Verification

This is the final MVP verification runbook for a weak follow-up agent. Follow it
exactly. Do not skip steps. Do not claim success from `health`, `preflight`,
`sessionId`, `promptId`, or `retry: 3000` alone.

Success means the full chain works:

```text
health
  -> preflight
  -> create session
  -> open SSE
  -> send prompt
  -> receive session_update
  -> send second prompt in the same session
  -> assembled streamed text equals ORBIT-17
```

## 0. Required Inputs

Set these variables before starting:

```bash
export RUNTIME_URL="<proxied-runtime-url-for-port-4170>"
export DP_TOKEN="<fresh-dp-token-for-ml-core-proxy>"
export RUNTIME_TOKEN="<the-exact-value-passed-as-BLAZE_RUNTIME_TOKEN>"
```

Rules:

- `DP_TOKEN` is sent to ML Core proxy in `Authorization`.
- `RUNTIME_TOKEN` is sent to `blaze-runtime serve` in
  `X-Blaze-Runtime-Authorization`.
- `DP_TOKEN` and `RUNTIME_TOKEN` are different security layers. Do not make them
  equal just to simplify curl commands.
- `RUNTIME_URL` must be the proxy URL for port `4170`.
- The sandbox image must be built from a version that contains the Nestor auth
  fix. The expected fixed version is `@art/blaze-runtime@0.18.5` or newer.

## 0.1. Expected Sandbox Auth Boot

The sandbox must be started with `BLAZE_DP_TOKEN` or `DP_TOKEN` in the
environment. The entrypoint must:

1. Exchange that raw DP/Ory token against Nestor:

   ```text
   POST https://code-completion-nestor.tcsbank.ru/api/v2/token
   Authorization: Bearer <BLAZE_DP_TOKEN>
   ```

2. Write the returned `.jwt` to:

   ```text
   /root/.blaze-runtime/dp_auth_creds.json
   /root/.nessy/dp_auth_creds.json
   ```

3. Export `DP_AUTH=true`.
4. Start `blaze-runtime serve`.
5. Spawn the ACP child as `blaze-runtime --acp --auth-type=dp-auth`.

If the sandbox log does not contain `Nestor credentials cache prepared`, session
creation will probably fail. Stop and inspect the entrypoint log before testing
prompts.

## 1. Health

First prove the proxy is reachable and runtime auth is enforced.

```bash
curl -i \
  -H "Authorization: Bearer $DP_TOKEN" \
  "$RUNTIME_URL/health"
```

Expected:

```text
HTTP 401
{"error":"Unauthorized"}
```

This is a good sign: ML Core proxy accepted the DP token and forwarded the
request, but `blaze-runtime` rejected it because the runtime token was missing.

Now send both headers:

```bash
curl -i \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  "$RUNTIME_URL/health"
```

Expected:

```text
HTTP 200
{"status":"ok"}
```

Stop if this does not pass. Do not continue to session/SSE until health works
with both headers.

## 2. Preflight

```bash
curl -sS \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  "$RUNTIME_URL/workspace/preflight" | tee /tmp/blaze-runtime-preflight.json | jq .
```

Expected:

- JSON is valid.
- Runtime is initialized.
- Auth/provider/model state is sane for `dp-auth` / Nestor.
- The auth cell should have `detail.source: "dp-auth"`.
- The auth cell should not say `No auth method configured`.
- If `detail.presentVar` is shown, it should usually be `BLAZE_DP_TOKEN`,
  `DP_TOKEN`, `BLAZE_DP_JWT`, or `NESSY_CLI_DP_AUTH_TOKEN`.
- There is no obvious startup/auth error.

Stop if preflight shows broken runtime state. Include
`/tmp/blaze-runtime-preflight.json` in the report with secrets redacted.

## 3. Create Session

```bash
CREATE_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "$RUNTIME_URL/session")

echo "$CREATE_RESPONSE" | tee /tmp/blaze-runtime-create-session.json | jq .

export SESSION_ID=$(echo "$CREATE_RESPONSE" | jq -r '.sessionId')
export CLIENT_ID=$(echo "$CREATE_RESPONSE" | jq -r '.clientId')

test -n "$SESSION_ID" && test "$SESSION_ID" != "null"
test -n "$CLIENT_ID" && test "$CLIENT_ID" != "null"
```

Stop if `sessionId` or `clientId` is empty or `null`.

Important: creating a session is not final success. It only proves the HTTP
daemon can create an ACP-backed session.

## 4. Open SSE Before Sending Prompts

Open the SSE stream before sending prompts. `Last-Event-ID` must be an HTTP
header, not a query parameter.

```bash
rm -f /tmp/blaze-runtime-sandbox-events.log

curl -N -sS \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "X-Qwen-Client-Id: $CLIENT_ID" \
  -H "Last-Event-ID: 0" \
  "$RUNTIME_URL/session/$SESSION_ID/events?maxQueued=1024" \
  > /tmp/blaze-runtime-sandbox-events.log &

export SSE_PID=$!
sleep 3

tail -50 /tmp/blaze-runtime-sandbox-events.log
```

Seeing this is not enough:

```text
retry: 3000
```

`retry: 3000` only proves the SSE handshake. Final success requires
`event: session_update` frames after prompts.

## 5. Prompt 1

```bash
PROMPT1_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Qwen-Client-Id: $CLIENT_ID" \
  -d '{"prompt":[{"type":"text","text":"Remember this exact code word for the next message: ORBIT-17. Reply with OK only."}]}' \
  "$RUNTIME_URL/session/$SESSION_ID/prompt")

echo "$PROMPT1_RESPONSE" | tee /tmp/blaze-runtime-prompt1.json | jq .
```

The response will usually contain `promptId`. That only proves prompt admission.
It does not prove the model answered.

Wait for SSE:

```bash
sleep 45
tail -200 /tmp/blaze-runtime-sandbox-events.log
```

Expected:

- There is at least one `event: session_update` after prompt 1.
- The streamed text contains an acknowledgement such as `OK`.

Stop if the SSE log contains only `retry: 3000` and no `session_update`.

## 6. Prompt 2 In The Same Session

Do not create a new session. Reuse the same `SESSION_ID` and `CLIENT_ID`.

```bash
PROMPT2_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Qwen-Client-Id: $CLIENT_ID" \
  -d '{"prompt":[{"type":"text","text":"What exact code word did I ask you to remember? Answer with the code word only."}]}' \
  "$RUNTIME_URL/session/$SESSION_ID/prompt")

echo "$PROMPT2_RESPONSE" | tee /tmp/blaze-runtime-prompt2.json | jq .
```

Wait for SSE:

```bash
sleep 45
tail -300 /tmp/blaze-runtime-sandbox-events.log
```

Expected:

- There are `event: session_update` frames after prompt 2.
- The second answer, after assembling streamed text chunks, is exactly:

```text
ORBIT-17
```

Important: the raw SSE log may split text into chunks such as:

```text
OR
BIT
-1
7
```

Do not require the literal string `ORBIT-17` to appear as one raw SSE line.
Assemble the streamed text chunks for the second answer and then compare.

## 7. Cleanup

```bash
kill "$SSE_PID" 2>/dev/null || true
```

## 8. Success Criteria

Only say "sandbox MVP verification passed" when all items are true:

1. `/health` with only DP header returns runtime `401`.
2. `/health` with DP + runtime headers returns `200`.
3. `/workspace/preflight` returns sane initialized runtime state.
   - `auth.detail.source` is `dp-auth`.
   - It does not report `No auth method configured`.
4. `POST /session` returns non-empty `sessionId` and `clientId`.
5. SSE is opened before prompts with `Last-Event-ID: 0` as an HTTP header.
6. Prompt 1 returns `promptId`, and SSE later contains `session_update`.
7. Prompt 2 is sent to the same session and same client.
8. Prompt 2 returns `promptId`, and SSE later contains `session_update`.
9. Assembled text chunks from prompt 2 equal `ORBIT-17`.
10. The daemon was not restarted between prompts.
11. The ACP child/session was not recreated between prompts.

## 9. Failure Report Template

If any step fails, do not guess. Report:

```text
FAILED STEP:
EXPECTED:
ACTUAL:
SANDBOX_ID:
RUNTIME_URL:
IMAGE:
RUNTIME_VERSION:
HTTP STATUS:
SANITIZED RESPONSE BODY:
CREATE_SESSION RESPONSE:
PROMPT1 RESPONSE:
PROMPT2 RESPONSE:
LAST 300 SSE LOG LINES:
DOES SSE CONTAIN retry: 3000:
DOES SSE CONTAIN event: session_update:
WAS Last-Event-ID SENT AS HEADER:
WERE BOTH AUTH HEADERS SENT:
WAS THE SAME SESSION_ID USED FOR BOTH PROMPTS:
WAS THE SAME CLIENT_ID USED FOR BOTH PROMPTS:
DAEMON PID BEFORE/AFTER IF KNOWN:
ACP CHILD PID BEFORE/AFTER IF KNOWN:
```

Never print real tokens. Redact `Authorization`,
`X-Blaze-Runtime-Authorization`, `BLAZE_RUNTIME_TOKEN`, `BLAZE_DP_TOKEN`, and
any `ory_at_...` values.
