# 3x-ui + XHTTP + Hysteria2 + Happ node installer

Автоматическое развёртывание ноды со схемой:

- `TCP/443 -> Caddy -> VLESS/XHTTP` по скрытому пути
- `UDP/443 -> Xray/Hysteria2`
- публичный masking site на корне домена
- `3x-ui` panel на отдельном порту с HTTPS
- Happ subscription с двумя профилями
- клиентский routing profile: RU/private -> DIRECT, остальное -> PROXY
- автоматическое продление Let's Encrypt с reload Caddy и restart x-ui
- radio stub site из `Balbuto/radio-stub-site`

## Требования

- чистый VPS с root-доступом
- A-запись домена уже указывает на IPv4 сервера
- TCP/80, TCP/443 и UDP/443 доступны извне
- Debian/Ubuntu или RHEL-like система с `apt`, `dnf` или `yum`

## Быстрый запуск

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/3x-ui-SETUP/main/install.sh)
```

Либо сохранить скрипт локально:

```bash
curl -fsSL https://raw.githubusercontent.com/evgmahov-blip/3x-ui-SETUP/main/install.sh -o /root/install-3xui-happ-node.sh
chmod 700 /root/install-3xui-happ-node.sh
/root/install-3xui-happ-node.sh
```

Скрипт запросит:

- DNS имя ноды, например `stream.example.com`
- email для Let's Encrypt

Остальные параметры генерируются автоматически.

## Важно: URL подписки

`SUB_PORT=2096` — это **только внутренний HTTPS listener 3x-ui**.

Он намеренно слушает `127.0.0.1:2096` и **не должен открываться наружу**.

Правильная публичная Happ subscription всегда идёт через Caddy на TCP/443:

```text
https://stream.example.com/<random-sub-path>/<sub-id>
```

Неправильно:

```text
https://stream.example.com:2096/<random-sub-path>/<sub-id>
```

Если в Happ была сохранена старая ссылка с `:2096`, её нужно удалить и добавить заново правильный URL без порта. Простого редактирования старой записи может быть недостаточно, если клиент сохранил исходный source URL.

## Переменные окружения

Можно запускать без интерактива:

```bash
DOMAIN='stream.example.com' \
EMAIL='admin@example.com' \
PANEL_PORT='8000' \
XHTTP_PORT='18443' \
SUB_PORT='2096' \
CLIENT_NAME='main' \
INSTALL_RADIO_STUB='yes' \
bash /root/install-3xui-happ-node.sh
```

Дополнительно можно заранее задать:

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

Если эти значения не указаны, безопасные случайные значения создаются автоматически.

## Что создаётся

После успешной установки скрипт выводит:

```text
Сайт:              https://stream.example.com/
Радио-админка:      https://stream.example.com/admin.html
3x-ui панель:       https://stream.example.com:8000/<random-path>/
Happ subscription:  https://stream.example.com/<random-sub-path>/<sub-id>
XHTTP:              stream.example.com:443 TCP
Hysteria2:          stream.example.com:443 UDP
```

Панельные username/password также выводятся в конце установки. Сохраните их.

## TLS

Для Caddy/XHTTP намеренно разрешён только TLS 1.2:

```caddy
protocols tls1.2 tls1.2
```

Hysteria2 работает через QUIC и использует TLS 1.3. Это разные транспортные пути.

## Сертификаты

Let's Encrypt управляется Certbot.

Исходные файлы:

```text
/etc/letsencrypt/live/<domain>/fullchain.pem
/etc/letsencrypt/live/<domain>/privkey.pem
```

Для Caddy и панели создаётся читаемая копия:

```text
/etc/caddy/certs/<domain>/fullchain.pem
/etc/caddy/certs/<domain>/privkey.pem
```

Deploy-hook Certbot после обновления:

1. обновляет копию сертификата;
2. валидирует Caddyfile;
3. reload Caddy;
4. restart x-ui.

## Caddy routing

Корень домена отдаёт masking site.

Только два специальных пути уходят во внутренние сервисы:

```text
/<subscription-path>/* -> HTTPS 127.0.0.1:2096
/<xhttp-path>/*        -> HTTP  127.0.0.1:18443
```

Публичный клиент при этом обращается только к `https://<domain>/<subscription-path>/<sub-id>` через TCP/443.

После включения SSL на панели 3x-ui subscription backend также работает по HTTPS, поэтому Caddy подключается к `127.0.0.1:2096` через TLS и проверяет сертификат по DNS-имени ноды.

Caddy слушает только HTTP/1.1 и HTTP/2, поэтому UDP/443 остаётся свободным для Hysteria2.

## Radio stub site

По умолчанию устанавливаются:

- `index.html`
- `admin.html`

из проекта `Balbuto/radio-stub-site`.

Админка радиосайта хранит настройки в `localStorage` браузера. Это клиентская настройка заглушки, а не серверная система управления.

## Happ routing

Инсталлятор передаёт routing profile через subscription headers.

Текущая логика:

```text
RU/private -> DIRECT
остальное  -> PROXY
```

Профиль содержит `geoip:ru`, `geoip:private` и приватные RFC1918/CGNAT сети.

`geosite:category-ru` оставлен как текущий доменный rule. Перед массовым production-развёртыванием желательно отдельно проверить, что используемая версия Happ содержит соответствующий geosite dataset.

## Безопасность

После первой проверки рекомендуется закрыть публичный panel port и разрешить его только с административных IP через UFW/nftables либо вынести панель за отдельный reverse proxy.

Скрипт специально не меняет firewall автоматически, чтобы не потерять SSH-доступ на удалённой машине.

**Не открывайте `2096/tcp` наружу.** Подписка публикуется через Caddy на `443/tcp`.

## Проверка после установки

Ожидаемые listeners:

```text
TCP 80                 Caddy
TCP 443                Caddy
UDP 443                Xray/Hysteria2
127.0.0.1:18443        Xray/XHTTP
127.0.0.1:2096         x-ui subscription HTTPS
TCP 8000               x-ui panel HTTPS
```

Публичная Happ subscription должна содержать две ссылки:

```text
vless://...
hysteria2://...
```

Инсталлятор дополнительно проверяет публичный subscription URL через Caddy, наличие двух профилей и то, что backend `2096` не опубликован как внешний listener.

## Обновление

Перед обновлением инсталлятора рекомендуется проверить diff и протестировать на отдельной ноде. Скрипт ориентирован прежде всего на первичное развёртывание чистого сервера, а не на повторный запуск поверх уже работающей конфигурации.
