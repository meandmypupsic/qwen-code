# Blaze Runtime Sandbox — Отчёт о верификации v0.18.4

**Дата:** 2026-06-22  
**Версия:** @art/blaze-runtime@0.18.4  
**Sandbox ID:** 019eef87-bc52-7d85-a328-4806a067c8d7  
**Статус:** Частичная верификация (health + preflight ✅, session ❌)

---

## Резюме

Sandbox запущен с правильными параметрами авторизации. Двухуровневая авторизация работает:

- ML Core Proxy принимает DP токен
- blaze-runtime принимает `X-Blaze-Runtime-Authorization` токен

**Блокирующий фактор:** Создание сессии требует JWT для Nestor API. `BLAZE_DP_TOKEN` передаётся, но механизм обмена на JWT требует дополнительной интеграции с Nestor.

## Диагностика после отчёта

Этот отчёт был получен на образе `@art/blaze-runtime@0.18.4`.

Важно: `0.18.4` уже починил двухуровневую HTTP-авторизацию через ML Core
Proxy, но ещё не чинил внутреннюю Nestor/DP авторизацию ACP child process.
Поэтому health и preflight доходили до runtime, но `POST /session` падал.

Найдены три причины:

1. ACP child не запускался явно в `dp-auth`.
   - Preflight показывал `detail.source: "none"`.
   - Это означало, что агентский процесс не выбрал Nestor/DP provider.

2. ACP `authMethods` рекламировал только `openai`.
   - Поэтому ошибка session creation возвращала `authMethods: [{ "id": "openai" }]`.
   - Это сбивает follow-up агента: он начинает чинить OpenAI, хотя нужен Nestor/DP.

3. DP runtime мог принять сырой DP/Ory токен вида `ory_at_...` за JWT.
   - JWT должен иметь 3 части через точки.
   - `ory_at_...` не JWT, поэтому появлялась ошибка `Invalid JWT: expected 3 parts`.

Исправление внесено в `0.18.5`:

- `/entrypoint.sh` делает `POST https://code-completion-nestor.tcsbank.ru/api/v2/token`
  с `Authorization: Bearer <BLAZE_DP_TOKEN>`;
- entrypoint пишет Nestor JWT cache в `/root/.blaze-runtime/dp_auth_creds.json`
  и `/root/.nessy/dp_auth_creds.json`;
- entrypoint выставляет `DP_AUTH=true`;
- spawned ACP child стартует как `blaze-runtime --acp --auth-type=dp-auth`;
- DP runtime больше не декодирует сырой `ory_at_...` как JWT;
- ACP `authMethods` теперь включает `dp-auth`.

Следующий запуск нужно делать на:

```text
npm:    @art/blaze-runtime@0.18.6
docker: docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.6
```

Ожидаемый preflight после фикса:

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

## Выполненные шаги

### Шаг 1: Health Check ✅

**Тест 1: Только DP токен**

```bash
curl -H "Authorization: Bearer $DP_TOKEN" "$RUNTIME_URL/health"
```

**Результат:**

```json
{ "error": "Unauthorized" }
```

✅ Ожидаемо: blaze-runtime отклоняет запрос без runtime токена.

**Тест 2: DP + Runtime токены**

```bash
curl -H "Authorization: Bearer $DP_TOKEN" \
     -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
     "$RUNTIME_URL/health"
```

**Результат:**

```json
{ "status": "ok" }
```

✅ Ожидаемо: оба токена приняты.

---

### Шаг 2: Preflight ✅

```bash
curl "$RUNTIME_URL/workspace/preflight" \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN"
```

**Результат:**

```json
{
  "v": 1,
  "workspaceCwd": "/workspace",
  "initialized": true,
  "acpChannelLive": true,
  "cells": [
    {
      "kind": "node_version",
      "status": "ok",
      "detail": { "version": "22.22.3", "required": ">=22" }
    },
    {
      "kind": "cli_entry",
      "status": "ok",
      "detail": {
        "path": "/usr/lib/node_modules/@art/blaze-runtime/blaze-runtime.js"
      }
    },
    {
      "kind": "auth",
      "locality": "acp",
      "status": "warning",
      "errorKind": "auth_env_error",
      "error": "No auth method configured.",
      "hint": "Run `qwen` and complete the auth flow, or set a provider env var."
    }
  ]
}
```

**Критичные поля:**

- ✅ `initialized: true`
- ✅ `acpChannelLive: true`
- ⚠️ `auth.status: "warning"` — нет провайдера аутентификации

---

### Шаг 3: Create Session ❌

```bash
curl -X POST "$RUNTIME_URL/session" \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Результат:**

```json
{
  "error": "Authentication required: Authentication failed: Invalid JWT: expected 3 parts",
  "code": -32000,
  "data": {
    "authMethods": [
      {
        "id": "openai",
        "name": "Use OpenAI API key"
      }
    ]
  }
}
```

**Причина в `0.18.4`:** `BLAZE_DP_TOKEN` не обменивается на JWT на старте,
а ACP child не выбирает `dp-auth` автоматически.

В исходниках это исправлено. Для повторной проверки не передавай
`OPENAI_API_KEY` и не пытайся чинить OpenAI provider. Собери и запусти новый
образ `0.18.6+`, потому что `0.18.5` мог быть опубликован из stale `dist/`
bundle.

Исторически возможные обходы для `0.18.4`:

1. Либо готовый JWT (`BLAZE_DP_JWT`)
2. Либо механизм обмена через Nestor API

---

## Диагностика auth

Из preflight:

```json
{
  "kind": "auth",
  "locality": "acp",
  "status": "warning",
  "errorKind": "auth_env_error",
  "error": "No auth method configured.",
  "detail": {
    "source": "none",
    "hasToken": false
  }
}
```

**Интерпретация:**

- `source: "none"` — нет настроенного провайдера аутентификации
- `hasToken: false` — JWT токен отсутствует

---

## Конфигурация sandbox

```json
{
  "image": "docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.4",
  "containerPorts": [{ "port": 4170, "name": "http" }],
  "environment": {
    "BLAZE_RUNTIME_TOKEN": "blaze-orbit-test-1782135110",
    "BLAZE_DP_TOKEN": "ory_at_***",
    "BLAZE_RUNTIME_HOST": "0.0.0.0",
    "BLAZE_RUNTIME_PORT": "4170",
    "BLAZE_RUNTIME_WORKSPACE": "/workspace"
  },
  "startupOptions": {
    "executeCommand": ["/entrypoint.sh"],
    "terminateAfterCommand": false
  }
}
```

---

## Что работает

| Компонент                     | Статус | Примечание                   |
| ----------------------------- | ------ | ---------------------------- |
| Docker image pull             | ✅     | v0.18.4 загружается          |
| Sandbox start                 | ✅     | Переходит в RUNNING          |
| containerPorts                | ✅     | Proxy URL создаётся          |
| startupOptions.executeCommand | ✅     | `/entrypoint.sh` выполняется |
| Health endpoint               | ✅     | 200 OK с обоими токенами     |
| Preflight                     | ✅     | Runtime initialized          |
| ACP channel                   | ✅     | Живой канал                  |
| **Session creation**          | ❌     | Требует JWT                  |

---

## Блокирующий фактор

### Проблема

`BLAZE_DP_TOKEN` передаётся в sandbox, но не обменивается на JWT для Nestor API.

### Возможные решения

**Вариант 1: Передать готовый JWT**

```bash
export BLAZE_DP_JWT="<jwt-token>"
```

**Вариант 2: Настроить обмен через Nestor**

- Требуется доступ к `https://code-completion-nestor.tcsbank.ru`
- Требуется механизм обмена DP токена на JWT

**Вариант 3: Использовать другой auth provider**

```bash
export OPENAI_API_KEY="sk-..."
export BLAZE_NESTOR_MODEL="gpt-4"
```

---

## Следующие шаги

1. Собрать и опубликовать npm `@art/blaze-runtime@0.18.6`.
2. Собрать и опубликовать Docker image
   `docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.6`.
3. Запустить sandbox с теми же двумя токенами:
   - `Authorization: Bearer <DP_TOKEN>` для ML Core Proxy;
   - `X-Blaze-Runtime-Authorization: Bearer <RUNTIME_TOKEN>` для runtime daemon.
4. В env sandbox передать:
   - `BLAZE_RUNTIME_TOKEN`;
   - `BLAZE_DP_TOKEN` или legacy `DP_TOKEN`.
5. Проверить, что в логах entrypoint есть:
   ```text
   exchanging DP token for Nestor JWT
   Nestor credentials cache prepared
   ```
6. Повторить шаги 3-7 runbook:
   - Create session
   - Open SSE
   - Prompt 1 (ORBIT-17)
   - Prompt 2 (recall)
   - Verify session_update

---

## Приложения

### A. Переменные окружения (redacted)

```bash
export RUNTIME_URL="https://mlcore.t-tech.team/tools/jobs-proxy/projects/art/jobs/sandbox-m0tx3a/ports/4170/"
export DP_TOKEN="ory_at_***"
export RUNTIME_TOKEN="blaze-orbit-test-1782135110"
```

### B. Preflight полный (redacted)

См. `/tmp/blaze-runtime-preflight.json`

### C. Create session response

```json
{
  "error": "Authentication required: Authentication failed: Invalid JWT: expected 3 parts",
  "code": -32000,
  "data": {
    "authMethods": [
      {
        "id": "openai",
        "name": "Use OpenAI API key",
        "description": "Requires setting the `OPENAI_API_KEY` environment variable",
        "_meta": {
          "type": "terminal",
          "args": ["--auth-type=openai"]
        }
      }
    ]
  }
}
```

---

## Вывод

**Sandbox MVP работает частично:**

- ✅ Инфраструктура (Docker, sandbox, proxy, env, startup) — работает
- ✅ Двухуровневая авторизация (DP + Runtime) — работает
- ✅ Health и preflight endpoints — работают
- ❌ Session creation — требует JWT для Nestor

**Для завершения verifications требуется:**

1. Получить JWT токен от платформы или настроить обмен
2. Передать `BLAZE_DP_JWT` в sandbox environment
3. Выполнить шаги 3-7 из `blaze-runtime-sandbox-final-verification.md`
