#!/usr/bin/env bash
set -Eeuo pipefail

TASK='3X-UI HAPP NODE INSTALL'
echo "#################### НАЧАЛО ВЫВОДА: ${TASK} ####################"

trap 'rc=$?; echo "[ОШИБКА] Установка прервана, код: $rc"; echo "#################### КОНЕЦ ВЫВОДА: ${TASK} ####################"; exit $rc' ERR

if [ "${EUID}" -ne 0 ]; then
  echo '[ОШИБКА] Запустите скрипт от root.'
  exit 1
fi

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
PANEL_PORT="${PANEL_PORT:-8000}"
XHTTP_PORT="${XHTTP_PORT:-18443}"
SUB_PORT="${SUB_PORT:-2096}"
CLIENT_NAME="${CLIENT_NAME:-main}"
INSTALL_RADIO_STUB="${INSTALL_RADIO_STUB:-yes}"
XUI_VERSION="${XUI_VERSION:-3.7.0}"
WEBROOT="${WEBROOT:-/var/www/mstream}"

rand_alnum() {
  local n="${1:-16}"
  local out
  set +o pipefail
  out="$(tr -dc 'a-z0-9' </dev/urandom | head -c "$n")"
  set -o pipefail
  printf '%s' "$out"
}

rand_pass() {
  local n="${1:-24}"
  local out
  set +o pipefail
  out="$(tr -dc 'A-Za-z0-9_!@#%+=' </dev/urandom | head -c "$n")"
  set -o pipefail
  printf '%s' "$out"
}

if [ -z "$DOMAIN" ]; then
  read -r -p 'DNS имя ноды (например stream.example.com): ' DOMAIN
fi
if [ -z "$EMAIL" ]; then
  read -r -p "Email для Let's Encrypt: " EMAIL
fi

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
  echo '[ОШИБКА] DOMAIN и EMAIL обязательны.'
  exit 1
fi

PANEL_USER="${PANEL_USER:-admin_$(rand_alnum 8)}"
PANEL_PASS="${PANEL_PASS:-$(rand_pass 24)}"
PANEL_PATH="${PANEL_PATH:-/$(rand_alnum 24)/}"
SUB_PATH="${SUB_PATH:-/$(rand_alnum 16)/}"
XHTTP_PATH="${XHTTP_PATH:-/api/v1/$(rand_alnum 8)/events/}"
SUB_ID="${SUB_ID:-$(rand_alnum 24)}"

normalize_path() {
  local p="$1"
  [[ "$p" == /* ]] || p="/$p"
  [[ "$p" == */ ]] || p="$p/"
  printf '%s' "$p"
}
PANEL_PATH="$(normalize_path "$PANEL_PATH")"
SUB_PATH="$(normalize_path "$SUB_PATH")"
XHTTP_PATH="$(normalize_path "$XHTTP_PATH")"

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl jq openssl ca-certificates certbot git caddy python3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release || true
    dnf install -y curl jq openssl ca-certificates certbot git caddy python3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y curl jq openssl ca-certificates certbot git caddy python3
  else
    echo '[ОШИБКА] Не найден apt/dnf/yum.'
    exit 1
  fi
}

wait_http() {
  local url="$1"
  for _ in $(seq 1 30); do
    curl -fsS "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

echo '[1/13] Предварительные проверки'
RESOLVED_IP="$( (getent ahostsv4 "$DOMAIN" 2>/dev/null || true) | awk 'NR==1{print $1}' )"
PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
echo "Domain:      $DOMAIN"
echo "DNS IPv4:    ${RESOLVED_IP:-не найден}"
echo "Public IPv4: ${PUBLIC_IP:-не определён}"

if [ -z "$RESOLVED_IP" ]; then
  echo '[ОШИБКА] DNS имя пока не резолвится в IPv4. Проверьте A-запись домена.'
  exit 1
fi

if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "$RESOLVED_IP" ]; then
  echo '[ОШИБКА] DNS A-запись не указывает на этот сервер.'
  echo "Ожидался IP сервера: $PUBLIC_IP"
  echo "DNS сейчас отдаёт:   $RESOLVED_IP"
  exit 1
fi

install_packages

echo "[2/13] Получаю сертификат Let's Encrypt"
if systemctl is-active --quiet caddy 2>/dev/null; then
  systemctl stop caddy
fi
certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"

LE_DIR="/etc/letsencrypt/live/${DOMAIN}"
[ -s "$LE_DIR/fullchain.pem" ] && [ -s "$LE_DIR/privkey.pem" ] || { echo '[ОШИБКА] Сертификат не получен.'; exit 1; }

mkdir -p "/etc/caddy/certs/${DOMAIN}"
install -o root -g caddy -m 0640 "$LE_DIR/fullchain.pem" "/etc/caddy/certs/${DOMAIN}/fullchain.pem"
install -o root -g caddy -m 0640 "$LE_DIR/privkey.pem" "/etc/caddy/certs/${DOMAIN}/privkey.pem"
chmod 0750 "/etc/caddy/certs/${DOMAIN}"

echo '[3/13] Устанавливаю 3x-ui'
export XUI_USERNAME="$PANEL_USER"
export XUI_PASSWORD="$PANEL_PASS"
export XUI_PANEL_PORT="$PANEL_PORT"
export XUI_WEB_BASE_PATH="$PANEL_PATH"
export XUI_SSL_MODE='none'

curl -fsSL "https://raw.githubusercontent.com/MHSanaei/3x-ui/v${XUI_VERSION}/install.sh" -o /tmp/3x-ui-install.sh
bash /tmp/3x-ui-install.sh
rm -f /tmp/3x-ui-install.sh

[ -s /etc/x-ui/install-result.env ] || { echo '[ОШИБКА] 3x-ui не создал install-result.env.'; exit 1; }
. /etc/x-ui/install-result.env

PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
PANEL_PATH="${XUI_WEB_BASE_PATH:-$PANEL_PATH}"
PANEL_PATH="$(normalize_path "$PANEL_PATH")"
API_TOKEN="${XUI_API_TOKEN:-}"
if [ -z "$API_TOKEN" ]; then
  API_TOKEN="$(/usr/local/x-ui/x-ui setting -getApiToken 2>/dev/null | tail -n1 | xargs || true)"
fi
[ -n "$API_TOKEN" ] || { echo '[ОШИБКА] Не удалось получить API token 3x-ui.'; exit 1; }

API="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH%/}"
api_get() { curl -fsS -H "Authorization: Bearer ${API_TOKEN}" "${API}/${1#/}"; }
api_post() { curl -fsS -H "Authorization: Bearer ${API_TOKEN}" -H 'Content-Type: application/json' -X POST "${API}/${1#/}" -d "${2:-{}}"; }

wait_http "http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}" || true

echo '[4/13] Настраиваю Happ subscription'
ROUTING_JSON="$(jq -cn '{Name:"RU DIRECT",GlobalProxy:"true",DirectSites:["geosite:category-ru"],DirectIp:["geoip:ru","geoip:private","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"],ProxySites:[],ProxyIp:[],BlockSites:[],BlockIp:[],DomainStrategy:"IPIfNonMatch",FakeDNS:"false"}')"
ROUTING_B64="$(printf '%s' "$ROUTING_JSON" | base64 -w0)"
HAPP_ROUTING="happ://routing/onadd/${ROUTING_B64}"

SETTINGS="$(api_post 'panel/api/setting/all' '{}')"
printf '%s' "$SETTINGS" | jq -e '.success == true' >/dev/null
OBJ="$(printf '%s' "$SETTINGS" | jq '.obj')"
OBJ="$(printf '%s' "$OBJ" | jq --arg domain "$DOMAIN" --arg listen '127.0.0.1' --arg path "$SUB_PATH" --arg routing "$HAPP_ROUTING" --argjson port "$SUB_PORT" '.subListen=$listen | .subPort=$port | .subPath=$path | .subDomain=$domain | .subEnable=true | .subEncrypt=true | .subEnableRouting=true | .subRoutingRules=$routing')"
RESP="$(api_post 'panel/api/setting/update' "$OBJ")"
printf '%s' "$RESP" | jq -e '.success == true' >/dev/null
systemctl restart x-ui
sleep 3

API="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH%/}"

echo '[5/13] Создаю VLESS/XHTTP inbound'
XHTTP_BODY="$(jq -cn --arg path "$XHTTP_PATH" --arg domain "$DOMAIN" --argjson port "$XHTTP_PORT" '{up:0,down:0,total:0,remark:"VLESS XHTTP",enable:true,expiryTime:0,listen:"127.0.0.1",port:$port,protocol:"vless",settings:{clients:[],decryption:"none",fallbacks:[]},streamSettings:{network:"xhttp",security:"none",externalProxy:[{forceTls:"tls",dest:$domain,port:443,remark:"public",show:true}],xhttpSettings:{path:$path,host:$domain,mode:"packet-up",xPaddingBytes:"100-1000",xPaddingObfsMode:true,xPaddingKey:"_dc",xPaddingHeader:"X-Cache",xPaddingPlacement:"queryInHeader",xPaddingMethod:"tokenish",sessionIDPlacement:"cookie",sessionIDKey:"sid",sessionIDTable:"Base62",sessionIDLength:"16-32",seqPlacement:"cookie",seqKey:"seq",scMaxBufferedPosts:30,scStreamUpServerSecs:"20-80",noSSEHeader:false,serverMaxHeaderBytes:0,headers:{},enableXmux:false}},sniffing:{enabled:true,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:true}}')"
RESP="$(api_post 'panel/api/inbounds/add' "$XHTTP_BODY")"
printf '%s' "$RESP" | jq -e '.success == true' >/dev/null

echo '[6/13] Создаю Hysteria2 inbound UDP/443'
HY2_BODY="$(jq -cn --arg cert "$LE_DIR/fullchain.pem" --arg key "$LE_DIR/privkey.pem" '{up:0,down:0,total:0,remark:"Hysteria2",enable:true,expiryTime:0,listen:"",port:443,protocol:"hysteria",settings:{version:2,clients:[]},streamSettings:{network:"hysteria",security:"tls",hysteriaSettings:{version:2,auth:"",udpIdleTimeout:60},tlsSettings:{serverName:"",minVersion:"1.2",maxVersion:"1.3",cipherSuites:"",rejectUnknownSni:false,disableSystemRoot:false,enableSessionResumption:false,certificates:[{certificateFile:$cert,keyFile:$key,ocspStapling:3600,oneTimeLoading:false,usage:"encipherment"}],alpn:["h3"]}},sniffing:{enabled:true,destOverride:["http","tls","quic","fakedns"],metadataOnly:false,routeOnly:true}}')"
RESP="$(api_post 'panel/api/inbounds/add' "$HY2_BODY")"
printf '%s' "$RESP" | jq -e '.success == true' >/dev/null

INBOUNDS="$(api_get 'panel/api/inbounds/list')"
XHTTP_ID="$(printf '%s' "$INBOUNDS" | jq -r 'first(.obj[] | select(.remark=="VLESS XHTTP") | .id) // empty')"
HY2_ID="$(printf '%s' "$INBOUNDS" | jq -r 'first(.obj[] | select(.remark=="Hysteria2") | .id) // empty')"
[ -n "$XHTTP_ID" ] && [ -n "$HY2_ID" ] || { echo '[ОШИБКА] Не найдены ID inbound-ов.'; exit 1; }

echo '[7/13] Создаю одного клиента на оба inbound-а'
CLIENT_BODY="$(jq -cn --arg email "$CLIENT_NAME" --arg subId "$SUB_ID" --argjson xhttp "$XHTTP_ID" --argjson hy2 "$HY2_ID" '{email:$email,enable:true,expiryTime:0,totalGB:0,limitIp:0,subId:$subId,inboundIds:[$xhttp,$hy2]}')"
RESP="$(api_post 'panel/api/clients/add' "$CLIENT_BODY")"
printf '%s' "$RESP" | jq -e '.success == true' >/dev/null
systemctl restart x-ui
sleep 3

echo '[8/13] Устанавливаю radio-stub-site'
mkdir -p "$WEBROOT"
if [ "$INSTALL_RADIO_STUB" = 'yes' ]; then
  TMP_SITE="$(mktemp -d)"
  curl -fsSL 'https://raw.githubusercontent.com/Balbuto/radio-stub-site/main/index.html' -o "$TMP_SITE/index.html"
  curl -fsSL 'https://raw.githubusercontent.com/Balbuto/radio-stub-site/main/admin.html' -o "$TMP_SITE/admin.html"
  rm -rf "${WEBROOT}.old"
  [ -d "$WEBROOT" ] && mv "$WEBROOT" "${WEBROOT}.old" || true
  mkdir -p "$WEBROOT"
  cp -a "$TMP_SITE"/. "$WEBROOT"/
  chmod -R a+rX "$WEBROOT"
  rm -rf "$TMP_SITE"
else
  cat >"$WEBROOT/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Media</title><h1>Media service</h1>
HTML
fi

echo '[9/13] Настраиваю Caddy'
[ -f /etc/caddy/Caddyfile ] && cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d-%H%M%S)" || true
cat >/etc/caddy/Caddyfile <<CADDY
{
    servers {
        protocols h1 h2
    }
    auto_https off
}

https://${DOMAIN}:443 {
    tls /etc/caddy/certs/${DOMAIN}/fullchain.pem /etc/caddy/certs/${DOMAIN}/privkey.pem {
        protocols tls1.2 tls1.2
    }

    @subscription path ${SUB_PATH}*
    reverse_proxy @subscription https://127.0.0.1:${SUB_PORT} {
        header_up Host ${DOMAIN}
        transport http {
            tls_server_name ${DOMAIN}
        }
    }

    @xhttp path ${XHTTP_PATH}*
    reverse_proxy @xhttp 127.0.0.1:${XHTTP_PORT} {
        flush_interval -1
    }

    root * ${WEBROOT}
    file_server
}

http://${DOMAIN}:80 {
    redir https://${DOMAIN}{uri} permanent
}
CADDY
caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1 || true
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl reload caddy

echo '[10/13] Включаю HTTPS на панели 3x-ui'
/usr/local/x-ui/x-ui setting -webCert "/etc/caddy/certs/${DOMAIN}/fullchain.pem" -webCertKey "/etc/caddy/certs/${DOMAIN}/privkey.pem"
systemctl restart x-ui
sleep 3

echo '[11/13] Устанавливаю hook продления сертификата'
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/3xui-happ-node.sh <<HOOK
#!/bin/sh
set -eu
DOMAIN='${DOMAIN}'
SRC="/etc/letsencrypt/live/\${DOMAIN}"
DST="/etc/caddy/certs/\${DOMAIN}"
install -d -o root -g caddy -m 0750 "\$DST"
install -o root -g caddy -m 0640 "\$SRC/fullchain.pem" "\$DST/fullchain.pem"
install -o root -g caddy -m 0640 "\$SRC/privkey.pem" "\$DST/privkey.pem"
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
systemctl restart x-ui
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/3xui-happ-node.sh

echo '[12/13] Проверяю сервисы и подписку'
systemctl is-active --quiet caddy
systemctl is-active --quiet x-ui
ss -lntup | grep -E ":(80|443|${PANEL_PORT}|${XHTTP_PORT}|${SUB_PORT})[[:space:]]" || true

SUB_URL="https://${DOMAIN}${SUB_PATH}${SUB_ID}"
curl -fsS -A 'Happ/1.0' --max-time 10 "$SUB_URL" -o /tmp/happ-sub.body
LINK_COUNT="$(python3 - <<'PY'
import base64
from pathlib import Path
raw=Path('/tmp/happ-sub.body').read_bytes().strip()
try:
    txt=base64.b64decode(raw).decode('utf-8','replace')
except Exception:
    txt=raw.decode('utf-8','replace')
print(sum(1 for x in txt.splitlines() if x.strip().startswith(('vless://','hysteria2://','hysteria://'))))
PY
)"
if [ "$LINK_COUNT" -lt 2 ]; then
  echo "[ОШИБКА] В подписке найдено подключений: $LINK_COUNT"
  exit 1
fi

echo '[13/13] ГОТОВО'
echo
printf 'Сайт:              https://%s/\n' "$DOMAIN"
printf 'Радио-админка:      https://%s/admin.html\n' "$DOMAIN"
printf '3x-ui панель:       https://%s:%s%s\n' "$DOMAIN" "$PANEL_PORT" "$PANEL_PATH"
printf 'Happ subscription:  %s\n' "$SUB_URL"
printf 'XHTTP:              %s:443 TCP, path %s\n' "$DOMAIN" "$XHTTP_PATH"
printf 'Hysteria2:          %s:443 UDP\n' "$DOMAIN"
echo
echo 'Панельные реквизиты сохраните сейчас:'
printf 'Username: %s\n' "$PANEL_USER"
printf 'Password: %s\n' "$PANEL_PASS"
echo
echo '[ВАЖНО] TCP/443 работает через Caddy только TLS 1.2; Hysteria2 использует QUIC/TLS 1.3.'
echo '[ВАЖНО] Панель пока слушает публичный порт. Ограничьте его firewall-ом после проверки.'

echo "#################### КОНЕЦ ВЫВОДА: ${TASK} ####################"
