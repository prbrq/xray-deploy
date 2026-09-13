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

Проект — **distribution, not a managed checkout**: репозиторий клонируется только для установки. После успешного deploy `bootstrap.sh` сохраняет provenance в `DEPLOYED_FROM` и удаляет `.git`. У VPS нет workflow `git pull` или in-place update: его можно свободно локально настраивать, не рискуя случайно отправить credentials в upstream.

## Что разворачивается

- Xray-core 26.9.8 из образа, закреплённого по digest;
- VLESS поверх RAW/TCP с `xtls-rprx-vision` и REALITY на `443/tcp`;
- Docker Compose и лог-ротация (3 × 10 MB);
- один первоначальный VLESS-профиль;
- fingerprint клиента `firefox` по умолчанию.

Собственный домен, nginx, сайт, TLS certificate, ACME и порт 80 не нужны.

## Перед началом: checklist

Перед запуском проверьте следующее:

- VPS работает на Ubuntu 22.04/24.04/26.04 или Debian 12/13, архитектура — `amd64` либо `arm64`;
- вы подключены к VPS и можете запускать команды через `sudo`;
- входящий `TCP/443` разрешён одновременно firewall VPS и firewall панели провайдера;
- вы готовы самостоятельно выбрать REALITY target; скрипт не выбирает его автоматически;
- терминал и история сессии не будут доступны посторонним: URI профиля выводится только по явному запросу.

`install-docker.sh` устанавливает Docker Engine и Docker Compose v2 только на указанные ОС. Он использует официальный подписанный Docker APT-репозиторий и не удаляет конфликтующие пакеты автоматически. `bootstrap.sh`, `deploy.sh` и `profile.sh` запускаются от root (через `sudo`); Xray внутри контейнера при этом работает без root.

## 1. Подготовить VPS

```bash
git clone <REPOSITORY_URL> xray-deploy
cd xray-deploy
chmod +x install-docker.sh bootstrap.sh deploy.sh profile.sh
sudo ./install-docker.sh
```

Если Docker и Compose v2 уже установлены, `install-docker.sh` только проверит daemon и завершится.

## 2. Установить сервер

```bash
sudo ./bootstrap.sh
```

Bootstrap показывает пять этапов: проверку требований, подготовку закреплённого образа, настройку credentials и target, TLS-проверку, затем deploy. Он фиксирует origin URL и commit hash, скачивает pinned image, создаёт недостающие UUID/X25519 keys/short ID, определяет публичный IP для клиентского адреса, сохраняет `.env`, рендерит и валидирует `config.json`, запускает Compose и лишь после успешного deploy удаляет `.git`.

При повторном запуске существующий `.env` загружается, поэтому уже созданные credentials не регенерируются.

## 3. Выбрать REALITY target

Target намеренно не выбирается автоматически. Это должен быть стабильный HTTPS hostname, который подходит для сети и ASN вашего VPS. Для первичной ориентации можно посмотреть ASN:

```bash
curl -s https://ipinfo.io/json
```

Не выбирайте без причины популярный generic CDN. Bootstrap проверяет выбранный host командой `xray tls ping` и требует успешный TLS handshake именно с SNI.

Если проверка не прошла, не обходите её. Типичные причины: hostname не разрешается с VPS, VPS не может установить исходящее HTTPS-соединение, сервер не принимает handshake с данным SNI, либо target нестабилен или фильтруется в сети VPS. Проверьте DNS и исходящий HTTPS, затем выберите другой стабильный HTTPS host и повторите `sudo ./bootstrap.sh`.

## 4. Проверить работу и получить профиль

После успешного bootstrap проверьте состояние сервера:

```bash
sudo docker compose ps
sudo ss -ltnp | grep ':443'
```

Контейнер должен быть запущен, а TCP/443 — слушаться. Затем **только в приватном терминале** получите импортируемый URI для OneXray:

```bash
sudo ./profile.sh
```

Скрипт печатает `vless://` URI, но не печатает REALITY Private Key. Не вставляйте URI в Git, чаты, тикеты, логи или запись экрана.

## 5. Обычные действия после установки

Применить локально изменённую конфигурацию без регенерации credentials:

```bash
sudo ./deploy.sh
```

Посмотреть логи и управлять сервисом:

```bash
sudo docker logs -f xray-reality
sudo docker compose ps
sudo docker compose down
sudo docker compose up -d
```

После ручного `docker compose up -d` проверьте статус контейнера. `deploy.sh` дополнительно рендерит и валидирует `config.json` и назначает ему UID непривилегированного пользователя Xray.

## FAQ

### Почему нельзя выполнить `git pull`?

После успешной установки `.git` намеренно удалён: целевой VPS отделяется от шаблонного репозитория. Для новой версии distribution подготовьте и проверьте новую установку, переключите клиент только после проверки и затем выведите из эксплуатации старую.

### Что сделает повторный `bootstrap.sh`?

Он переиспользует credentials из существующего `.env`, снова проверит target и применит конфигурацию. Не удаляйте `.env`, если хотите сохранить существующий профиль.

### Где хранить secrets и резервную копию?

`.env`, `config.json` и полный URI — секретные данные. `.env` и `config.json` имеют права `0600`. Храните резервную копию в защищённом хранилище, а не в Git, чатах, публичных заметках или логах.

### Кто отвечает за открытие 443/tcp?

Скрипт не меняет firewall VPS и настройки firewall провайдера. Это обязанность владельца VPS: нужно разрешить входящий `TCP/443` в обоих местах.

## Fingerprint

По умолчанию используется `firefox`: в рабочем стеке в протестированных российских сетях `chrome` начал зависать на REALITY handshake, а `firefox` работал стабильно. Это не означает, что Chrome fingerprint глобально заблокирован во всех сетях РФ.

Чтобы заменить fingerprint (например, на `safari`), измените `CLIENT_FINGERPRINT` в `.env`, затем заново получите URI:

```bash
sudo ./profile.sh
```

Серверный `config.json` для этого менять не нужно.

## Состояние файлов после bootstrap

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
├── install-docker.sh
└── profile.sh
```

`.git/` больше нет. Xray получает сгенерированный `config.json` только для чтения; права `0600` и read-only mount сохраняются.

## Обновления

Автоматических обновлений нет. Образ Xray закреплён по digest. Не заменяйте его на работающем VPS без отдельной подготовки, проверки и согласованного обновления distribution.

## Независимость VPS

Каждый VPS получает собственные UUID, REALITY key pair, short ID и target/SNI. Компрометация одного сервера не раскрывает credentials остальных. `DEPLOYED_FROM` сохраняет происхождение deployment даже после удаления `.git`.
