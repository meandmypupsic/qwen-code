# Blaze Runtime Sandbox — Нерешённая проблема авторизации

**Дата:** 2026-06-22  
**Версия:** @art/blaze-runtime@0.18.5  
**Статус:** 🔴 БЛОКИРОВАНО

---

## Краткое описание

Sandbox запускается, health check работает, но **аутентификация для Nestor API не работает**. Preflight показывает `auth.source: "none"` вместо ожидаемого `auth.source: "dp-auth"`.

---

## Что работает ✅

1. **npm пакет опубликован:** `@art/blaze-runtime@0.18.5`
2. **Docker образ опубликован:** `docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.5`
3. **Sandbox запускается:** переходит в статус `RUNNING`
4. **Health endpoint работает:**
   - Без runtime токена → `401 Unauthorized`
   - С обоими токенами → `200 OK {"status":"ok"}`
5. **Preflight возвращается:** runtime initialized, acpChannelLive: true

---

## Что НЕ работает ❌

### Проблема: auth.source = "none"

**Ожидаемое поведение (согласно документации v0.18.5):**

```json
{
  "kind": "auth",
  "locality": "acp",
  "status": "ok",
  "detail": {
    "source": "dp-auth",
    "hasToken": true
  }
}
```

**Фактическое поведение:**

```json
{
  "kind": "auth",
  "locality": "acp",
  "status": "warning",
  "errorKind": "auth_env_error",
  "error": "No auth method configured.",
  "hint": "Run `qwen` and complete the auth flow, or set a provider env var.",
  "detail": {
    "source": "none",
    "hasToken": false
  }
}
```

### Следствие: Create Session fails

```bash
curl -X POST "$RUNTIME_URL/session" ...
```

**Ответ:**

```json
{
  "error": "Authentication required: Authentication failed: Invalid JWT: expected 3 parts",
  "code": -32000,
  "data": {
    "authMethods": [{ "id": "openai", "name": "Use OpenAI API key" }]
  }
}
```

---

## Диагностика

### 1. entrypoint.sh должен делать exchange токена

Согласно коду entrypoint.sh (v0.18.5):

```bash
export DP_AUTH="${DP_AUTH:-true}"
...
prepare_nestor_credentials() {
  if [ -n "${BLAZE_DP_JWT:-}" ] || [ -n "${NESSY_CLI_DP_AUTH_TOKEN:-}" ]; then
    log "delegated Nestor JWT env detected, skipping DP token exchange"
    return
  fi

  if [ -z "${BLAZE_DP_TOKEN:-}" ]; then
    return
  fi

  log "exchanging DP token for Nestor JWT"
  curl --fail ... POST https://code-completion-nestor.tcsbank.ru/api/v2/token ...
  ...
  log "Nestor credentials cache prepared"
}
```

**Ожидалось в логах:**

```
[blaze-runtime-entrypoint] exchanging DP token for Nestor JWT
[blaze-runtime-entrypoint] Nestor credentials cache prepared
```

**Фактически:** Логи entrypoint недоступны через ML Core Sandbox API.

### 2. Проверка env переменных в sandbox

Попытки проверить env через ExecuteCommand возвращают `null` — sandbox не отвечает на команды или они не выполняются.

### 3. Проверка файлов credentials

```bash
ls -la /root/.blaze-runtime/dp_auth_creds.json
ls -la /root/.nessy/dp_auth_creds.json
```

Результат: `Not Found` — файлы не созданы, exchange не выполнился.

---

## Возможные причины

### 1. Egress блокирован 🔴

Sandbox не имеет доступа к `https://code-completion-nestor.tcsbank.ru/api/v2/token` из-за политик сети ML Core.

**Симптомы:**

- exchange токена не выполняется
- файлы credentials не создаются
- daemon не может прочитать JWT

**Проверка:**

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"identity": {...}, "command": ["curl", "-v", "https://code-completion-nestor.tcsbank.ru/api/v2/token"]}' \
  https://mlcore.t-tech.team/tools/sandbox-api/.../ExecuteCommand
```

### 2. BLAZE_DP_TOKEN не передаётся в sandbox

ML Core Sandbox API может не передавать environment variables правильно.

**Проверка:**

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"identity": {...}, "command": ["env"]}' \
  https://mlcore.t-tech.team/tools/sandbox-api/.../ExecuteCommand
```

### 3. entrypoint.sh не выполняется

`startupOptions.executeCommand` может не работать как ожидается.

**Проверка:**

- Sandbox логи через `/Get` или `/Logs` API
- Проверка процесса: `ps aux | grep blaze-runtime`

### 4. daemon не читает credentials из файла

`dpTokenManager.ts` может не читать `/root/.blaze-runtime/dp_auth_creds.json`.

**Проверка:**

- Логика в `packages/core/src/dp/dpTokenManager.ts:loadCachedCredentials()`
- Пути: `getDpCredentialsPath()` → `/root/.blaze-runtime/dp_auth_creds.json`

---

## Что было попробовано

| Попытка                         | Результат                               |
| ------------------------------- | --------------------------------------- |
| Health с обоими токенами        | ✅ 200 OK                               |
| Preflight                       | ✅ Возвращается, но auth.source: "none" |
| BLAZE_DP_TOKEN в environment    | ❌ auth всё равно "none"                |
| DP_TOKEN вместо BLAZE_DP_TOKEN  | ❌ auth всё равно "none"                |
| ExecuteCommand для проверки env | ❌ Возвращает null                      |
| Проверка логов sandbox          | ❌ Not Found                            |

---

## Следующие шаги

### 1. Получить доступ к логам entrypoint

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"identity": {"project": "art", "id": "..."}}' \
  https://mlcore.t-tech.team/tools/sandbox-api/mlcore.api.v1beta.sandbox.SandboxManagement/Logs
```

### 2. Проверить egress в Nestor API

Выполнить curl из sandbox к Nestor API для проверки доступности.

### 3. Проверить env переменные

Выполнить `env` внутри sandbox и проверить наличие `BLAZE_DP_TOKEN` / `DP_TOKEN` / `DP_AUTH`.

### 4. Альтернатива: использовать готовый JWT

Если exchange невозможен, попробовать передать готовый JWT через `BLAZE_DP_JWT` или `NESSY_CLI_DP_AUTH_TOKEN`.

```bash
dp auth token  # Получить JWT
# Передать как BLAZE_DP_JWT в sandbox environment
```

---

## Блокирующий фактор

**Для завершения верификации ORBIT-17 требуется:**

1. Либо починить exchange DP токена на JWT внутри sandbox
2. Либо передать готовый JWT через environment

Без работающей аутентификации невозможно:

- Создать сессию
- Открыть SSE stream
- Отправить prompt
- Получить session_update
- Доказать end-to-end работу

---

## Ссылки

- [Blaze Runtime Sandbox Final Verification](./blaze-runtime-sandbox-final-verification.md)
- [Blaze Runtime Sandbox Auth Solution](./blaze-runtime-sandbox-auth-solution.md)
- [Blaze Runtime Sandbox Docker Build](./blaze-runtime-sandbox-docker-build.md)
- [deploy/sandbox/blaze-runtime/entrypoint.sh](../../deploy/sandbox/blaze-runtime/entrypoint.sh)
- [packages/core/src/dp/dpTokenManager.ts](../../packages/core/src/dp/dpTokenManager.ts)
