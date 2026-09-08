#!/usr/bin/env bash
# Полная установка Vaultwarden на РЕД ОС (Docker Compose) — от и до:
#   Docker → каталоги → SSL (HTTPS) → compose/nginx → firewall → запуск
#
# Официальный проект: https://github.com/dani-garcia/vaultwarden
# Образ: vaultwarden/server:latest
#
# Примеры:
#   sudo ./scripts/install-vaultwarden-redos.sh --fqdn vault.example.local --ip 192.168.1.50
#   sudo ./scripts/install-vaultwarden-redos.sh --fqdn vault.lan --ip 10.0.0.5 --access http
#   # порты по умолчанию 8080/8443 (чтобы не конфликтовать с Vault на 80/443)
#   # вернуть классические: --http-port 80 --https-port 443

set -euo pipefail

FQDN=""
IP=""
ACCESS="https"          # https | http
CERT_MODE="ca"          # ca | selfsigned
ORG="MyOrg"
FORCE=0
INSTALL_ROOT="/opt/vaultwarden"
IMAGE="vaultwarden/server:latest"
SIGNUPS_ALLOWED="true"
HTTP_PORT=8080          # не 80 — часто занят nginx HashiCorp Vault
HTTPS_PORT=8443         # не 443 — то же
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_SCRIPT="${SCRIPT_DIR}/create-vaultwarden-ssl-cert.sh"
ADMIN_TOKEN=""
ADMIN_TOKEN_FILE=""
CERT_FILE=""            # готовый сертификат / fullchain от УЦ
KEY_FILE=""             # готовый ключ от УЦ
CHAIN_FILE=""           # опциональная цепочка CA

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/install-vaultwarden-redos.sh --fqdn <имя> [--ip <IP>] [опции]

Обязательно:
  --fqdn NAME                 DNS-имя (для DOMAIN и сертификата)

Рекомендуется:
  --ip ADDR                   IP сервера (SAN, hosts, удобный URL)

Опции:
  --access https|http         https = nginx + TLS (по умолчанию)
                              http  = только HTTP-порт (LAN)
  --http-port N               хост-порт HTTP (по умолчанию 8080)
  --https-port N              хост-порт HTTPS (по умолчанию 8443)
  --cert-mode ca|selfsigned   самоподписанный cert (если нет своих файлов)
  --cert-file PATH            готовый сертификат/fullchain от УЦ
  --key-file PATH             готовый ключ от УЦ
  --chain-file PATH           CA-bundle (если cert без цепочки)
  --org NAME                  организация в DN самоподписанного cert
  --dir PATH                  каталог установки (по умолчанию /opt/vaultwarden)
  --image IMAGE               образ (по умолчанию vaultwarden/server:latest)
  --admin-token TOKEN         задать ADMIN_TOKEN явно
  --force                     перезаписать compose/nginx и SSL
  -h, --help

По умолчанию UI: https://<fqdn>:8443/

Свои сертификаты от УЦ:
  sudo ./scripts/install-vaultwarden-redos.sh --fqdn vault.company.ru --ip 192.168.1.57 \
    --cert-file /path/server.crt --key-file /path/server.key \
    --chain-file /path/ca-bundle.crt --force

Только положить готовые cert в /opt/vaultwarden/ssl:
  sudo ./scripts/install-existing-ssl-cert.sh --target vaultwarden \
    --cert /path/server.crt --key /path/server.key --chain /path/ca-bundle.crt --restart
EOF
}

log() { printf '\n==> %s\n' "$*"; }
ok()  { printf '    OK: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fqdn) FQDN="${2:-}"; shift 2 ;;
    --ip) IP="${2:-}"; shift 2 ;;
    --access) ACCESS="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --https-port) HTTPS_PORT="${2:-}"; shift 2 ;;
    --cert-mode) CERT_MODE="${2:-}"; shift 2 ;;
    --cert-file) CERT_FILE="${2:-}"; shift 2 ;;
    --key-file) KEY_FILE="${2:-}"; shift 2 ;;
    --chain-file) CHAIN_FILE="${2:-}"; shift 2 ;;
    --org) ORG="${2:-}"; shift 2 ;;
    --dir) INSTALL_ROOT="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --admin-token) ADMIN_TOKEN="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "запустите через sudo"
[[ -n "$FQDN" ]] || die "укажите --fqdn"
case "$ACCESS" in https|http) ;; *) die "--access: https|http" ;; esac
case "$CERT_MODE" in ca|selfsigned) ;; *) die "--cert-mode: ca|selfsigned" ;; esac
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || die "--http-port должен быть числом"
[[ "$HTTPS_PORT" =~ ^[0-9]+$ ]] || die "--https-port должен быть числом"

http_url() {
  local host="${IP:-$FQDN}"
  if [[ "$HTTP_PORT" == "80" ]]; then
    printf 'http://%s' "$host"
  else
    printf 'http://%s:%s' "$host" "$HTTP_PORT"
  fi
}

https_url() {
  if [[ "$HTTPS_PORT" == "443" ]]; then
    printf 'https://%s' "$FQDN"
  else
    printf 'https://%s:%s' "$FQDN" "$HTTPS_PORT"
  fi
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -qE ":${port}\\b" && return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  return 1
}

who_holds_port() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -E ":${port}\\b" || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
  fi
}

check_ports() {
  log "Проверка портов"
  local conflict=0
  if port_in_use "$HTTP_PORT"; then
    printf 'ERROR: порт %s уже занят:\n' "$HTTP_PORT" >&2
    who_holds_port "$HTTP_PORT" >&2
    conflict=1
  fi
  if [[ "$ACCESS" == "https" ]] && port_in_use "$HTTPS_PORT"; then
    printf 'ERROR: порт %s уже занят:\n' "$HTTPS_PORT" >&2
    who_holds_port "$HTTPS_PORT" >&2
    conflict=1
  fi
  if [[ "$conflict" -eq 1 ]]; then
    cat >&2 <<EOF

Порты заняты (часто это nginx от HashiCorp Vault на :80/:443).

Варианты:
  1) Остановить конфликтующий сервис, например:
       systemctl stop nginx
  2) Выбрать свободные порты:
       sudo $0 --fqdn ${FQDN} ${IP:+--ip $IP} \\
         --http-port 9080 --https-port 9443 --force
EOF
    exit 1
  fi
  ok "порты свободны (http=${HTTP_PORT}$([[ "$ACCESS" == https ]] && printf ', https=%s' "$HTTPS_PORT"))"
}

pkg_install() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  else
    die "нужен dnf/yum"
  fi
}

install_docker() {
  log "1/7 Docker"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "$(docker --version); $(docker compose version)"
    systemctl enable --now docker 2>/dev/null || true
    return
  fi
  pkg_install dnf-plugins-core || true
  if command -v dnf >/dev/null 2>&1; then
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null || \
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
  fi
  pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin || \
    die "не удалось установить Docker. Поставьте вручную: docker-ce + docker-compose-plugin"
  systemctl enable --now docker
  ok "$(docker --version)"
}

prepare_dirs() {
  log "2/7 Каталоги ${INSTALL_ROOT}"
  mkdir -p "$INSTALL_ROOT"/{data,ssl,nginx}
  chmod 755 "$INSTALL_ROOT"
  ok "data, ssl, nginx"
}

make_admin_token() {
  log "3/7 ADMIN_TOKEN"
  if [[ -z "$ADMIN_TOKEN" ]]; then
    if [[ -f "${INSTALL_ROOT}/admin-token.txt" && "$FORCE" -ne 1 ]]; then
      ADMIN_TOKEN="$(tr -d '\n' < "${INSTALL_ROOT}/admin-token.txt")"
      ADMIN_TOKEN_FILE="${INSTALL_ROOT}/admin-token.txt"
      ok "использован существующий ${ADMIN_TOKEN_FILE}"
      return
    fi
    command -v openssl >/dev/null || pkg_install openssl
    ADMIN_TOKEN="$(openssl rand -base64 48)"
  fi
  ADMIN_TOKEN_FILE="${INSTALL_ROOT}/admin-token.txt"
  umask 077
  printf '%s\n' "$ADMIN_TOKEN" > "$ADMIN_TOKEN_FILE"
  chmod 600 "$ADMIN_TOKEN_FILE"
  ok "сохранён в ${ADMIN_TOKEN_FILE}"
}

setup_certs() {
  if [[ "$ACCESS" != "https" ]]; then
    log "4/7 SSL пропущен (--access http)"
    return
  fi
  log "4/7 SSL-сертификаты"

  # Готовые сертификаты от УЦ
  if [[ -n "$CERT_FILE" || -n "$KEY_FILE" ]]; then
    [[ -n "$CERT_FILE" && -n "$KEY_FILE" ]] || die "нужны оба: --cert-file и --key-file"
    local existing="${SCRIPT_DIR}/install-existing-ssl-cert.sh"
    [[ -x "$existing" ]] || die "нет ${existing}"
    local args=(--target vaultwarden --cert "$CERT_FILE" --key "$KEY_FILE" --vw-dir "${INSTALL_ROOT}/ssl")
    [[ -n "$CHAIN_FILE" ]] && args+=(--chain "$CHAIN_FILE")
    [[ "$FORCE" -eq 1 ]] && args+=(--force)
    "$existing" "${args[@]}"
    ok "установлены ваши сертификаты от УЦ"
    return
  fi

  [[ -x "$CERT_SCRIPT" ]] || die "нет ${CERT_SCRIPT}"
  if [[ -f "${INSTALL_ROOT}/ssl/fullchain.pem" && -f "${INSTALL_ROOT}/ssl/privkey.pem" && "$FORCE" -ne 1 ]]; then
    ok "сертификаты уже есть (перевыпуск: --force или --cert-file/--key-file)"
    return
  fi
  local args=(--fqdn "$FQDN" --mode "$CERT_MODE" --org "$ORG" --install-dir "${INSTALL_ROOT}/ssl")
  [[ -n "$IP" ]] && args+=(--ip "$IP")
  [[ "$FORCE" -eq 1 ]] && args+=(--force)
  "$CERT_SCRIPT" "${args[@]}"
  [[ -f "${INSTALL_ROOT}/ssl/fullchain.pem" && -f "${INSTALL_ROOT}/ssl/privkey.pem" ]] \
    || die "сертификаты не созданы"
  ok "ssl/fullchain.pem + privkey.pem"
}

write_http_compose() {
  local domain
  domain="$(http_url)"

  cat > "${INSTALL_ROOT}/docker-compose.yml" <<EOF
services:
  vaultwarden:
    image: ${IMAGE}
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "${domain}"
      SIGNUPS_ALLOWED: "${SIGNUPS_ALLOWED}"
      ADMIN_TOKEN: "${ADMIN_TOKEN}"
    volumes:
      - ./data:/data
    ports:
      - "${HTTP_PORT}:80"
EOF
}

write_https_stack() {
  local domain
  domain="$(https_url)"

  # Внутри контейнера nginx всегда слушает 80/443; на хост маппятся HTTP_PORT/HTTPS_PORT
  cat > "${INSTALL_ROOT}/nginx/nginx.conf" <<EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }
    server {
        listen 80;
        server_name ${FQDN};
        return 301 https://\$host\$request_uri;
    }
    server {
        listen 443 ssl;
        http2 on;
        server_name ${FQDN};
        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        client_max_body_size 128M;
        location / {
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_pass http://vaultwarden:80;
        }
    }
}
EOF

  cat > "${INSTALL_ROOT}/docker-compose.yml" <<EOF
services:
  vaultwarden:
    image: ${IMAGE}
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "${domain}"
      SIGNUPS_ALLOWED: "${SIGNUPS_ALLOWED}"
      ADMIN_TOKEN: "${ADMIN_TOKEN}"
    volumes:
      - ./data:/data
    networks:
      - vwnet

  nginx:
    image: nginx:alpine
    container_name: vaultwarden-nginx
    restart: unless-stopped
    depends_on:
      - vaultwarden
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/certs:ro
    networks:
      - vwnet

networks:
  vwnet:
EOF
}

write_configs() {
  log "5/7 docker-compose / nginx"
  if [[ -f "${INSTALL_ROOT}/docker-compose.yml" && "$FORCE" -ne 1 ]]; then
    ok "compose уже есть (перезапись: --force)"
  else
    if [[ "$ACCESS" == "http" ]]; then
      write_http_compose
    else
      write_https_stack
    fi
    ok "конфиги записаны (host ports http=${HTTP_PORT}$([[ "$ACCESS" == https ]] && printf ' https=%s' "$HTTPS_PORT"))"
  fi
}

setup_firewall() {
  log "6/7 Firewall"
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    ok "firewalld нет — пропуск"
    return
  fi
  systemctl enable --now firewalld 2>/dev/null || true
  if [[ "$HTTP_PORT" == "80" ]]; then
    firewall-cmd --permanent --add-service=http || true
  else
    firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp" || true
  fi
  if [[ "$ACCESS" == "https" ]]; then
    if [[ "$HTTPS_PORT" == "443" ]]; then
      firewall-cmd --permanent --add-service=https || true
    else
      firewall-cmd --permanent --add-port="${HTTPS_PORT}/tcp" || true
    fi
  fi
  firewall-cmd --reload || true
  ok "правила применены"
}

start_stack() {
  log "7/7 Запуск контейнеров"
  cd "$INSTALL_ROOT"
  # убрать полузапущенный стек от прошлой попытки
  docker compose down 2>/dev/null || true
  docker compose pull
  docker compose up -d
  sleep 2
  docker compose ps
  ok "стек запущен"
}

print_summary() {
  local url
  if [[ "$ACCESS" == "http" ]]; then
    url="$(http_url)"
  else
    url="$(https_url)"
  fi

  cat <<EOF

========================================
  Vaultwarden установлен
========================================
  Проект:   https://github.com/dani-garcia/vaultwarden
  Каталог:  ${INSTALL_ROOT}
  Данные:   ${INSTALL_ROOT}/data   (SQLite внутри)
  Доступ:   ${ACCESS}
  Порты:    HTTP ${HTTP_PORT}$([[ "$ACCESS" == https ]] && printf ' / HTTPS %s' "$HTTPS_PORT")
  UI:       ${url}/
  Admin:    ${url}/admin
  Token:    ${ADMIN_TOKEN_FILE}

  Дальше:
    1) откройте ${url}/   (без двойных слэшей //)
    2) создайте аккаунт
    3) отключите регистрации — в docker-compose.yml:
         SIGNUPS_ALLOWED: "false"
       затем: cd ${INSTALL_ROOT} && docker compose up -d
    4) в клиенте Bitwarden укажите сервер: ${url}

  Команды:
    cd ${INSTALL_ROOT} && docker compose ps
    docker compose logs -f
    docker compose pull && docker compose up -d

  Документация: docs/vaultwarden-redos-docker.md
========================================
EOF
}

main() {
  install_docker
  prepare_dirs
  make_admin_token
  setup_certs
  write_configs
  setup_firewall
  check_ports
  start_stack
  print_summary
}

main
