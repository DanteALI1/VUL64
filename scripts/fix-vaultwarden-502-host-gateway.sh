#!/usr/bin/env bash
# Быстрый фикс 502 / Host is unreachable на РЕД ОС:
# nginx ходит в Vaultwarden через 127.0.0.1 (host.docker.internal),
# а не по Docker-сети 172.18.0.x (её часто режет firewalld).
#
#   sudo ./scripts/fix-vaultwarden-502-host-gateway.sh
#   sudo ./scripts/fix-vaultwarden-502-host-gateway.sh --dir /opt/vaultwarden --backend-port 8787

set -euo pipefail

INSTALL_ROOT="/opt/vaultwarden"
BACKEND_PORT=8787
FQDN=""

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/fix-vaultwarden-502-host-gateway.sh [опции]

Опции:
  --dir PATH           каталог установки (по умолчанию /opt/vaultwarden)
  --backend-port N     локальный порт Vaultwarden (по умолчанию 8787)
  --fqdn NAME          server_name в nginx (если не задан — берётся из текущего nginx.conf)
  -h, --help
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_ROOT="${2:-}"; shift 2 ;;
    --backend-port) BACKEND_PORT="${2:-}"; shift 2 ;;
    --fqdn) FQDN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "запустите через sudo"
[[ -d "$INSTALL_ROOT" ]] || die "нет каталога ${INSTALL_ROOT}"
[[ -f "${INSTALL_ROOT}/docker-compose.yml" ]] || die "нет docker-compose.yml"
command -v docker >/dev/null || die "нужен docker"

# сохранить DOMAIN и ADMIN_TOKEN из текущего compose
DOMAIN="$(grep -E '^\s*DOMAIN:' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
ADMIN_TOKEN="$(grep -E '^\s*ADMIN_TOKEN:' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
SIGNUPS="$(grep -E '^\s*SIGNUPS_ALLOWED:' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
IMAGE="$(grep -E '^\s*image:' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | awk '{print $2}' || true)"
[[ -n "$IMAGE" ]] || IMAGE="vaultwarden/server:latest"
[[ -n "$SIGNUPS" ]] || SIGNUPS="true"
[[ -n "$DOMAIN" ]] || DOMAIN="https://localhost"
[[ -n "$ADMIN_TOKEN" ]] || ADMIN_TOKEN=""

if [[ -z "$FQDN" && -f "${INSTALL_ROOT}/nginx/nginx.conf" ]]; then
  FQDN="$(grep -E '^\s*server_name' "${INSTALL_ROOT}/nginx/nginx.conf" | head -1 | awk '{print $2}' | tr -d ';' || true)"
fi
[[ -n "$FQDN" ]] || FQDN="vaultwarden.local"

# порты с хоста из текущего compose (если есть)
HTTP_PORT="$(grep -E '^\s*-\s*\"[0-9]+:80\"' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*\"([0-9]+):80\".*/\1/' || true)"
HTTPS_PORT="$(grep -E '^\s*-\s*\"[0-9]+:443\"' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*\"([0-9]+):443\".*/\1/' || true)"
[[ -n "$HTTP_PORT" ]] || HTTP_PORT=8080
[[ -n "$HTTPS_PORT" ]] || HTTPS_PORT=8443

log "Остановка текущего стека"
cd "$INSTALL_ROOT"
docker compose down --remove-orphans 2>/dev/null || true
docker rm -f vaultwarden vaultwarden-nginx 2>/dev/null || true

log "Запись нового docker-compose.yml (backend 127.0.0.1:${BACKEND_PORT})"
cat > "${INSTALL_ROOT}/docker-compose.yml" <<EOF
services:
  vaultwarden:
    image: ${IMAGE}
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "${DOMAIN}"
      SIGNUPS_ALLOWED: "${SIGNUPS}"
      ADMIN_TOKEN: "${ADMIN_TOKEN}"
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:${BACKEND_PORT}:80"

  nginx:
    image: nginx:alpine
    container_name: vaultwarden-nginx
    restart: unless-stopped
    depends_on:
      - vaultwarden
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/certs:ro
EOF

mkdir -p "${INSTALL_ROOT}/nginx" "${INSTALL_ROOT}/ssl"
[[ -f "${INSTALL_ROOT}/ssl/fullchain.pem" && -f "${INSTALL_ROOT}/ssl/privkey.pem" ]] \
  || die "нет SSL в ${INSTALL_ROOT}/ssl (fullchain.pem / privkey.pem)"

log "Запись nginx.conf → host.docker.internal:${BACKEND_PORT}"
cat > "${INSTALL_ROOT}/nginx/nginx.conf" <<EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    resolver 127.0.0.11 valid=10s ipv6=off;
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
            set \$vw_upstream host.docker.internal;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_pass http://\$vw_upstream:${BACKEND_PORT};
            proxy_connect_timeout 5s;
            proxy_read_timeout 300s;
        }
    }
}
EOF

log "Запуск"
docker compose up -d
sleep 4
docker compose ps

log "Проверка backend"
if curl -fsS "http://127.0.0.1:${BACKEND_PORT}/" >/dev/null 2>&1 || wget -qO- "http://127.0.0.1:${BACKEND_PORT}/" >/dev/null 2>&1; then
  printf '    OK: http://127.0.0.1:%s/\n' "$BACKEND_PORT"
else
  docker compose logs --tail=30 vaultwarden || true
  die "Vaultwarden не отвечает на 127.0.0.1:${BACKEND_PORT}"
fi

if docker exec vaultwarden-nginx wget -qO- "http://host.docker.internal:${BACKEND_PORT}/" >/dev/null 2>&1; then
  printf '    OK: nginx → host.docker.internal:%s\n' "$BACKEND_PORT"
else
  die "nginx всё ещё не видит backend (host.docker.internal:${BACKEND_PORT})"
fi

cat <<EOF

Готово. Откройте: ${DOMAIN}/
(или https://IP:${HTTPS_PORT}/)

Схема: браузер → nginx :${HTTPS_PORT} → 127.0.0.1:${BACKEND_PORT} → vaultwarden
EOF
