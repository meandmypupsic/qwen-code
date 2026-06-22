# Blaze Runtime Sandbox Docker Build

Этот документ описывает процесс сборки Docker образа для Blaze Runtime Sandbox и известные проблемы.

## Проблема: SSL ошибка при сборке Docker образа

### Симптом

При запуске `docker build` для `deploy/sandbox/blaze-runtime/Dockerfile`:

```
ERROR: failed to solve: failed to resolve source metadata for docker.io/docker/dockerfile:1:
failed to do request: Head "https://registry-1.docker.io/v2/docker/dockerfile/manifests/1":
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

### Причина

Строка `# syntax=docker/dockerfile:1` в начале Dockerfile заставляет Docker BuildKit скачать образ `docker/dockerfile:1` с Docker Hub (`registry-1.docker.io`).

В корпоративной сети TCS Bank:

- Docker Hub блокируется корпоративным прокси
- SSL-сертификаты подменяются (SSL inspection)
- Docker не доверяет корпоративному CA-сертификату

### Решение

**Удалить строку `# syntax=docker/dockerfile:1` из Dockerfile.**

Эта строка **не обязательна** — Docker будет использовать стандартный парсер Dockerfile.

```dockerfile
# Было:
# syntax=docker/dockerfile:1

# Blaze Runtime replacement for the old nessy-cli async sandbox image flow.
ARG BASE_IMAGE=docker-hosted.artifactory.tcsbank.ru/cicd-images/nodejs-22
FROM --platform=linux/amd64 ${BASE_IMAGE}
...

# Стало:
# Blaze Runtime replacement for the old nessy-cli async sandbox image flow.
ARG BASE_IMAGE=docker-hosted.artifactory.tcsbank.ru/cicd-images/nodejs-22
FROM --platform=linux/amd64 ${BASE_IMAGE}
...
```

### Альтернативное решение (не рекомендуется)

Настроить Docker для доверия корпоративным сертификатам:

```bash
# Скопировать корпоративный CA-сертификат
sudo cp /usr/local/share/ca-certificates/tinkoff-bundle.crt /etc/docker/certs.d/docker.io/ca.crt

# Перезапустить Docker
sudo systemctl restart docker
```

Это решение сложнее и требует root-прав.

## Полный цикл сборки и публикации

### 1. Подготовка npm пакета

```bash
# Сборка
npm ci
npm run build --workspace=packages/core
npm run build --workspace=packages/cli
npm run bundle
npm run prepare:package

# Проверка dist/package.json
node -e "const p=require('./dist/package.json'); console.log(p.name, p.version, p.bin)"
# Ожидаемый вывод: @art/blaze-runtime 0.18.3 { qwen: 'cli-entry.js', 'blaze-runtime': 'blaze-runtime-entry.js' }
```

### 2. Публикация npm в Artifactory

```bash
# Настройка аутентификации
dp auth configure-npm

# Публикация
cd dist
npm publish --registry="https://artifactory.tcsbank.ru/artifactory/api/npm/npm-hosted/"

# Проверка
npm view @art/blaze-runtime@0.18.3 --registry="https://artifactory.tcsbank.ru/artifactory/api/npm/npm-hosted/"
```

### 3. Сборка Docker образа

```bash
cd /Users/s.salnikov/Documents/Developers/qwen-code

export BLAZE_RUNTIME_PACKAGE="@art/blaze-runtime"
export BLAZE_RUNTIME_VERSION="0.18.3"
export NPM_REGISTRY="https://artifactory.tcsbank.ru/artifactory/api/npm/npm-hosted/"
export IMAGE="docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:${BLAZE_RUNTIME_VERSION}"

docker build --platform linux/amd64 \
  -f deploy/sandbox/blaze-runtime/Dockerfile \
  --build-arg NPM_REGISTRY="$NPM_REGISTRY" \
  --build-arg BLAZE_RUNTIME_PACKAGE="$BLAZE_RUNTIME_PACKAGE" \
  --build-arg BLAZE_RUNTIME_VERSION="$BLAZE_RUNTIME_VERSION" \
  -t "$IMAGE" \
  .
```

### 4. Тегирование и Push в Artifactory

```bash
# Тегирование (если нужно другое имя)
docker tag "$IMAGE" docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:latest

# Push
docker push docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:${BLAZE_RUNTIME_VERSION}
```

### 5. Проверка публикации

```bash
docker pull docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:${BLAZE_RUNTIME_VERSION}
```

## Локальное тестирование образа

```bash
# Запуск с тестовыми переменными окружения
docker run --rm \
  -e BLAZE_RUNTIME_TOKEN="local-dev-token" \
  -e BLAZE_DP_TOKEN="<dp-token>" \
  -p 4170:4170 \
  docker-hosted.artifactory.tcsbank.ru/art/blaze-runtime-sandbox:0.18.3

# В другом терминале: health check
curl -i http://127.0.0.1:4170/health
curl -i -H "Authorization: Bearer local-dev-token" http://127.0.0.1:4170/health
```

Ожидаемый результат:

- Без токена: `HTTP 401 Unauthorized`
- С токеном: `HTTP 200 OK {"status":"ok"}`

## Структура Docker образа

**Base image:** `docker-hosted.artifactory.tcsbank.ru/cicd-images/nodejs-22`

**Установленные пакеты:**

- `@art/blaze-runtime` (глобально через npm)
- `ca-certificates`, `curl`, `git`, `jq`, `lsof`, `procps`, `ripgrep`

**Порт:** `4170` (HTTP)

**Entrypoint:** `/entrypoint.sh` — запускает `blaze-runtime serve`

**Переменные окружения:**

- `BLAZE_RUNTIME_TOKEN` — bearer токен для HTTP daemon
- `BLAZE_DP_TOKEN` или `DP_TOKEN` — токен для обмена на Nestor JWT
- `BLAZE_RUNTIME_HOST=0.0.0.0`
- `BLAZE_RUNTIME_PORT=4170`
- `BLAZE_RUNTIME_WORKSPACE=/workspace`

## Частые ошибки

| Ошибка                                         | Решение                                                                        |
| ---------------------------------------------- | ------------------------------------------------------------------------------ |
| `tls: failed to verify certificate` при сборке | Удалить `# syntax=docker/dockerfile:1` из Dockerfile                           |
| `blaze-runtime binary not found`               | Проверить что npm пакет опубликован и установлен глобально                     |
| `403 Forbidden` при npm publish                | Использовать `npm-hosted` вместо `npm-all`, проверить права Artifact publisher |
| `EBADREQ` при npm publish                      | Войти в Artifactory UI и нажать Devplatform для активации роли                 |

## Ссылки

- [Blaze Runtime Sandbox MVP Handoff](./blaze-runtime-sandbox-mvp-handoff.md)
- [Blaze Runtime Local Smoke Test](./blaze-runtime-local-smoke-test.md)
- [deploy/sandbox/blaze-runtime/README.md](../../deploy/sandbox/blaze-runtime/README.md)
- [Spirit Docs: Docker-образы](https://devplatform.pages.devplatform.tcsbank.ru/spirit-user-docs/docs/build/artifacts/registry/)
