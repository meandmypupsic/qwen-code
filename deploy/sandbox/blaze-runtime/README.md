# Blaze Runtime Sandbox Image Flow

This is the concrete replacement for the old `nessy-cli` async sandbox flow.

Old flow:

```text
build/publish nessy-cli npm artifact
  -> install that npm artifact in async.Dockerfile
  -> build/publish Docker image
  -> pass Docker image to sandbox start
```

New flow:

```text
build/publish qwen-code npm artifact with blaze-runtime bin
  -> install that npm artifact in deploy/sandbox/blaze-runtime/Dockerfile
  -> build/publish Docker image
  -> pass Docker image + env + port 4170 to sandbox start
  -> call blaze-runtime serve through the sandbox proxy URL
```

Do not run `sandbox-agent ExecuteCommand` for every prompt. The image entrypoint
starts one long-lived `blaze-runtime serve` process. That daemon then keeps a
long-lived ACP child process for the user's session.

## 1. Build the npm artifact

From the repository root:

```bash
npm ci
npm run build --workspace=packages/core
npm run build --workspace=packages/cli
npm run bundle
npm run prepare:package
```

The distributable npm package is prepared in `dist/`.

Important: `prepare:package` must produce a package with both bins:

```text
qwen
blaze-runtime
```

Verify:

```bash
node -e "const p=require('./dist/package.json'); console.log(p.name, p.version, p.bin)"
test -f dist/blaze-runtime.js
test -f dist/blaze-runtime-entry.js
```

## 2. Publish the npm artifact

Set your internal npm registry:

```bash
export NPM_REGISTRY="https://artifactory.tcsbank.ru/artifactory/api/npm/npm-all/"
```

If the current package version already exists in Artifactory, set a new version
before running `prepare:package`. Do not publish over an existing immutable npm
version.

Pack and publish:

```bash
cd dist
npm pack
npm publish --registry "$NPM_REGISTRY"
```

Record package name and version:

```bash
export BLAZE_RUNTIME_PACKAGE="$(node -p "require('./package.json').name")"
export BLAZE_RUNTIME_VERSION="$(node -p "require('./package.json').version")"
echo "$BLAZE_RUNTIME_PACKAGE@$BLAZE_RUNTIME_VERSION"
```

Expected MVP package name today:

```text
@qwen-code/qwen-code
```

The public product boundary is the `blaze-runtime` binary inside that package.
The package can still contain qwen names during this MVP stage.

## 3. Build the sandbox Docker image

Return to repository root:

```bash
cd ..
```

Build:

```bash
export IMAGE="<docker-registry>/<namespace>/blaze-runtime-sandbox:${BLAZE_RUNTIME_VERSION}"

docker build --platform linux/amd64 \
  -f deploy/sandbox/blaze-runtime/Dockerfile \
  --build-arg NPM_REGISTRY="$NPM_REGISTRY" \
  --build-arg BLAZE_RUNTIME_PACKAGE="$BLAZE_RUNTIME_PACKAGE" \
  --build-arg BLAZE_RUNTIME_VERSION="$BLAZE_RUNTIME_VERSION" \
  -t "$IMAGE" \
  .
```

Smoke check the image locally if Docker can reach Nestor and the internal
network:

```bash
docker run --rm \
  -e BLAZE_RUNTIME_TOKEN="local-dev-token" \
  -e BLAZE_DP_TOKEN="<dp-token>" \
  -p 4170:4170 \
  "$IMAGE"
```

In another terminal:

```bash
curl -i http://127.0.0.1:4170/health
curl -i -H "Authorization: Bearer local-dev-token" http://127.0.0.1:4170/health
```

Expected:

```text
without token -> HTTP 401
with token    -> HTTP 200 {"status":"ok"}
```

## 4. Publish the Docker image

```bash
docker push "$IMAGE"
```

Use this pushed image in the sandbox start request.

## 5. Sandbox start configuration

Use `sandbox-start.example.json` as a field-level template. Adapt field names to
the real ML Core/Sandbox API if needed.

Required image:

```text
<docker-registry>/<namespace>/blaze-runtime-sandbox:<tag>
```

Required exposed/proxied port:

```text
4170 HTTP
```

Required env:

```text
BLAZE_RUNTIME_TOKEN=<runtime-bearer-token>
BLAZE_DP_TOKEN=<dp-token>
BLAZE_RUNTIME_HOST=0.0.0.0
BLAZE_RUNTIME_PORT=4170
BLAZE_RUNTIME_WORKSPACE=/workspace
```

`BLAZE_RUNTIME_TOKEN` is the bearer token used by Nessy Blaze/BFF when calling
the proxied runtime URL.

`BLAZE_DP_TOKEN` is exchanged by Blaze Runtime against Nestor. The entrypoint
also accepts legacy `DP_TOKEN` and maps it to `BLAZE_DP_TOKEN`.

## 6. Verify through the sandbox proxy URL

After sandbox start, the platform should return a proxied URL for port `4170`.
Call it `<RUNTIME_URL>`.

Health:

```bash
curl -i "$RUNTIME_URL/health"
curl -i -H "Authorization: Bearer <runtime-bearer-token>" "$RUNTIME_URL/health"
```

Preflight:

```bash
curl -sS \
  -H "Authorization: Bearer <runtime-bearer-token>" \
  "$RUNTIME_URL/workspace/preflight" | jq .
```

Create session:

```bash
CREATE_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Bearer <runtime-bearer-token>" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "$RUNTIME_URL/session")

echo "$CREATE_RESPONSE" | jq .
export SESSION_ID=$(echo "$CREATE_RESPONSE" | jq -r '.sessionId')
export CLIENT_ID=$(echo "$CREATE_RESPONSE" | jq -r '.clientId')
```

Open SSE before prompts:

```bash
curl -N -sS \
  -H "Authorization: Bearer <runtime-bearer-token>" \
  -H "X-Qwen-Client-Id: $CLIENT_ID" \
  -H "Last-Event-ID: 0" \
  "$RUNTIME_URL/session/$SESSION_ID/events?maxQueued=1024" \
  > /tmp/blaze-runtime-sandbox-events.log &

SSE_PID=$!
```

Prompt 1:

```bash
curl -sS -X POST \
  -H "Authorization: Bearer <runtime-bearer-token>" \
  -H "Content-Type: application/json" \
  -H "X-Qwen-Client-Id: $CLIENT_ID" \
  -d '{"prompt":[{"type":"text","text":"Remember this exact code word for the next message: ORBIT-17. Reply with OK only."}]}' \
  "$RUNTIME_URL/session/$SESSION_ID/prompt" | jq .
```

Wait for model output:

```bash
sleep 30
tail -150 /tmp/blaze-runtime-sandbox-events.log
```

Prompt 2:

```bash
curl -sS -X POST \
  -H "Authorization: Bearer <runtime-bearer-token>" \
  -H "Content-Type: application/json" \
  -H "X-Qwen-Client-Id: $CLIENT_ID" \
  -d '{"prompt":[{"type":"text","text":"What exact code word did I ask you to remember? Answer with the code word only."}]}' \
  "$RUNTIME_URL/session/$SESSION_ID/prompt" | jq .
```

Wait and inspect:

```bash
sleep 30
tail -200 /tmp/blaze-runtime-sandbox-events.log
kill "$SSE_PID" 2>/dev/null || true
```

Success means:

```text
SSE contains session_update frames
the second answer's streamed text chunks assemble to ORBIT-17
the daemon process was not recreated
the ACP child process was not recreated
```

Seeing only `retry: 3000` is not enough. That only proves the SSE handshake. If
there are no `session_update` frames after prompts, investigate sandbox proxy
buffering, Nestor auth, and daemon logs.

## 7. What Qwen must not do

Do not:

- rebuild the old `nessy-cli` image;
- call `nessy serve`;
- run one `ExecuteCommand` per prompt;
- manually create `~/.nessy/dp_auth_creds.json` in entrypoint;
- print real tokens;
- claim success from `promptId` alone;
- claim success from `retry: 3000` alone.
