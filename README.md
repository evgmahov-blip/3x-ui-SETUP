# 3x-ui + XHTTP + Hysteria2 + Happ

Готовый установщик ноды на чистый VPS.

Он автоматически разворачивает:

- `3x-ui`
- `VLESS + XHTTP`
- `Hysteria2`
- `Caddy`
- HTTPS-сертификат Let's Encrypt
- masking site
- Happ subscription сразу с двумя профилями
- Happ routing: `RU/private -> DIRECT`, остальное -> `PROXY`

---

# Быстрая установка

## Вариант 1 — одна команда

Запустить от `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/3x-ui-SETUP/main/install.sh)
```

Это основной и рекомендуемый способ установки.

## Ссылка на установочный скрипт

[Открыть install.sh](https://raw.githubusercontent.com/evgmahov-blip/3x-ui-SETUP/main/install.sh)

Репозиторий:

[https://github.com/evgmahov-blip/3x-ui-SETUP](https://github.com/evgmahov-blip/3x-ui-SETUP)

## Вариант 2 — скачать скрипт на сервер

```bash
curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/3x-ui-SETUP/main/install.sh -o /root/install-3xui-happ-node.sh
chmod 700 /root/install-3xui-happ-node.sh
/root/install-3xui-happ-node.sh
```

---

# Что нужно до запуска

Нужен чистый VPS с root-доступом.

Перед установкой должны выполняться условия:

1. Есть домен или поддомен, например:

```text
finx.example.com
```

2. Его `A`-запись уже указывает на публичный IPv4 VPS.

3. Снаружи доступны:

```text
TCP 80
TCP 443
UDP 443
```

4. Поддерживаемая ОС:

```text
Debian / Ubuntu
или
RHEL-like с dnf/yum
```

---

# Что спросит установщик

Во время запуска нужно ввести только:

```text
DNS имя ноды
Email для Let's Encrypt
```

Например:

```text
DNS имя ноды: finx.example.com
Email: admin@example.com
```

Остальное установщик создаёт автоматически:

- логин панели
- пароль панели
- путь панели
- путь XHTTP
- путь подписки
- SubID клиента
- остальные необходимые параметры

---

# Как устроена нода

Схема после установки:

```text
                         INTERNET
                            |
                  +---------+---------+
                  |                   |
               TCP/443             UDP/443
                  |                   |
                Caddy              Hysteria2
                  |
          +-------+--------+
          |                |
     masking site       special paths
                           |
                  +--------+--------+
                  |                 |
             VLESS/XHTTP        Happ subscription
            127.0.0.1:18443     127.0.0.1:2096
```

То есть:

```text
TCP/443 -> Caddy -> VLESS/XHTTP
TCP/443 -> Caddy -> Happ subscription
UDP/443 -> Xray/Hysteria2
```

---

# Очень важно: URL Happ subscription

Порт:

```text
2096
```

используется **только внутри сервера**.

3x-ui subscription слушает:

```text
127.0.0.1:2096
```

Этот порт **не надо открывать наружу**.

Публичная подписка всегда работает через Caddy на обычном HTTPS-порту `443`.

Правильно:

```text
https://finx.example.com/<subscription-path>/<sub-id>
```

Неправильно:

```text
https://finx.example.com:2096/<subscription-path>/<sub-id>
```

Если в Happ раньше была добавлена ссылка с `:2096`, лучше:

1. удалить старую подписку;
2. закрыть Happ;
3. открыть Happ снова;
4. добавить новую ссылку без `:2096`.

Это важно, потому что клиент может сохранить старый source URL даже после редактирования записи.

---

# Что установщик выводит в конце

После успешной установки будет примерно такой результат:

```text
Сайт:              https://finx.example.com/
Радио-админка:      https://finx.example.com/admin.html
3x-ui панель:       https://finx.example.com:8000/<random-panel-path>/
Happ subscription:  https://finx.example.com/<random-sub-path>/<sub-id>
XHTTP:              finx.example.com:443 TCP
Hysteria2:          finx.example.com:443 UDP
```

Также установщик показывает логин и пароль панели 3x-ui.

Сохраните их сразу после установки.

---

# Что будет внутри Happ subscription

Одна подписка содержит сразу два подключения:

```text
VLESS + XHTTP
Hysteria2
```

То есть не нужно добавлять два отдельных профиля вручную.

Установщик проверяет, что оба подключения реально присутствуют в subscription body.

---

# Happ routing

Установщик добавляет routing profile:

```text
RU/private -> DIRECT
остальное  -> PROXY
```

В DIRECT входят:

```text
geoip:ru
geoip:private
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.168.0.0/16
```

Также используется:

```text
geosite:category-ru
```

---

# TLS

Для публичного TCP/443 через Caddy намеренно используется только:

```text
TLS 1.2
```

Конфигурация Caddy:

```caddy
protocols tls1.2 tls1.2
```

Hysteria2 работает отдельно:

```text
UDP/443
QUIC
TLS 1.3
```

Это два разных транспортных пути и они не конфликтуют.

---

# Сертификаты

Сертификат получает Certbot через Let's Encrypt.

Исходные файлы:

```text
/etc/letsencrypt/live/<domain>/fullchain.pem
/etc/letsencrypt/live/<domain>/privkey.pem
```

Для Caddy и x-ui создаётся отдельная читаемая копия:

```text
/etc/caddy/certs/<domain>/fullchain.pem
/etc/caddy/certs/<domain>/privkey.pem
```

Права каталога и файлов выставляются так, чтобы Caddy мог читать сертификат.

После продления сертификата deploy-hook автоматически:

1. копирует новый сертификат;
2. проверяет Caddyfile;
3. reload-ит Caddy;
4. restart-ит x-ui.

---

# Masking site

На корне домена работает обычный сайт-заглушка.

По умолчанию используется:

[Balbuto/radio-stub-site](https://github.com/Balbuto/radio-stub-site)

Файлы располагаются в:

```text
/var/www/mstream
```

Основная страница:

```text
https://finx.example.com/
```

Админ-страница заглушки:

```text
https://finx.example.com/admin.html
```

Настройки radio-stub-site хранятся в `localStorage` браузера. Это не серверная админ-панель.

---

# Ожидаемые порты после установки

Нормальное состояние:

```text
TCP 80                 Caddy
TCP 443                Caddy
UDP 443                Xray/Hysteria2
127.0.0.1:18443        Xray/XHTTP
127.0.0.1:2096         x-ui subscription HTTPS
TCP <panel-port>        x-ui panel HTTPS
```

Ключевой момент:

```text
127.0.0.1:2096
```

должен оставаться локальным.

Наружу subscription публикуется только через:

```text
TCP/443 -> Caddy
```

---

# Firewall

Установщик специально **не меняет firewall автоматически**.

Это сделано для того, чтобы случайно не потерять SSH-доступ к удалённому VPS.

Перед установкой снаружи должны быть доступны:

```text
80/tcp
443/tcp
443/udp
```

Не нужно открывать:

```text
2096/tcp
18443/tcp
```

Они внутренние.

Порт панели 3x-ui после проверки рекомендуется ограничить firewall-ом по административным IP.

---

# Проверки, которые делает установщик

В конце установки автоматически проверяются:

- DNS домена;
- соответствие DNS публичному IP сервера;
- получение сертификата;
- доступ Caddy к сертификату;
- запуск x-ui;
- запуск Caddy;
- наличие VLESS/XHTTP inbound;
- наличие Hysteria2 inbound;
- наличие клиента в обоих inbound;
- masking site через HTTPS;
- публичная Happ subscription через TCP/443;
- отсутствие `:2096` в публичном subscription URL;
- наличие VLESS в подписке;
- наличие Hysteria2 в подписке;
- локальный listener `127.0.0.1:2096`.

---

# Неинтерактивная установка

При необходимости параметры можно передать заранее:

```bash
DOMAIN='finx.example.com' \
EMAIL='admin@example.com' \
PANEL_PORT='8000' \
XHTTP_PORT='18443' \
SUB_PORT='2096' \
CLIENT_NAME='main' \
INSTALL_RADIO_STUB='yes' \
bash /root/install-3xui-happ-node.sh
```

Дополнительно поддерживаются:

```text
PANEL_USER
PANEL_PASS
PANEL_PATH
SUB_PATH
XHTTP_PATH
SUB_ID
XUI_VERSION
WEBROOT
```

Если их не задавать, значения генерируются автоматически.

---

# Обновление установщика

Для новой чистой ноды всегда используйте актуальную версию из `main`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/3x-ui-SETUP/main/install.sh)
```

Прямая ссылка:

[https://raw.githubusercontent.com/evgmahov-blip/3x-ui-SETUP/main/install.sh](https://raw.githubusercontent.com/evgmahov-blip/3x-ui-SETUP/main/install.sh)

Скрипт в первую очередь рассчитан на **первичную установку чистого VPS**. Повторный запуск поверх уже работающей production-ноды лучше выполнять только после проверки изменений.
