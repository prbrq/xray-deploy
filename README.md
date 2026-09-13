# xray-deploy

Одноразовый дистрибутив для развёртывания минимального Xray REALITY-сервера.

```text
OneXray
   |
   | VLESS + RAW + xtls-rprx-vision + REALITY
   | fingerprint: firefox
   | TCP/443
   v
Xray-core 26.9.8 (pinned image digest)
   |
   v
Internet
```

Проект устроен как **distribution, not a managed checkout**: клонируем репозиторий, запускаем `./bootstrap.sh`, после успешного deploy сохраняем provenance в `DEPLOYED_FROM` и удаляем `.git`. Конкретный VPS после этого живёт самостоятельно и может свободно кастомизироваться. `git pull` и in-place update workflow намеренно отсутствуют.

## Что разворачивается

- Xray-core 26.9.8;
- VLESS;
- RAW/TCP;
- `xtls-rprx-vision`;
- REALITY;
- TCP/443;
- Docker Compose;
- log rotation: 3 x 10 MB;
- один первоначальный VLESS user;
- client fingerprint по умолчанию: `firefox`.

Не нужны собственный домен, nginx, белый сайт, TLS certificate, ACME и порт 80.

## Требования

До bootstrap должны быть установлены Docker Engine, Docker Compose v2, `curl`, `openssl`, `python3`. `git` нужен только для clone/provenance. TCP/443 должен быть разрешён в firewall VPS/провайдера.

```bash
docker --version
docker compose version
```

## Быстрый старт

```bash
git clone <REPOSITORY_URL> xray-deploy
cd xray-deploy
chmod +x bootstrap.sh deploy.sh profile.sh
./bootstrap.sh
```

Bootstrap фиксирует origin URL и commit hash, скачивает pinned Xray image, генерирует отдельные UUID/X25519 keys/shortId, определяет публичный IP, просит REALITY target, проверяет target через `xray tls ping`, создаёт `.env`, рендерит и валидирует `config.json`, запускает Compose, печатает готовый `vless://` URI для OneXray, записывает `DEPLOYED_FROM` и **только после успешного deploy удаляет `.git`**.

## REALITY target

Target намеренно не выбирается автоматически. Для нового VPS можно сначала посмотреть ASN:

```bash
curl -s https://ipinfo.io/json
```

Затем выбрать стабильный HTTPS hostname, подходящий для VPS, и проверить его. Bootstrap сам требует успешный handshake с SNI. Не стоит без причины использовать популярный CDN как target.

## После bootstrap

```text
xray-deploy/
├── .env
├── .env.example
├── .gitignore
├── DEPLOYED_FROM
├── README.md
├── bootstrap.sh
├── config.json
├── config.json.template
├── deploy.sh
├── docker-compose.yml
└── profile.sh
```

`.git/` больше нет. `.env` и `config.json` имеют `chmod 600`.
Xray работает без root: `deploy.sh` назначает сгенерированному `config.json` UID, заданный образом Xray по умолчанию. Права `0600` и read-only mount сохраняются.

### Профиль OneXray

```bash
./profile.sh
```

Скрипт не печатает REALITY Private Key, только импортируемый `vless://` URI.

### Применить локальные изменения

```bash
./deploy.sh
```

Секреты не регенерируются. Если `.env` уже существует, повторный `bootstrap.sh` также переиспользует существующие credentials.

### Логи и управление

```bash
docker logs -f xray-reality
docker compose ps
sudo ss -ltnp | grep ':443'
docker compose down
docker compose up -d
```

Docker logs ограничены 3 файлами по 10 MB.

## Секреты

`.env`, `config.json` и полный `vless://` URI не должны публиковаться. До удаления `.git` они защищены `.gitignore`. После bootstrap Git metadata удаляется специально, чтобы локальная настройка не превращалась в набор modified/untracked файлов и чтобы случайно не отправить credentials в upstream.

## Fingerprint

По умолчанию используется `firefox`: в рабочем стеке в протестированных российских сетях `chrome` начал зависать на REALITY handshake, а `firefox` работал стабильно. Это не утверждение, что Chrome fingerprint глобально заблокирован во всех сетях РФ.

Для замены fingerprint (например на `safari`) достаточно изменить `CLIENT_FINGERPRINT` в `.env` и заново получить URI через `./profile.sh`; серверный `config.json` менять не нужно.

## Обновления

Автоматических обновлений нет намеренно. Xray image pinned по digest. Для новой версии distribution: подготовить и протестировать новую версию репозитория, развернуть её заново, переключить OneXray и только после проверки убрать старый экземпляр.

## Независимость VPS

Каждый VPS получает собственные UUID, REALITY key pair, short ID и target/SNI. Компрометация одного сервера не раскрывает credentials остальных. `DEPLOYED_FROM` сохраняет происхождение deployment даже после удаления `.git`.
