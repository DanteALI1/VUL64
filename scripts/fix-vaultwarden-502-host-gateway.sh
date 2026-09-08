#!/usr/bin/env bash
# Фикс 502 на РЕД ОС, когда Docker-сеть и host.docker.internal недоступны.
# nginx в режиме network_mode: host → proxy на http://127.0.0.1:BACKEND_PORT
#
#   sudo ./scripts/fix-vaultwarden-502-host-gateway.sh
#   sudo ./scripts/fix-vaultwarden-502-host-gateway.sh --https-port 8443 --backend-port 8787

set -euo pipefail

INSTALL_ROOT="/opt/vaultwarden"
BACKEND_PORT=8787
HTTP_PORT=""
HTTPS_PORT=""
FQDN=""

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/fix-vaultwarden-502-host-gateway.sh [опции]

Опции:
  --dir PATH           /opt/vaultwarden
  --backend-port N     Vaultwarden на 127.0.0.1 (по умолчанию 8787)
  --http-port N        HTTP на хосте (по умолчанию из compose или 8080)
  --https-port N       HTTPS на хосте (по умолчанию из compose или 8443)
  --fqdn NAME          server_name
  -h, --help
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
ok()  { printf '    OK: %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_ROOT="${2:-}"; shift 2 ;;
    --backend-port) BACKEND_PORT="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --https-port) HTTPS_PORT="${2:-}"; shift 2 ;;
    --fqdn) FQDN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "запустите через sudo"
[[ -d "$INSTALL_ROOT" ]] || die "нет ${INSTALL_ROOT}"
[[ -f "${INSTALL_ROOT}/docker-compose.yml" ]] || die "нет docker-compose.yml"
[[ -f "${INSTALL_ROOT}/ssl/fullchain.pem" && -f "${INSTALL_ROOT}/ssl/privkey.pem" ]] \
  || die "нет SSL в ${INSTALL_ROOT}/ssl/"

DOMAIN="$(grep -E '^\s*DOMAIN:' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
ADMIN_TOKEN="$(grep -E '^\s*ADMIN_TOKEN:' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
SIGNUPS="$(grep -E '^\s*SIGNUPS_ALLOWED:' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
IMAGE="$(grep -E 'image:\s*vaultwarden' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | awk '{print $2}' || true)"
[[ -n "$IMAGE" ]] || IMAGE="vaultwarden/server:latest"
[[ -n "$SIGNUPS" ]] || SIGNUPS="true"
[[ -n "$DOMAIN" ]] || DOMAIN="https://localhost"
[[ -n "$ADMIN_TOKEN" ]] || ADMIN_TOKEN=""

if [[ -z "$FQDN" && -f "${INSTALL_ROOT}/nginx/nginx.conf" ]]; then
  FQDN="$(grep -E '^\s*server_name' "${INSTALL_ROOT}/nginx/nginx.conf" | head -1 | awk '{print $2}' | tr -d ';' || true)"
fi
[[ -n "$FQDN" ]] || FQDN="vaultwarden.local"

if [[ -z "$HTTP_PORT" ]]; then
  HTTP_PORT="$(grep -E '\"[0-9]+:80\"' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*\"([0-9]+):80\".*/\1/' || true)"
fi
if [[ -z "$HTTPS_PORT" ]]; then
  HTTPS_PORT="$(grep -E '\"[0-9]+:443\"' "${INSTALL_ROOT}/docker-compose.yml" | head -1 | sed -E 's/.*\"([0-9]+):443\".*/\1/' || true)"
fi
# если раньше уже был host-network — порты могли быть только в nginx.conf
if [[ -z "$HTTP_PORT" && -f "${INSTALL_ROOT}/nginx/nginx.conf" ]]; then
  HTTP_PORT="$(grep -E 'listen[[:space:]]+[0-9]+;' "${INSTALL_ROOT}/nginx/nginx.conf" | grep -v ssl | head -1 | grep -oE '[0-9]+' | head -1 || true)"
fi
if [[ -z "$HTTPS_PORT" && -f "${INSTALL_ROOT}/nginx/nginx.conf" ]]; then
  HTTPS_PORT="$(grep -E 'listen[[:space:]]+[0-9]+[[:space:]]+ssl' "${INSTALL_ROOT}/nginx/nginx.conf" | head -1 | grep -oE '[0-9]+' | head -1 || true)"
fi
[[ -n "$HTTP_PORT" ]] || HTTP_PORT=8080
[[ -n "$HTTPS_PORT" ]] || HTTPS_PORT=8443

port_busy() {
  local p="$1"
  ss -tlnp 2>/dev/null | grep -qE ":${p}\\b" || return 1
  # игнорируем, если это наши контейнеры — мы их сейчас остановим
  return 0
}

log "Остановка стека"
cd "$INSTALL_ROOT"
docker compose down --remove-orphans 2>/dev/null || true
docker rm -f vaultwarden vaultwarden-nginx 2>/dev/null || true
sleep 1

log "Проверка портов ${HTTP_PORT}/${HTTPS_PORT}/${BACKEND_PORT}"
for p in "$HTTP_PORT" "$HTTPS_PORT" "$BACKEND_PORT"; do
  if ss -tlnp 2>/dev/null | grep -E ":${p}\\b" | grep -vq docker; then
    log "внимание: порт ${p} слушает кто-то ещё:"
    ss -tlnp 2>/dev/null | grep -E ":${p}\\b" || true
  fi
done

log "docker-compose: vaultwarden → 127.0.0.1:${BACKEND_PORT}, nginx → network_mode:host"
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
    network_mode: host
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/certs:ro
EOF

mkdir -p "${INSTALL_ROOT}/nginx"
log "nginx.conf: listen ${HTTP_PORT}/${HTTPS_PORT} → 127.0.0.1:${BACKEND_PORT}"
cat > "${INSTALL_ROOT}/nginx/nginx.conf" <<EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }
    server {
        listen ${HTTP_PORT};
        server_name ${FQDN};
        return 301 https://\$host:${HTTPS_PORT}\$request_uri;
    }
    server {
        listen ${HTTPS_PORT} ssl;
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
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            proxy_connect_timeout 5s;
            proxy_read_timeout 300s;
        }
    }
}
EOF

# firewalld: открыть HTTPS порт, если ещё не открыт
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp" 2>/dev/null || true
  firewall-cmd --permanent --add-port="${HTTPS_PORT}/tcp" 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
fi

log "Запуск"
docker compose up -d
sleep 5
docker compose ps

log "Проверки"
if ! curl -fsS "http://127.0.0.1:${BACKEND_PORT}/" >/dev/null 2>&1 && ! wget -qO- "http://127.0.0.1:${BACKEND_PORT}/" >/dev/null 2>&1; then
  docker compose logs --tail=40 vaultwarden || true
  die "Vaultwarden не отвечает на http://127.0.0.1:${BACKEND_PORT}/"
fi
ok "backend http://127.0.0.1:${BACKEND_PORT}/"

if curl -kfsS "https://127.0.0.1:${HTTPS_PORT}/" >/dev/null 2>&1 || wget --no-check-certificate -qO- "https://127.0.0.1:${HTTPS_PORT}/" >/dev/null 2>&1; then
  ok "HTTPS https://127.0.0.1:${HTTPS_PORT}/"
else
  docker compose logs --tail=40 nginx || true
  # показать, слушает ли порт
  ss -tlnp | grep -E ":${HTTPS_PORT}\\b" || true
  die "nginx на :${HTTPS_PORT} не отдаёт страницу"
fi

cat <<EOF

Готово.
  Backend:  http://127.0.0.1:${BACKEND_PORT}/
  UI:       https://${FQDN}:${HTTPS_PORT}/
            https://<IP_СЕРВЕРА>:${HTTPS_PORT}/

Схема: браузер → nginx (host network :${HTTPS_PORT}) → 127.0.0.1:${BACKEND_PORT} → vaultwarden
EOF
