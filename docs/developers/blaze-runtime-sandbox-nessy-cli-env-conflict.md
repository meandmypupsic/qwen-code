# Blaze Runtime Sandbox — Конфликт с ML Core NESSY_CLI_DP_AUTH_TOKEN

**Дата:** 2026-06-22  
**Версия:** @art/blaze-runtime@0.18.6  
**Статус:** 🔴 БЛОКИРОВАНО — требуется фикс entrypoint.sh

---

## Проблема

Sandbox не создаёт `/root/.blaze-runtime/dp_auth_creds.json`, хотя:

- `DP_TOKEN` передан в environment ✅
- Exchange DP токена на JWT работает через curl ✅
- `blaze-runtime serve` запускается ✅

**Результат:** `auth.source: "none"` в preflight, session creation fails.

---

## Корневая причина

ML Core Sandbox API **автоматически добавляет** переменную окружения:

```bash
NESSY_CLI_DP_AUTH_TOKEN=$NESTOR_TOKEN
```

Это **не JWT**, а literal строка `$NESTOR_TOKEN` (шаблон для подстановки).

### Конфликт в entrypoint.sh

Строки 47-50 `deploy/sandbox/blaze-runtime/entrypoint.sh`:

```bash
prepare_nestor_credentials() {
  if [ -n "${BLAZE_DP_JWT:-}" ] || [ -n "${NESSY_CLI_DP_AUTH_TOKEN:-}" ]; then
    log "delegated Nestor JWT env detected, skipping DP token exchange"
    return
  fi
```

**Проблема:** Проверка `[ -n "${NESSY_CLI_DP_AUTH_TOKEN:-}" ]` проходит, потому что строка `$NESTOR_TOKEN` **не пустая**.

**Результат:** `prepare_nestor_credentials()` делает `return` **без выполнения exchange**.

### Почему не срабатывает fallback на DP_TOKEN

Строки 26-28:

```bash
if [ -z "${BLAZE_DP_TOKEN:-}" ] && [ -n "${DP_TOKEN:-}" ]; then
  export BLAZE_DP_TOKEN="$DP_TOKEN"
fi
```

Эта логика **выполняется**, `BLAZE_DP_TOKEN` экспортируется.

Но в `prepare_nestor_credentials()`:

1. Проверка `NESSY_CLI_DP_AUTH_TOKEN` проходит (не пустой)
2. Функция делает `return` до проверки `BLAZE_DP_TOKEN`
3. Exchange **никогда не выполняется**

---

## Диагностика

### Env переменные в sandbox (через CommandEvents)

```bash
DP_TOKEN=ory_at_xA1z-8pdq7B-Z9I1tdYQPkvww7qybxLDGr7bqUFQDwA.Bza_W6U_G3oZnDieKDVaa6TnXDal_eLOsTYrrSgYkpY
BLAZE_RUNTIME_TOKEN=blaze-runtime-token-1782142045
NESSY_CLI_DP_AUTH_TOKEN=$NESTOR_TOKEN  # ← ЭТО НЕ JWT!
```

### Файлы credentials

```bash
cat /root/.blaze-runtime/dp_auth_creds.json
# cat: /root/.blaze-runtime/dp_auth_creds.json: No such file or directory
```

### Preflight auth cell

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

### Exchange работает вручную

```bash
curl -s -X POST \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{}" \
  https://code-completion-nestor.tcsbank.ru/api/v2/token

# Возвращает валидный JWT ✅
```

---

## Решение

### Исправить entrypoint.sh

Нужно проверять **валидность JWT** (3 части), а не просто наличие переменной:

```bash
prepare_nestor_credentials() {
  # Check if we have a valid delegated JWT (must be 3 parts separated by dots)
  if [ -n "${BLAZE_DP_JWT:-}" ]; then
    local jwt_parts
    jwt_parts=$(printf '%s' "$BLAZE_DP_JWT" | awk -F. '{print NF}')
    if [ "$jwt_parts" -eq 3 ]; then
      log "delegated Nestor JWT env detected (BLAZE_DP_JWT), skipping DP token exchange"
      prepare_credentials_from_jwt "$BLAZE_DP_JWT"
      return
    fi
  fi

  if [ -n "${NESSY_CLI_DP_AUTH_TOKEN:-}" ]; then
    local nessy_jwt_parts
    nessy_jwt_parts=$(printf '%s' "$NESSY_CLI_DP_AUTH_TOKEN" | awk -F. '{print NF}')
    if [ "$nessy_jwt_parts" -eq 3 ]; then
      log "delegated Nestor JWT env detected (NESSY_CLI_DP_AUTH_TOKEN), skipping DP token exchange"
      prepare_credentials_from_jwt "$NESSY_CLI_DP_AUTH_TOKEN"
      return
    else
      log "NESSY_CLI_DP_AUTH_TOKEN is set but not a valid JWT (expected 3 parts, got $nessy_jwt_parts), will use DP token exchange"
    fi
  fi

  if [ -z "${BLAZE_DP_TOKEN:-}" ]; then
    return
  fi

  # ... rest of exchange logic
}
```

### Требуемые изменения

1. **Добавить функцию `prepare_credentials_from_jwt()`** — принимает JWT и записывает credentials
2. **Изменить проверку `BLAZE_DP_JWT`** — проверять на валидность (3 части)
3. **Изменить проверку `NESSY_CLI_DP_AUTH_TOKEN`** — проверять на валидность (3 части), логировать если не JWT
4. **Позволить fallback на `BLAZE_DP_TOKEN`** — если `NESSY_CLI_DP_AUTH_TOKEN` не валидный JWT

---

## План действий

1. Исправить `deploy/sandbox/blaze-runtime/entrypoint.sh` — добавить проверку на валидность JWT
2. Собрать новый Docker image `blaze-runtime-sandbox:0.18.7`
3. Опубликовать image
4. Пересоздать sandbox с новым image
5. Проверить:
   - `/root/.blaze-runtime/dp_auth_creds.json` создан ✅
   - `preflight auth.source: "dp-auth"` ✅
   - `session create` работает ✅

---

## Временное решение (не рекомендуется)

Можно передать `BLAZE_DP_JWT` с валидным JWT напрямую, но это требует:

- Ручного получения JWT через `curl` к Nestor API
- Передачи JWT в sandbox environment (менее безопасно)

**Предпочтительное решение:** Исправить entrypoint.sh для автоматического exchange.

---

## Ссылки

- [Blaze Runtime Sandbox Auth Blocker](./blaze-runtime-sandbox-auth-blocker.md)
- [Blaze Runtime Sandbox Auth Solution](./blaze-runtime-sandbox-auth-solution.md)
- [deploy/sandbox/blaze-runtime/entrypoint.sh](../../deploy/sandbox/blaze-runtime/entrypoint.sh)
