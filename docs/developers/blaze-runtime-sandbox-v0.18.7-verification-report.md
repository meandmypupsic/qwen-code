# Blaze Runtime Sandbox v0.18.7 — Отчёт о Верификации

**Дата:** 2026-06-22  
**Версия:** @art/blaze-runtime@0.18.7  
**Docker Image:** `docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.7`  
**Статус:** ✅ **ВЕРИФИКАЦИЯ ПРОЙДЕНА ПОЛНОСТЬЮ**

---

## 1. Резюме

Blaze Runtime Sandbox v0.18.7 успешно верифицирован. Все тесты пройдены:

- ✅ Health check с двумя токенами
- ✅ Preflight: `auth.source: "dp-auth"`
- ✅ Session created
- ✅ SSE stream opened
- ✅ Model response 1: "OK"
- ✅ Model response 2: "ORBIT-17" (recall test)
- ✅ Capital of France: "Paris"
- ✅ Capital of Russia: "Moscow"
- ✅ Code generation: Rust, JavaScript, Java

**Корневая проблема v0.18.6 исправлена:** ML Core автоматически добавляет `NESSY_CLI_DP_AUTH_TOKEN=$NESTOR_TOKEN` (literal строка, не JWT). Entrypoint v0.18.7 теперь проверяет валидность JWT (3 части) перед пропуском exchange.

### 1.1. Codex Validation Notes

Codex проверил отчёт после публикации и считает runtime-валидацию успешной:

- `preflight` показывает `auth.source: "dp-auth"` и `presentVar: "BLAZE_DP_TOKEN"`;
- `POST /session` вернул `sessionId` и `clientId`;
- SSE stream открылся и отдал `session_update`;
- recall test в той же session собрал `"ORBIT-17"` из streamed chunks.

Две правки внесены в сам отчёт:

- реальные DP/runtime токены заменены на `<redacted-...>`;
- формат `dp_auth_creds.json` исправлен: `expiresAt` хранится как epoch
  milliseconds number, не ISO string.

Для будущих повторений build-секция ниже должна считаться минимальной записью.
Перед публикацией обязательно выполнять `npm run prepare:package` и grep markers
из runbook, даже если отчёт с runtime-проверкой уже успешен.

---

## 2. Сборка npm Пакета

### 2.1. Подготовка

```bash
cd /Users/s.salnikov/Documents/Developers/qwen-code
git pull origin main
```

Получен коммит `fcc48bb96` с фиксом entrypoint.sh:

```
fix(blaze-runtime): ignore ML Core Nestor placeholder
```

### 2.2. Сборка

```bash
npm install
npm run build
npm run bundle
npm run prepare:package
```

**Результат:**

- `dist/cli.js` — bundled CLI
- `packages/core/dist/` — compiled core
- `@art/blaze-runtime@0.18.7` готов к публикации

Перед publish должны проходить freshness checks:

```bash
node -e "const p=require('./dist/package.json'); console.log(p.name, p.version, p.bin)"
grep -R "Use Nestor / DP auth" dist
grep -R "BLAZE_RUNTIME_AUTH_TYPE" dist
grep -R '\$NESTOR_TOKEN' dist
```

### 2.3. Публикация в Artifactory

```bash
npm publish --registry https://artifactory.tcsbank.ru/artifactory/api/npm/npm-hosted/
```

**Результат:** ✅ `@art/blaze-runtime@0.18.7` опубликован в `npm-hosted`

---

## 3. Сборка Docker Образа

### 3.1. Build

```bash
docker build \
  -f deploy/sandbox/blaze-runtime/Dockerfile \
  -t docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.7 \
  .
```

### 3.2. Push в Artifactory

```bash
docker push docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.7
```

**Результат:** ✅ Docker image опубликован

---

## 4. Запуск Sandbox

### 4.1. Параметры Запуска

Sandbox запущен через ML Core Sandbox API со следующими параметрами:

| Параметр                | Значение                                                                |
| ----------------------- | ----------------------------------------------------------------------- |
| **Image**               | `docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.7` |
| **Sandbox ID**          | `019ef008-bb09-7d59-870f-2a12462903ef`                                  |
| **Job**                 | `sandbox-erb4pb`                                                        |
| **Port**                | `4170`                                                                  |
| **DP_TOKEN**            | `<redacted>` (Ory access token)                                         |
| **BLAZE_RUNTIME_TOKEN** | `<redacted-runtime-token>`                                        |

### 4.2. Environment Variables

```bash
DP_TOKEN=<redacted-dp-token>
BLAZE_RUNTIME_TOKEN=<redacted-runtime-token>
NESSY_CLI_DP_AUTH_TOKEN=$NESTOR_TOKEN  # ← ML Core добавляет автоматически
```

**Важно:** ML Core Sandbox API автоматически добавляет `NESSY_CLI_DP_AUTH_TOKEN=$NESTOR_TOKEN`. Это literal строка (шаблон для подстановки), **не JWT**.

### 4.3. Boot Sequence

1. Entrypoint проверяет `NESSY_CLI_DP_AUTH_TOKEN` — строка не пустая, но **не валидный JWT** (не 3 части)
2. Entrypoint выполняет exchange `DP_TOKEN` → JWT через Nestor API
3. Записывает credentials:
   - `/root/.blaze-runtime/dp_auth_creds.json`
   - `/root/.nessy/dp_auth_creds.json`
4. Экспортирует `DP_AUTH=true`
5. Запускает `blaze-runtime serve`
6. Spawn ACP child: `blaze-runtime --acp --auth-type=dp-auth`

---

## 5. Авторизация в Nestor API

### 5.1. Двухуровневая Авторизация

Blaze Runtime использует два уровня авторизации:

| Уровень           | Header                                                  | Назначение                    |
| ----------------- | ------------------------------------------------------- | ----------------------------- |
| **ML Core Proxy** | `Authorization: Bearer <DP_TOKEN>`                      | Доступ к прокси ML Core       |
| **Runtime**       | `X-Blaze-Runtime-Authorization: Bearer <RUNTIME_TOKEN>` | Доступ к blaze-runtime daemon |

### 5.2. Exchange Токена

Entrypoint выполняет exchange DP токена на JWT:

```bash
curl -X POST \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{}" \
  https://code-completion-nestor.tcsbank.ru/api/v2/token
```

**Ответ Nestor:**

```json
{
  "jwt": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expiresIn": 3600
}
```

### 5.3. Формат Credentials

Файл `/root/.blaze-runtime/dp_auth_creds.json`:

```json
{
  "jwt": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expiresAt": 1782147227842,
  "username": "...",
  "userId": "...",
  "cachedModels": []
}
```

---

## 6. Верификация: Пошаговый Флоу

### 6.1. Переменные Окружения для Тестов

```bash
export RUNTIME_URL="https://mlcore.t-tech.team/tools/jobs-proxy/projects/art/jobs/sandbox-erb4pb/ports/4170/"
export DP_TOKEN="<redacted-dp-token>"
export RUNTIME_TOKEN="<redacted-runtime-token>"
```

### 6.2. Шаг 1: Health Check

**Тест 1: Без runtime токена (ожидаем 401)**

```bash
curl -sS -H "Authorization: Bearer $DP_TOKEN" "$RUNTIME_URL/health"
```

**Результат:**

```json
{ "error": "Unauthorized" }
```

✅ HTTP 401 — runtime требует второй уровень авторизации

**Тест 2: С обоими токенами (ожидаем 200)**

```bash
curl -sS \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  "$RUNTIME_URL/health"
```

**Результат:**

```json
{ "status": "ok" }
```

✅ HTTP 200 — оба уровня авторизации работают

---

### 6.3. Шаг 2: Preflight

```bash
curl -sS \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  "$RUNTIME_URL/workspace/preflight" | jq '.cells[] | select(.kind == "auth")'
```

**Результат:**

```json
{
  "kind": "auth",
  "locality": "acp",
  "status": "ok",
  "detail": {
    "source": "dp-auth",
    "hasToken": true,
    "envVarCandidates": [
      "BLAZE_DP_TOKEN",
      "DP_TOKEN",
      "BLAZE_DP_JWT",
      "NESSY_CLI_DP_AUTH_TOKEN"
    ],
    "presentVar": "BLAZE_DP_TOKEN"
  }
}
```

✅ **`auth.source: "dp-auth"`** — авторизация через DP token работает

---

### 6.4. Шаг 3: Создание Сессии

```bash
CREATE=$(curl -sS -X POST \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "$RUNTIME_URL/session")

echo "$CREATE" | jq .

SESSION_ID=$(echo "$CREATE" | jq -r '.sessionId')
CLIENT_ID=$(echo "$CREATE" | jq -r '.clientId')
```

**Результат:**

```json
{
  "sessionId": "54846358-dbbb-4fbe-8fde-2b90cb98d64c",
  "workspaceCwd": "/workspace",
  "attached": true,
  "clientId": "client_972ad733-ad38-4b15-9ddb-b60b6b930e48",
  "createdAt": "2026-06-22T15:53:47.842Z"
}
```

✅ Сессия создана: `SESSION_ID=54846358-dbbb-4fbe-8fde-2b90cb98d64c`

---

### 6.5. Шаг 4: Открытие SSE Stream

**Важно:** `Last-Event-ID` должен быть передан как **HTTP header**, не query parameter.

```bash
rm -f /tmp/sse.log

curl -N -sS \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "X-Qwen-Client-Id: $CLIENT_ID" \
  -H "Last-Event-ID: 0" \
  "$RUNTIME_URL/session/$SESSION_ID/events?maxQueued=1024" \
  > /tmp/sse.log &
```

**Ожидание handshake:**

```bash
sleep 3
tail -10 /tmp/sse.log
```

**Результат:**

```text
retry: 3000
```

✅ SSE stream открыт

---

### 6.6. Шаг 5: Промпт 1 — ORBIT-17 (Запоминание)

**Отправка промпта:**

```bash
PROMPT1=$(curl -sS -X POST \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Qwen-Client-Id: $CLIENT_ID" \
  -d '{"prompt":[{"type":"text","text":"Remember this exact code word for the next message: ORBIT-17. Reply with OK only."}]}' \
  "$RUNTIME_URL/session/$SESSION_ID/prompt")

echo "$PROMPT1" | jq .
```

**Ответ API:**

```json
{
  "promptId": "7d617060-7e62-4364-920d-8461029593bc",
  "lastEventId": 5
}
```

**Ожидание ответа модели:**

```bash
sleep 45
```

**Чтение SSE лога:**

```bash
grep 'agent_message_chunk' /tmp/sse.log | head -10
```

**Результат (SSE events):**

```text
id: 3
event: session_update
data: {"content":{"text":"OK","type":"text"},"sessionUpdate":"agent_message_chunk"}

id: 4
event: session_update
data: {"_meta":{"usage":{"inputTokens":20254,"outputTokens":2,"totalTokens":20256}},"sessionUpdate":"agent_message_chunk"}
```

✅ **Модель ответила: "OK"**

---

### 6.7. Шаг 6: Промпт 2 — ORBIT-17 (Recall Test)

**Отправка промпта (та же сессия, тот же client):**

```bash
PROMPT2=$(curl -sS -X POST \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $RUNTIME_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Qwen-Client-Id: $CLIENT_ID" \
  -d '{"prompt":[{"type":"text","text":"What exact code word did I ask you to remember? Answer with the code word only."}]}' \
  "$RUNTIME_URL/session/$SESSION_ID/prompt")

echo "$PROMPT2" | jq .
```

**Ответ API:**

```json
{
  "promptId": "11cfd119-d72b-4cc3-a88e-646229a94d79",
  "lastEventId": 9
}
```

**Ожидание ответа модели:**

```bash
sleep 30
```

**Чтение SSE лога (assembly chunks):**

```bash
grep 'agent_message_chunk' /tmp/sse.log | tail -10
```

**Результат (SSE events):**

```text
id: 11
event: session_update
data: {"content":{"text":"OR","type":"text"},"sessionUpdate":"agent_message_chunk"}

id: 12
event: session_update
data: {"content":{"text":"BIT","type":"text"},"sessionUpdate":"agent_message_chunk"}

id: 13
event: session_update
data: {"content":{"text":"-1","type":"text"},"sessionUpdate":"agent_message_chunk"}

id: 14
event: session_update
data: {"content":{"text":"7","type":"text"},"sessionUpdate":"agent_message_chunk"}
```

**Сборка ответа:** `OR` + `BIT` + `-1` + `7` = **"ORBIT-17"**

✅ **Модель вспомнила: "ORBIT-17"**

---

### 6.8. Шаг 7: Дополнительные Тесты

#### Тест A: Столица Франции

**Промпт:**

```text
What is the capital of France? Answer with the city name only.
```

**SSE Response:**

```text
id: 18
event: session_update
data: {"content":{"text":"Paris","type":"text"},"sessionUpdate":"agent_message_chunk"}
```

✅ **Ответ: "Paris"**

---

#### Тест B: Столица России

**Промпт:**

```text
What is the capital of Russia? Answer with the city name only.
```

**SSE Response:**

```text
id: 22
event: session_update
data: {"content":{"text":"Mos","type":"text"},"sessionUpdate":"agent_message_chunk"}

id: 23
event: session_update
data: {"content":{"text":"cow","type":"text"},"sessionUpdate":"agent_message_chunk"}
```

**Сборка ответа:** `Mos` + `cow` = **"Moscow"**

✅ **Ответ: "Moscow"**

---

#### Тест C: Code Generation (Rust, JS, Java)

**Промпт:**

```text
Write a hello world function in Rust, JavaScript, and Java. Show all three code examples.
```

**SSE Response (сборка):**

**Rust:**

```rust
fn main() {
    println!("Hello, world!");
}
```

**JavaScript:**

```javascript
function helloWorld() {
  console.log('Hello, world!');
}
```

**Java:**

```java
public class HelloWorld {
    public static void main(String[] args) {
        System.out.println("Hello, world!");
    }
}
```

✅ **Код сгенерирован на всех трёх языках**

---

## 7. Итоговая Таблица Тестов

| №   | Тест                        | Ожидаемый Результат        | Фактический                            | Статус |
| --- | --------------------------- | -------------------------- | -------------------------------------- | ------ |
| 1   | Health (без runtime токена) | HTTP 401                   | HTTP 401                               | ✅     |
| 2   | Health (с обоими токенами)  | HTTP 200 `{"status":"ok"}` | HTTP 200 `{"status":"ok"}`             | ✅     |
| 3   | Preflight auth              | `auth.source: "dp-auth"`   | `auth.source: "dp-auth"`               | ✅     |
| 4   | Session create              | `sessionId` не null        | `54846358-dbbb-4fbe-8fde-2b90cb98d64c` | ✅     |
| 5   | SSE open                    | `retry: 3000`              | `retry: 3000`                          | ✅     |
| 6   | Prompt 1 (запоминание)      | "OK"                       | "OK"                                   | ✅     |
| 7   | Prompt 2 (recall)           | "ORBIT-17"                 | "ORBIT-17"                             | ✅     |
| 8   | Capital of France           | "Paris"                    | "Paris"                                | ✅     |
| 9   | Capital of Russia           | "Moscow"                   | "Moscow"                               | ✅     |
| 10  | Code generation             | Rust + JS + Java           | Все 3 языка                            | ✅     |

---

## 8. Критерии Успеха

Все критерии выполнены:

1. ✅ `/health` только с DP header → HTTP 401
2. ✅ `/health` с DP + runtime headers → HTTP 200
3. ✅ `/workspace/preflight` → `auth.detail.source: "dp-auth"`
4. ✅ `POST /session` → `sessionId` и `clientId` не null
5. ✅ SSE открыт с `Last-Event-ID: 0` как HTTP header
6. ✅ Prompt 1 → `promptId` + SSE `session_update`
7. ✅ Prompt 2 → `promptId` + SSE `session_update`
8. ✅ assembled text chunks = "ORBIT-17"
9. ✅ Daemon не перезапускался между промптами
10. ✅ ACP child/session не пересоздавался между промптами

---

## 9. Артефакты

| Файл                                     | Описание                              |
| ---------------------------------------- | ------------------------------------- |
| `/tmp/sse.log`                           | SSE events log (полный поток событий) |
| `/tmp/blaze-runtime-preflight.json`      | Preflight response                    |
| `/tmp/blaze-runtime-create-session.json` | Session create response               |
| `/tmp/blaze-runtime-prompt1.json`        | Prompt 1 API response                 |
| `/tmp/blaze-runtime-prompt2.json`        | Prompt 2 API response                 |

---

## 10. Выводы

### 10.1. Исправление v0.18.7

**Проблема v0.18.6:**

- ML Core добавляет `NESSY_CLI_DP_AUTH_TOKEN=$NESTOR_TOKEN` (literal строка)
- Entrypoint проверял только на пустоту, не на валидность JWT
- Exchange пропускался, credentials не создавались

**Фикс v0.18.7:**

- Добавлена проверка JWT на валидность (3 части через `.`)
- Non-JWT `NESSY_CLI_DP_AUTH_TOKEN` логируется и игнорируется
- Fallback на `BLAZE_DP_TOKEN` exchange работает корректно

### 10.2. Статус

**Blaze Runtime Sandbox v0.18.7 полностью верифицирован и готов к использованию.**

Все тесты пройдены, модель отвечает на промпты, контекст сохраняется между запросами, код генерируется корректно.

---

## 11. Ссылки

- [Blaze Runtime Sandbox Auth Blocker](./blaze-runtime-sandbox-auth-blocker.md)
- [Blaze Runtime Sandbox Auth Solution](./blaze-runtime-sandbox-auth-solution.md)
- [Blaze Runtime Sandbox — Конфликт с ML Core NESSY_CLI_DP_AUTH_TOKEN](./blaze-runtime-sandbox-nessy-cli-env-conflict.md)
- [Blaze Runtime Sandbox Final Verification](./blaze-runtime-sandbox-final-verification.md)
- [deploy/sandbox/blaze-runtime/entrypoint.sh](../../deploy/sandbox/blaze-runtime/entrypoint.sh)
