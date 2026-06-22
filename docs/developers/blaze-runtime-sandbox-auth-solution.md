# Blaze Runtime Sandbox — Решение проблемы авторизации

Этот документ описывает окончательное решение проблемы авторизации при запуске
Blaze Runtime Sandbox через ML Core Sandbox API.

**Дата решения:** 2026-06-22  
**Версия:** @art/blaze-runtime@0.18.6

---

## Краткое резюме

Для успешного запуска Blaze Runtime Sandbox через ML Core Proxy требуется **двухуровневая авторизация**:

1. **ML Core Proxy** проверяет DP токен в заголовке `Authorization`
2. **blaze-runtime daemon** проверяет runtime токен в заголовке `X-Blaze-Runtime-Authorization`

**Критические изменения в v0.18.4:**

- Добавлена поддержка заголовка `X-Blaze-Runtime-Authorization`
- Обновлён Dockerfile для установки v0.18.4
- Обновлена документация с примерами запуска

**Критические изменения в v0.18.5:**

- `/entrypoint.sh` обменивает `BLAZE_DP_TOKEN`/`DP_TOKEN` на Nestor JWT через
  `POST https://code-completion-nestor.tcsbank.ru/api/v2/token`
- entrypoint пишет Nestor JWT cache в `/root/.blaze-runtime/dp_auth_creds.json`
  и legacy mirror `/root/.nessy/dp_auth_creds.json`
- entrypoint выставляет `DP_AUTH=true`
- spawned ACP child получает DP/Nestor env явно и стартует как
  `blaze-runtime --acp --auth-type=dp-auth`
- DP runtime больше не пытается декодировать сырой `ory_at_...` как JWT, если
  этот токен попал в generic `settings.security.auth.apiKey`

**Критическое изменение в v0.18.6:**

- `npm run prepare:package` теперь падает, если `dist/` содержит старый bundle
  без DP/Nestor auth fixes. Это защищает от ситуации, когда
  `dist/package.json` уже показывает новую версию, но `dist/blaze-runtime.js`
  и `dist/chunks/*.js` остались от старой сборки.

---

## Проблема

При запуске sandbox с образом v0.18.3 возникали следующие проблемы:

### Симптом 1: 502 Bad Gateway

```bash
curl -H "Authorization: Bearer $DP_TOKEN" \
  https://mlcore.t-tech.team/.../ports/4170/health
# HTTP 502 Bad Gateway
```

**Причина:** blaze-runtime не запускался автоматически. В ML Core sandbox Docker
`ENTRYPOINT` не выполняется — нужно явно указать `startupOptions.executeCommand`.

### Симптом 2: 401 Unauthorized

```bash
curl -H "Authorization: Bearer $DP_TOKEN" \
  https://mlcore.t-tech.team/.../ports/4170/health
# HTTP 401 {"error": "Unauthorized"}
```

**Причина:** blaze-runtime не принимал DP токен как runtime токен авторизации.
Это разные токены для разных слоёв безопасности.

### Симптом 3: Путаница с токенами

Три разных токена выполняли разные функции, но мы пытались использовать один:

| Токен                       | Назначение                         | Где проверяется       |
| --------------------------- | ---------------------------------- | --------------------- |
| **DP Token** (`ory_at_...`) | Доступ к ML Core Proxy             | ML Core / DevPlatform |
| **BLAZE_RUNTIME_TOKEN**     | Доступ к blaze-runtime HTTP daemon | blaze-runtime         |
| **BLAZE_DP_TOKEN**          | Обмен на JWT для Nestor API        | Nestor (через DP)     |

### Симптом 4: Preflight warning и `Invalid JWT: expected 3 parts`

В образе `0.18.4` health и proxy headers уже работали, но session creation
падал:

```json
{
  "error": "Authentication required: Authentication failed: Invalid JWT: expected 3 parts",
  "data": {
    "authMethods": [{ "id": "openai", "name": "Use OpenAI API key" }]
  }
}
```

Preflight при этом мог показывать:

```json
{
  "kind": "auth",
  "status": "warning",
  "error": "No auth method configured.",
  "detail": { "source": "none", "hasToken": false }
}
```

**Причины:**

1. ACP child не был жёстко запущен в `dp-auth`.
2. В списке ACP auth methods был только `openai`, поэтому отчёт сбивал агента.
3. DP runtime мог принять сырой `ory_at_...` из generic apiKey за JWT и пытался
   декодировать его как JWT.

**Исправление:** использовать `@art/blaze-runtime@0.18.6` или новее и убедиться,
что `npm run prepare:package` прошёл без stale bundle ошибки.

---

## Решение

### 1. Двухуровневая авторизация

```bash
curl \
  -H "Authorization: Bearer <DP_TOKEN>" \
  -H "X-Blaze-Runtime-Authorization: Bearer <RUNTIME_TOKEN>" \
  https://mlcore.t-tech.team/.../ports/4170/health
```

**Как работает:**

1. **ML Core Proxy** проверяет `Authorization: Bearer <DP_TOKEN>`
   - Если токен невалиден → 401 от proxy
   - Если валиден → пропускает запрос в sandbox

2. **blaze-runtime** проверяет `X-Blaze-Runtime-Authorization: Bearer <RUNTIME_TOKEN>`
   - Если токен невалиден → 401 от daemon
   - Если валиден → 200 OK

**Важно:** Не используйте DP токен как `BLAZE_RUNTIME_TOKEN`. Это разные security domains.

### 2. Явный запуск entrypoint через startupOptions

ML Core sandbox не запускает Docker `ENTRYPOINT` автоматически. Нужно указать:

```json
{
  "startupOptions": {
    "executeCommand": ["/entrypoint.sh"],
    "terminateAfterCommand": false
  }
}
```

**Почему `terminateAfterCommand: false`:**

- `/entrypoint.sh` запускает `blaze-runtime serve` как долгоживущий процесс
- `false` указывает sandbox не завершать сессию после выполнения команды

### 3. Правильная конфигурация sandbox

```json
{
  "project": "art",
  "spec": {
    "flavor": "2cpu-4ram",
    "image": "docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.6",
    "containerPorts": [
      {
        "name": "http",
        "port": 4170
      }
    ],
    "environment": {
      "BLAZE_RUNTIME_TOKEN": "<unique-token-generated-by-bff>",
      "BLAZE_DP_TOKEN": "<dp-token-for-nestor-exchange>",
      "BLAZE_RUNTIME_HOST": "0.0.0.0",
      "BLAZE_RUNTIME_PORT": "4170",
      "BLAZE_RUNTIME_WORKSPACE": "/workspace"
    }
  },
  "startupOptions": {
    "executeCommand": ["/entrypoint.sh"],
    "terminateAfterCommand": false
  }
}
```

**Критичные поля:**

| Поле                                   | Значение             | Почему важно                   |
| -------------------------------------- | -------------------- | ------------------------------ |
| `containerPorts[0].name`               | `"http"`             | Имя < 16 символов, `[a-z0-9_]` |
| `containerPorts[0].port`               | `4170`               | Порт blaze-runtime             |
| `environment.BLAZE_RUNTIME_TOKEN`      | Уникальный токен     | Не DP токен!                   |
| `environment.BLAZE_DP_TOKEN`           | DP токен             | Для обмена на Nestor JWT       |
| `startupOptions.executeCommand`        | `["/entrypoint.sh"]` | Явный запуск daemon            |
| `startupOptions.terminateAfterCommand` | `false`              | Долгоживущий процесс           |

---

## Пошаговый процесс запуска

### Шаг 1: Получить DP токен

```bash
DP_TOKEN=$(python3 ~/.nessy/skills/dp-auth-token.py)
```

### Шаг 2: Сгенерировать runtime токен

```bash
RUNTIME_TOKEN="blaze-sandbox-token-$(date +%s)"
```

**Примечание:** В продакшене Blaze/BFF должен генерировать уникальный токен
на каждую сессию и сохранять его для последующей проверки.

### Шаг 3: Создать sandbox

```bash
TOKEN="<ory-токен-для-ml-core-api>" && \
curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "project": "art",
    "spec": {
      "flavor": "2cpu-4ram",
      "image": "docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.6",
      "containerPorts": [{"port": 4170, "name": "http"}],
      "environment": {
        "BLAZE_RUNTIME_TOKEN": "'"$RUNTIME_TOKEN"'",
        "BLAZE_DP_TOKEN": "'"$DP_TOKEN"'",
        "BLAZE_RUNTIME_HOST": "0.0.0.0",
        "BLAZE_RUNTIME_PORT": "4170",
        "BLAZE_RUNTIME_WORKSPACE": "/workspace"
      }
    },
    "startupOptions": {
      "executeCommand": ["/entrypoint.sh"],
      "terminateAfterCommand": false
    }
  }' \
  https://mlcore.t-tech.team/tools/sandbox-api/mlcore.api.v1beta.sandbox.SandboxManagement/Start
```

### Шаг 4: Дождаться RUNNING

```bash
curl -s --no-buffer -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"identity": {"project": "art", "id": "<SANDBOX_ID>"}}' \
  https://mlcore.t-tech.team/tools/sandbox-api/.../WatchStatus
```

Ждать `"state":"RUNNING"` и появления proxy URL.

### Шаг 5: Проверить health

```bash
RUNTIME_URL="https://mlcore.t-tech.team/tools/jobs-proxy/projects/art/jobs/.../ports/4170/"

# Без runtime токена → 401
curl -sS -H "Authorization: Bearer $DP_TOKEN" "$RUNTIME_URL/health"
# HTTP 401 {"error":"Unauthorized"}

# С обоими токенами → 200
curl -sS \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  "$RUNTIME_URL/health"
# HTTP 200 {"status":"ok"}
```

### Шаг 6: Preflight и сессия

```bash
# Preflight
curl -sS \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  "$RUNTIME_URL/workspace/preflight" | jq .

# Create session
CREATE_RESPONSE=$(curl -sS -X POST \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "$RUNTIME_URL/session")

SESSION_ID=$(echo "$CREATE_RESPONSE" | jq -r '.sessionId')
CLIENT_ID=$(echo "$CREATE_RESPONSE" | jq -r '.clientId')
```

---

## Архитектура авторизации

```
┌─────────────┐
│   Client    │
└──────┬──────┘
       │
       │ 1. Authorization: Bearer <DP_TOKEN>
       │    X-Blaze-Runtime-Authorization: Bearer <RUNTIME_TOKEN>
       ▼
┌─────────────────────────────────────────────────────────┐
│              ML Core Proxy                              │
│  - Проверяет DP токен                                   │
│  - Пропускает в sandbox                                 │
│  - Передаёт оба заголовка в sandbox                     │
└─────────────────────────────────────────────────────────┘
       │
       │ 2. Заголовок X-Blaze-Runtime-Authorization
       ▼
┌─────────────────────────────────────────────────────────┐
│           blaze-runtime daemon (порт 4170)              │
│  - Проверяет X-Blaze-Runtime-Authorization              │
│  - Стартует один ACP child process                      │
│  - Передаёт ему DP/Nestor env                           │
│  - Обрабатывает запросы                                 │
└─────────────────────────────────────────────────────────┘
       │
       │ 3. blaze-runtime --acp --auth-type=dp-auth
       ▼
┌─────────────────────────────────────────────────────────┐
│              ACP child / agent runtime                  │
│  - Читает /root/.blaze-runtime/dp_auth_creds.json       │
│  - Ходит в Nestor OpenAI-compatible API                 │
│  - Выполняет tools и ведёт session context              │
└─────────────────────────────────────────────────────────┘
```

---

## Изменения в v0.18.4

### packages/cli/src/serve/auth.ts

Добавлена поддержка заголовка `X-Blaze-Runtime-Authorization`:

```typescript
const runtimeAuthorizationHeader = 'x-blaze-runtime-authorization';

export function bearerAuth(token: string | undefined): RequestHandler {
  if (!token) {
    return (_req, _res, next) => next();
  }

  const expected = createHash('sha256').update(token, 'utf8').digest();

  return (req, res, next) => {
    // Сначала проверяем X-Blaze-Runtime-Authorization
    const header =
      firstHeaderValue(req.headers[runtimeAuthorizationHeader]) ??
      firstHeaderValue(req.headers.authorization);

    if (!header) {
      res.status(401).json({ error: 'Unauthorized' });
      return;
    }

    // ... проверка токена
  };
}
```

### deploy/sandbox/blaze-runtime/Dockerfile

Обновлена версия npm пакета:

```dockerfile
ARG BLAZE_RUNTIME_VERSION=0.18.4
```

### deploy/sandbox/blaze-runtime/sandbox-start.example.json

Добавлен `startupOptions`:

```json
{
  "startupOptions": {
    "executeCommand": ["/entrypoint.sh"],
    "terminateAfterCommand": false
  }
}
```

### deploy/sandbox/blaze-runtime/sandbox.env.example

Добавлено пояснение для `X-Blaze-Runtime-Authorization`:

```bash
# Required. Generated by Nessy Blaze/BFF per user/project runtime session.
# This is NOT the DP/Ory token. Through the ML Core proxy it must be sent as:
# X-Blaze-Runtime-Authorization: Bearer <runtime-bearer-token>
BLAZE_RUNTIME_TOKEN=<runtime-bearer-token>
```

## Изменения в v0.18.5

### deploy/sandbox/blaze-runtime/entrypoint.sh

Entrypoint теперь делает то, что раньше делал старый `nessy-cli`
`deploy/async/entrypoint.sh`:

```text
1. Берёт BLAZE_DP_TOKEN или DP_TOKEN.
2. Делает POST https://code-completion-nestor.tcsbank.ru/api/v2/token.
3. Достаёт поле .jwt.
4. Пишет:
   /root/.blaze-runtime/dp_auth_creds.json
   /root/.nessy/dp_auth_creds.json
5. Экспортирует DP_AUTH=true.
6. Запускает blaze-runtime serve.
```

Если передан `BLAZE_DP_JWT` или `NESSY_CLI_DP_AUTH_TOKEN`, entrypoint не делает
token exchange: это уже delegated JWT flow.

### packages/acp-bridge/src/spawnChannel.ts

Если в окружении есть `DP_AUTH=true`, spawned ACP child стартует так:

```text
blaze-runtime --acp --auth-type=dp-auth
```

Это важно, потому что `--auth-type` имеет приоритет над сохранённым
`settings.security.auth.selectedType`.

### packages/cli/src/serve/runQwenServe.ts

Daemon явно прокидывает в ACP child:

```text
BLAZE_DP_TOKEN
DP_TOKEN
BLAZE_DP_JWT
NESSY_CLI_DP_AUTH_TOKEN
BLAZE_DP_CREDENTIALS_PATH
BLAZE_RUNTIME_HOME
BLAZE_NESTOR_SERVER_URL
BLAZE_NESTOR_BASE_URL
NESTOR_BASE_URL
BLAZE_NESTOR_MODEL
NESTOR_MODEL
DP_AUTH
```

### packages/core/src/dp/dpTokenManager.ts

DP runtime больше не считает любую `apiKey` строку JWT. Если туда случайно
попал сырой `ory_at_...`, runtime обменивает его как DP access token или берёт
настоящий DP token из env.

## Изменения в v0.18.6

### scripts/prepare-package.js

Перед публикацией npm artifact проверяет, что bundle действительно содержит
новую DP/Nestor auth логику:

```text
Use Nestor / DP auth
BLAZE_RUNTIME_AUTH_TYPE
DP auth received a non-JWT apiKey value
```

Если этих строк нет в `dist/`, значит был выполнен `npm run prepare:package`
поверх старого bundle. Такой пакет будет выглядеть как новая версия, но в
sandbox поведёт себя как старый runtime: preflight покажет
`auth.source: "none"`, а `authMethods` будет содержать только `openai`.

Правильный recovery:

```bash
npm ci
npm run build --workspace=packages/core
npm run build --workspace=packages/cli
npm run bundle
npm run prepare:package
cd dist
npm publish --registry="https://artifactory.tcsbank.ru/artifactory/api/npm/npm-hosted/"
```

### Ожидаемый preflight после v0.18.6

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

---

## Чеклист для запуска

- [ ] Получен свежий DP токен (`dp-auth-token.py`)
- [ ] Сгенерирован уникальный `BLAZE_RUNTIME_TOKEN` (не DP токен!)
- [ ] Указан `containerPorts` с именем `"http"` (не `"blaze-runtime"`)
- [ ] Передан `startupOptions.executeCommand: ["/entrypoint.sh"]`
- [ ] Указан `terminateAfterCommand: false`
- [ ] Переданы оба env: `BLAZE_RUNTIME_TOKEN` и `BLAZE_DP_TOKEN`
- [ ] Sandbox перешёл в статус `RUNNING`
- [ ] Health check возвращает 200 с обоими заголовками
- [ ] Preflight возвращает `initialized: true`
- [ ] Preflight auth cell показывает `detail.source: "dp-auth"`
- [ ] Preflight auth cell не показывает `No auth method configured`
- [ ] Выполнен полный финальный runbook:
      `docs/developers/blaze-runtime-sandbox-final-verification.md`
- [ ] SSE после prompt содержит реальные `session_update`, а второй prompt в
      той же session после сборки streamed chunks даёт `ORBIT-17`

---

## Частые ошибки

| Ошибка                      | Причина                  | Решение                                        |
| --------------------------- | ------------------------ | ---------------------------------------------- |
| `502 Bad Gateway`           | blaze-runtime не запущен | Добавить `startupOptions.executeCommand`       |
| `401 Unauthorized` (proxy)  | Невалидный DP токен      | Обновить токен через `dp-auth-token.py`        |
| `401 Unauthorized` (daemon) | Невалидный runtime токен | Проверить `BLAZE_RUNTIME_TOKEN` в env          |
| `null` proxy URL            | Нет `containerPorts`     | Добавить `[{port: 4170, name: "http"}]`        |
| `Invalid port name`         | Имя порта > 16 символов  | Использовать `"http"` вместо `"blaze-runtime"` |
| `No auth method configured` | Старый образ, stale bundle или ACP child не в `dp-auth` | Использовать `0.18.6+`, проверить bundle guard и `DP_AUTH=true` |
| `Invalid JWT: expected 3 parts` | Сырой `ory_at_...` был принят за JWT или запущен старый bundle | Использовать `0.18.6+`, передавать raw DP token в `BLAZE_DP_TOKEN` |

---

## Ссылки

- [Blaze Runtime Sandbox MVP Handoff](./blaze-runtime-sandbox-mvp-handoff.md)
- [Blaze Runtime Sandbox Final Verification](./blaze-runtime-sandbox-final-verification.md)
- [Blaze Runtime Local Smoke Test](./blaze-runtime-local-smoke-test.md)
- [Blaze Runtime Sandbox Debug](./blaze-runtime-sandbox-debug.md)
- [Blaze Runtime Docker Build](./blaze-runtime-sandbox-docker-build.md)
- [deploy/sandbox/blaze-runtime/README.md](../../deploy/sandbox/blaze-runtime/README.md)
- [packages/cli/src/serve/auth.ts](../../packages/cli/src/serve/auth.ts)
