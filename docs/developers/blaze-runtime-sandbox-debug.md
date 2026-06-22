# Blaze Runtime Sandbox — Отладка и запуск

Этот документ подробно описывает проблемы, с которыми мы столкнулись при первом запуске
Blaze Runtime Sandbox через ML Core Sandbox API, и как мы их решали.

## Контекст

Мы только что опубликовали:

- npm пакет `@art/blaze-runtime@0.18.3` в `npm-hosted`
- Docker образ `docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.3`

Теперь нужно запустить sandbox через ML Core API и проверить работу.

## Критическое уточнение после диагностики

Первичный отчёт ниже полезен как история отладки, но два его промежуточных
вывода были неполными:

1. В ML Core sandbox не нужно ждать, что Docker `ENTRYPOINT` нашего image станет
   главным процессом. Sandbox API запускает `/sandbox-binaries/sandbox-agent`,
   а пользовательскую команду надо передать через `startupOptions.executeCommand`.
   Для Blaze Runtime это должен быть один долгоживущий startup command:
   `["/entrypoint.sh"]`.

2. Не нужно делать `BLAZE_RUNTIME_TOKEN = DP token`. Это смешивает два разных
   слоя авторизации. Через ML Core proxy используем два заголовка:

   ```text
   Authorization: Bearer <dp-token-for-ml-core-proxy>
   X-Blaze-Runtime-Authorization: Bearer <runtime-bearer-token>
   ```

   `Authorization` проверяет ML Core / DevPlatform. Новый заголовок
   `X-Blaze-Runtime-Authorization` проверяет `blaze-runtime serve`.

---

## Проблема 1: Sandbox создан без containerPorts — нет proxy URL

### Что сделали

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"project": "art", "spec": {"flavor": "2cpu-4ram", "image": "..."}}' \
  https://mlcore.t-tech.team/tools/sandbox-api/.../Start
```

### Результат

Sandbox перешёл в `RUNNING`, но `proxyUrls` пустой:

```json
{
  "status": {
    "state": "RUNNING",
    "proxyUrls": []
  }
}
```

### Причина

При создании sandbox не были указаны `containerPorts`. ML Core не знает какие порты
пробрасывать через proxy.

### Решение

Указать `containerPorts` при создании:

```json
{
  "containerPorts": [{ "port": 4170, "name": "http" }]
}
```

**Важно:** имя порта должно быть < 16 символов, только `[a-z0-9_]`. `blaze-runtime` не подойдёт.

---

## Проблема 2: Не установлены переменные окружения — blaze-runtime не запускается

### Что сделали

Создали sandbox с `containerPorts`, но без `environment`.

### Результат

Sandbox в `RUNNING`, proxy URL есть, но health endpoint возвращает **502 Bad Gateway**.

Проверка процессов внутри sandbox:

```bash
ps aux
```

```
PID 1: /pause
PID 57: /ml_core_binaries/go-init /sandbox-binaries/sandbox-agent
PID 98: /sandbox-binaries/sandbox-agent
```

**blaze-runtime не запущен!**

### Анализ entrypoint.sh

Entrypoint проверяет переменные:

```bash
if [ -z "${BLAZE_RUNTIME_TOKEN:-}" ]; then
  fail "BLAZE_RUNTIME_TOKEN is required..."
fi

if [ -z "${BLAZE_DP_TOKEN:-}" ] && \
   [ -z "${BLAZE_DP_JWT:-}" ] && \
   [ -z "${NESSY_CLI_DP_AUTH_TOKEN:-}" ]; then
  fail "set BLAZE_DP_TOKEN/DP_TOKEN for Nestor exchange..."
fi
```

**Проблема:** переменные не переданы, entrypoint должен был упасть с ошибкой, но
sandbox-agent молчит.

### Решение

Передать `environment` при создании sandbox:

```json
{
  "environment": {
    "BLAZE_RUNTIME_TOKEN": "sandbox-dev-token",
    "BLAZE_DP_TOKEN": "ory_at_...",
    "BLAZE_RUNTIME_HOST": "0.0.0.0",
    "BLAZE_RUNTIME_PORT": "4170",
    "BLAZE_RUNTIME_WORKSPACE": "/workspace"
  }
}
```

---

## Проблема 3: Путаница с токенами — какие за что отвечают?

### Три типа токенов

В процессе отладки мы запутались в трёх разных токенах:

| Токен                       | Где используется                            | Кто проверяет         |
| --------------------------- | ------------------------------------------- | --------------------- |
| **DP Token** (`ory_at_...`) | Авторизация в **ML Core Proxy**             | ML Core / DevPlatform |
| **BLAZE_RUNTIME_TOKEN**     | Авторизация в **blaze-runtime HTTP daemon** | blaze-runtime         |
| **BLAZE_DP_TOKEN**          | Обмен на JWT для **Nestor API**             | Nestor (через DP)     |

### Где какой токен нужен

#### 1. Доступ к proxy URL (ML Core)

```bash
curl -H "Authorization: Bearer <DP_TOKEN>" \
  https://mlcore.t-tech.team/tools/jobs-proxy/.../ports/4170/health
```

**ML Core Proxy** проверяет DP токен. Без него — `401 Unauthorized` от proxy.

#### 2. Доступ к blaze-runtime напрямую, без ML Core proxy

```bash
curl -H "Authorization: Bearer <BLAZE_RUNTIME_TOKEN>" \
  http://<sandbox>:4170/health
```

**blaze-runtime** проверяет `BLAZE_RUNTIME_TOKEN`. Без него — `401 Unauthorized` от daemon.
Через ML Core proxy использовать этот же `Authorization` для runtime token нельзя:
он занят DP-токеном для proxy. Через proxy используйте
`X-Blaze-Runtime-Authorization`.

#### 3. Обмен на Nestor JWT

```bash
# Внутри blaze-runtime, при вызове Nestor API
POST https://nestor/...
Authorization: Bearer <JWT_from_BLAZE_DP_TOKEN_exchange>
```

**Nestor** принимает JWT, который blaze-runtime получает через обмен `BLAZE_DP_TOKEN`.

### Путаница

Мы пытались:

1. **DP token как BLAZE_RUNTIME_TOKEN** — blaze-runtime возвращает `401`, потому что
   не знает про формат Ory токенов.

2. **BLAZE_RUNTIME_TOKEN как Authorization для proxy** — ML Core proxy возвращает
   `401`, потому что ожидает DP token.

3. **Оба токена одновременно** — не поняли что proxy **пропускает** заголовок в
   sandbox, но **сам тоже проверяет** Authorization.

### Вывод

**Два уровня авторизации:**

```
User --[DP Token]--> ML Core Proxy --[BLAZE_RUNTIME_TOKEN]--> blaze-runtime
```

ML Core Proxy:

1. Проверяет `Authorization: Bearer <DP_TOKEN>`
2. Пропускает запрос в sandbox
3. **Не передаёт** заголовок в sandbox (или передаёт?)

blaze-runtime:

1. Получает запрос от proxy
2. Проверяет `X-Blaze-Runtime-Authorization: Bearer <BLAZE_RUNTIME_TOKEN>`
3. Отвечает

**Вопрос:** передаёт ли proxy заголовок `Authorization` в sandbox?

---

## Проблема 4: 502 Bad Gateway — сервис не слушает порт

### Симптомы

```bash
curl -H "Authorization: Bearer $DP_TOKEN" \
  https://mlcore.t-tech.team/.../ports/4170/health
# HTTP 502 Bad Gateway
```

### Проверка внутри sandbox

```bash
# Порт не слушается
lsof -i :4170
# (пусто)

# Процессы
ps aux
# blaze-runtime отсутствует
```

### Анализ логов sandbox

```
2026-06-22 15:09:02.9453 [ML Core] Job is waiting until the docker image is pulled...
2026-06-22 15:09:11.2348 12:09PM INF Starting health probes at 0.0.0.0:9093
2026-06-22 15:09:11.2349 12:09PM INF sandbox agent started
2026-06-22 15:09:11.2427 12:09PM INF Serving GRPC at 0.0.0.0:9091
2026-06-22 15:09:11.2752 12:09PM INF Serving REST at 0.0.0.0:9090
2026-06-22 15:09:11.3596 12:09PM INF Starting to serve metrics at 0.0.0.0:9092
```

**Что видно:**

- sandbox-agent запустился (порты 9090, 9091, 9092, 9093)
- **Нет логов от entrypoint.sh** — значит он не выполнился или упал
- **Нет логов от blaze-runtime** — значит не запускался

**Уточнённый вывод:** в ML Core sandbox пользовательский Docker `ENTRYPOINT` не
является основным процессом. Основным процессом является sandbox-agent. Поэтому
`/entrypoint.sh` нужно явно запускать через `startupOptions.executeCommand`.
Отсутствующие env всё равно были отдельной проблемой, но даже с env не стоит
рассчитывать на автоматический Docker ENTRYPOINT.

### Ручной запуск blaze-runtime

```bash
# Внутри sandbox через ExecuteCommand
blaze-runtime serve --hostname 0.0.0.0 --port 4170 --workspace /workspace --require-auth
```

После ручного запуска:

```bash
curl -H "Authorization: Bearer sandbox-dev-token" \
  https://mlcore.t-tech.team/.../ports/4170/health
# HTTP 401 Unauthorized (ожидаемо — blaze-runtime требует свой токен)
```

**Сервис работает!**

---

## Проблема 5: entrypoint.sh не запускается автоматически

### Вопрос

Почему entrypoint.sh не запустил blaze-runtime автоматически?

### Гипотезы

1. **Entrypoint не указан в Dockerfile** — проверили: указан

   ```dockerfile
   ENTRYPOINT ["/entrypoint.sh"]
   ```

2. **Entrypoint упал на проверке переменных** — проверили логи: нет логов вообще
   - Возможно stderr не попадает в логи ML Core?

3. **Sandbox-agent не запускает entrypoint** — sandbox-agent только предоставляет
   API для ExecuteCommand, но не управляет entrypoint?

### Анализ Dockerfile

```dockerfile
ENTRYPOINT ["/entrypoint.sh"]
```

Entrypoint должен запуститься при старте контейнера. Но:

```bash
ps aux
# /entrypoint.sh отсутствует в списке процессов
```

**Вывод:** entrypoint упал сразу после старта контейнера.

### Проверка environment

```bash
env | grep BLAZE
# BLAZE_RUNTIME_PACKAGE=@art/blaze-runtime
# BLAZE_RUNTIME_PORT=4170
# BLAZE_RUNTIME_HOST=0.0.0.0
# BLAZE_RUNTIME_WORKSPACE=/workspace
# BLAZE_RUNTIME_TOKEN=ОТСУТСТВУЕТ
# BLAZE_DP_TOKEN=ОТСУТСТВУЕТ
```

**Причина:** переменные не были переданы при создании sandbox.

---

## Проблема 6: DP token vs BLAZE_RUNTIME_TOKEN — какой куда?

### Эксперимент 1: DP token как Authorization для proxy

```bash
curl -H "Authorization: Bearer $DP_TOKEN" \
  https://mlcore.t-tech.team/.../ports/4170/health
# HTTP 502 (сервис не запущен)
```

Proxy работает, но сервис не отвечает.

### Эксперимент 2: BLAZE_RUNTIME_TOKEN как Authorization для proxy

```bash
curl -H "Authorization: Bearer sandbox-dev-token" \
  https://mlcore.t-tech.team/.../ports/4170/health
# HTTP 401 Unauthorized
```

Proxy не принимает BLAZE_RUNTIME_TOKEN.

### Эксперимент 3: DP token после запуска blaze-runtime

```bash
curl -H "Authorization: Bearer $DP_TOKEN" \
  https://mlcore.t-tech.team/.../ports/4170/health
# HTTP 401 {"error": "Unauthorized"}
```

Proxy пропустил запрос, blaze-runtime вернул 401.

**Вывод:** blaze-runtime не принимает DP token как BLAZE_RUNTIME_TOKEN.

### Эксперимент 4: BLAZE_RUNTIME_TOKEN после запуска blaze-runtime

```bash
curl -H "Authorization: Bearer sandbox-dev-token" \
  https://mlcore.t-tech.team/.../ports/4170/health
# HTTP 401 (proxy не пропускает)
```

Proxy не пропускает запрос без DP token.

### Тупик в старой реализации

- Proxy требует DP token
- blaze-runtime требует BLAZE_RUNTIME_TOKEN
- оба слоя хотели использовать один и тот же HTTP header `Authorization`

**Правильное решение:** не использовать один токен для обоих уровней. Runtime
теперь поддерживает отдельный заголовок `X-Blaze-Runtime-Authorization`, поэтому
`Authorization` остаётся внешним DP/ML Core proxy header.

---

## Проблема 7: Как передавать оба токена?

### Правильный вариант: разные заголовки

```bash
curl \
  -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $BLAZE_RUNTIME_TOKEN" \
  https://mlcore.t-tech.team/.../ports/4170/health
```

`Authorization` проверяет ML Core proxy. `X-Blaze-Runtime-Authorization`
проверяет `blaze-runtime serve`.

### Неправильный вариант: DP token = BLAZE_RUNTIME_TOKEN

Не передавать один и тот же токен в обоих местах:

```json
{
  "environment": {
    "BLAZE_RUNTIME_TOKEN": "ory_at_...",
    "BLAZE_DP_TOKEN": "ory_at_..."
  }
}
```

```bash
curl -H "Authorization: Bearer ory_at_..." \
  https://mlcore.t-tech.team/.../ports/4170/health
```

Это был временный обходной вариант из первичной отладки. Не использовать его как
целевой MVP flow.

---

## Итоговый рабочий алгоритм

### 1. Получить свежий DP token

```bash
DP_TOKEN=$(python3 ~/.nessy/skills/dp-auth-token.py)
```

### 2. Создать sandbox с правильными переменными

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "project": "art",
    "spec": {
      "flavor": "2cpu-4ram",
      "image": "docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.3",
      "containerPorts": [{"port": 4170, "name": "http"}],
      "environment": {
        "BLAZE_RUNTIME_TOKEN": "'"$BLAZE_RUNTIME_TOKEN"'",
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

**Критично:**

- `containerPorts` с именем `< 16` символов
- `startupOptions.executeCommand = ["/entrypoint.sh"]`
- `BLAZE_RUNTIME_TOKEN` — отдельный runtime token, не DP token
- `BLAZE_DP_TOKEN` = DP token (для Nestor)

### 3. Дождаться RUNNING

```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"identity": {"project": "art", "id": "'"$SANDBOX_ID"'"}}' \
  https://mlcore.t-tech.team/tools/sandbox-api/.../WatchStatus
```

Ждать `"state":"RUNNING"` и появления proxy URL.

### 4. Проверить health

```bash
RUNTIME_URL="https://mlcore.t-tech.team/tools/jobs-proxy/projects/art/jobs/.../ports/4170/"

curl -H "Authorization: Bearer $DP_TOKEN" \
  -H "X-Blaze-Runtime-Authorization: Bearer $BLAZE_RUNTIME_TOKEN" \
  "$RUNTIME_URL/health"
```

Ожидаемый результат:

- `HTTP 200 OK` — успех
- `HTTP 401 Unauthorized` — blaze-runtime требует токен (проверить environment)
- `HTTP 502 Bad Gateway` — сервис не запущен (проверить entrypoint логи)

---

## Чеклист для следующего запуска

- [ ] Получить свежий DP token (`dp-auth-token.py`)
- [ ] Указать `containerPorts` с коротким именем (`http`, не `blaze-runtime`)
- [ ] Передать `environment` с `BLAZE_RUNTIME_TOKEN` и `BLAZE_DP_TOKEN`
- [ ] Передать `startupOptions.executeCommand: ["/entrypoint.sh"]`
- [ ] Не использовать DP token как `BLAZE_RUNTIME_TOKEN`
- [ ] Дождаться `RUNNING` и появления proxy URL
- [ ] Проверить health с DP token в `Authorization` и runtime token в `X-Blaze-Runtime-Authorization`
- [ ] Если 502 — проверить `ps aux` внутри sandbox
- [ ] Если 401 — проверить что `BLAZE_RUNTIME_TOKEN` установлен

---

## Приложения

### A. Логи sandbox (полные)

```
2026-06-22 15:09:02.9453 [ML Core] Job is waiting until the docker image is pulled...
2026-06-22 15:09:11.2348 12:09PM INF Starting health probes at 0.0.0.0:9093
2026-06-22 15:09:11.2349 12:09PM INF sandbox agent started
2026-06-22 15:09:11.2427 12:09PM INF Serving GRPC at 0.0.0.0:9091
2026-06-22 15:09:11.2752 12:09PM INF Serving REST at 0.0.0.0:9090
2026-06-22 15:09:11.3596 12:09PM INF Starting to serve metrics at 0.0.0.0:9092
2026-06-22 15:11:00.7535 12:11PM INF requested command execution command=["ps","aux"] ...
2026-06-22 15:11:23.9634 12:11PM INF requested command execution command=["cat","/entrypoint.sh"] ...
2026-06-22 15:11:51.9911 12:11PM INF requested command execution command=["which","blaze-runtime"] ...
2026-06-22 15:12:04.8553 12:12PM INF requested command execution command=["lsof","-i",":4170"] ...
2026-06-22 15:12:41.2284 12:12PM INF requested command execution command=["blaze-runtime","serve",...] ...
```

### B. environment внутри sandbox (полный)

```
BLAZE_RUNTIME_PACKAGE=@art/blaze-runtime
BLAZE_RUNTIME_PORT=4170
BLAZE_RUNTIME_HOST=0.0.0.0
BLAZE_RUNTIME_WORKSPACE=/workspace
DP_USER_NAME=s.salnikov
TINKOFFPY_DP_TOKEN=ory_at_...
NESSY_CLI_DP_AUTH_TOKEN=$NESTOR_TOKEN
...
```

### C. entrypoint.sh — ключевые проверки

```bash
# Строка 21-22
if [ -z "${BLAZE_RUNTIME_TOKEN:-}" ]; then
  fail "BLAZE_RUNTIME_TOKEN is required..."
fi

# Строка 25-32
if [ -z "${BLAZE_DP_TOKEN:-}" ] && \
   [ -z "${BLAZE_DP_JWT:-}" ] && \
   [ -z "${NESSY_CLI_DP_AUTH_TOKEN:-}" ]; then
  fail "set BLAZE_DP_TOKEN/DP_TOKEN for Nestor exchange..."
fi
```

---

## Ссылки

- [Blaze Runtime Sandbox MVP Handoff](./blaze-runtime-sandbox-mvp-handoff.md)
- [Blaze Runtime Local Smoke Test](./blaze-runtime-local-smoke-test.md)
- [deploy/sandbox/blaze-runtime/README.md](../../deploy/sandbox/blaze-runtime/README.md)
- [docs/developers/blaze-runtime-sandbox-docker-build.md](./blaze-runtime-sandbox-docker-build.md)
