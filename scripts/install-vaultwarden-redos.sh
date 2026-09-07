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
#   sudo ./scripts/install-vaultwarden-redos.sh --fqdn vault.lan --ip 10.0.0.5 --cert-mode selfsigned

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_SCRIPT="${SCRIPT_DIR}/create-vaultwarden-ssl-cert.sh"
ADMIN_TOKEN=""
ADMIN_TOKEN_FILE=""

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/install-vaultwarden-redos.sh --fqdn <имя> [--ip <IP>] [опции]

Обязательно:
  --fqdn NAME                 DNS-имя (для DOMAIN и сертификата)

Рекомендуется:
  --ip ADDR                   IP сервера (SAN, hosts, удобный URL)

Опции:
  --access https|http         https = nginx :443 + TLS (по умолчанию)
                              http  = только порт 80 (LAN)
  --cert-mode ca|selfsigned   тип сертификата при https
  --org NAME                  организация в DN сертификата
  --dir PATH                  каталог установки (по умолчанию /opt/vaultwarden)
  --image IMAGE               образ (по умолчанию vaultwarden/server:latest)
  --admin-token TOKEN         задать ADMIN_TOKEN явно
  --force                     перезаписать compose/nginx и пересоздать cert
  -h, --help

Что делает скрипт:
  1) ставит Docker Engine + Compose plugin (если нет)
  2) создаёт /opt/vaultwarden/{data,ssl,nginx}
  3) генерирует ADMIN_TOKEN
  4) при https — создаёт SSL и конфиг nginx
  5) пишет docker-compose.yml, открывает firewall, запускает стек
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
    --cert-mode) CERT_MODE="${2:-}"; shift 2 ;;
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
  [[ -x "$CERT_SCRIPT" ]] || die "нет ${CERT_SCRIPT}"
  local args=(--fqdn "$FQDN" --mode "$CERT_MODE" --org "$ORG" --install-dir "${INSTALL_ROOT}/ssl")
  [[ -n "$IP" ]] && args+=(--ip "$IP")
  [[ "$FORCE" -eq 1 ]] && args+=(--force)
  "$CERT_SCRIPT" "${args[@]}"
  [[ -f "${INSTALL_ROOT}/ssl/fullchain.pem" && -f "${INSTALL_ROOT}/ssl/privkey.pem" ]] \
    || die "сертификаты не созданы"
  ok "ssl/fullchain.pem + privkey.pem"
}

write_http_compose() {
  local domain="http://${FQDN}"
  [[ -n "$IP" ]] && domain="http://${IP}"

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
      - "80:80"
EOF
}

write_https_stack() {
  local domain="https://${FQDN}"

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
      - "80:80"
      - "443:443"
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
    ok "конфиги записаны"
  fi
}

setup_firewall() {
  log "6/7 Firewall"
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    ok "firewalld нет — пропуск"
    return
  fi
  systemctl enable --now firewalld 2>/dev/null || true
  firewall-cmd --permanent --add-service=http || true
  [[ "$ACCESS" == "https" ]] && firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
  ok "правила применены"
}

start_stack() {
  log "7/7 Запуск контейнеров"
  cd "$INSTALL_ROOT"
  docker compose pull
  docker compose up -d
  sleep 2
  docker compose ps
  ok "стек запущен"
}

print_summary() {
  local url
  if [[ "$ACCESS" == "http" ]]; then
    url="http://${IP:-$FQDN}"
  else
    url="https://${FQDN}"
  fi

  cat <<EOF

========================================
  Vaultwarden установлен
========================================
  Проект:   https://github.com/dani-garcia/vaultwarden
  Каталог:  ${INSTALL_ROOT}
  Данные:   ${INSTALL_ROOT}/data   (SQLite внутри)
  Доступ:   ${ACCESS}
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
  start_stack
  print_summary
}

main
