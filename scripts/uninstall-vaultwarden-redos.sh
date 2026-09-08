#!/usr/bin/env bash
# Полное удаление Vaultwarden с РЕД ОС (Docker Compose).
# Останавливает контейнеры, удаляет сеть/тома compose, каталог /opt/vaultwarden,
# опционально — образы Docker, рабочие certs, правила firewall.
#
# Примеры:
#   sudo ./scripts/uninstall-vaultwarden-redos.sh --yes
#   sudo ./scripts/uninstall-vaultwarden-redos.sh --yes --keep-data
#   sudo ./scripts/uninstall-vaultwarden-redos.sh --yes --remove-images --purge-certs

set -euo pipefail

INSTALL_ROOT="/opt/vaultwarden"
YES=0
KEEP_DATA=0
REMOVE_IMAGES=0
PURGE_CERTS=0
PURGE_FIREWALL=1
HTTP_PORT=""
HTTPS_PORT=""

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/uninstall-vaultwarden-redos.sh --yes [опции]

Обязательно для реального удаления:
  --yes                         подтвердить удаление (без этого — только план)

Опции:
  --dir PATH                    каталог установки (по умолчанию /opt/vaultwarden)
  --keep-data                   не удалять ./data (бэкап паролей SQLite)
  --remove-images               удалить образы vaultwarden/server и nginx:alpine
  --purge-certs                 удалить ~/vaultwarden-certs у root и SUDO_USER
  --no-firewall                 не трогать правила firewalld
  --http-port N                 закрыть порт HTTP в firewalld (если открывали вручную)
  --https-port N                закрыть порт HTTPS в firewalld (по умолчанию 8443, если был)
  -h, --help

Что удаляется по умолчанию (--yes):
  1) docker compose down (контейнеры vaultwarden + nginx)
  2) сеть compose (vwnet)
  3) каталог /opt/vaultwarden целиком (если нет --keep-data — вместе с data)
  4) попытка убрать порты 8080/8443 из firewalld (и указанные --http-port/--https-port)

НЕ удаляет:
  - Docker Engine
  - HashiCorp Vault (это другой стек)
EOF
}

log() { printf '\n==> %s\n' "$*"; }
ok()  { printf '    OK: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --dir) INSTALL_ROOT="${2:-}"; shift 2 ;;
    --keep-data) KEEP_DATA=1; shift ;;
    --remove-images) REMOVE_IMAGES=1; shift ;;
    --purge-certs) PURGE_CERTS=1; shift ;;
    --no-firewall) PURGE_FIREWALL=0; shift ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --https-port) HTTPS_PORT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "запустите через sudo"

print_plan() {
  cat <<EOF
План удаления Vaultwarden
  Каталог:        ${INSTALL_ROOT}
  Данные data/:   $([ "$KEEP_DATA" -eq 1 ] && echo 'СОХРАНИТЬ' || echo 'УДАЛИТЬ')
  Образы Docker:  $([ "$REMOVE_IMAGES" -eq 1 ] && echo 'удалить' || echo 'оставить')
  Certs ~/…:      $([ "$PURGE_CERTS" -eq 1 ] && echo 'удалить' || echo 'оставить')
  Firewall:       $([ "$PURGE_FIREWALL" -eq 1 ] && echo 'почистить порты' || echo 'не трогать')
EOF
}

stop_compose() {
  log "1/5 Остановка Docker Compose"
  if [[ -f "${INSTALL_ROOT}/docker-compose.yml" ]]; then
    (
      cd "$INSTALL_ROOT"
      docker compose down --remove-orphans 2>/dev/null || true
      # на всякий случай именованные контейнеры
      docker rm -f vaultwarden vaultwarden-nginx 2>/dev/null || true
    )
    ok "контейнеры остановлены"
  else
    docker rm -f vaultwarden vaultwarden-nginx 2>/dev/null || true
    ok "compose-файл не найден — сняты контейнеры по имени (если были)"
  fi

  # сеть compose
  docker network rm vaultwarden_vwnet 2>/dev/null || true
  docker network ls --format '{{.Name}}' | grep -E 'vaultwarden.*vwnet|vwnet' | while read -r n; do
    docker network rm "$n" 2>/dev/null || true
  done || true
}

backup_keep_data() {
  if [[ "$KEEP_DATA" -ne 1 ]]; then
    return
  fi
  if [[ -d "${INSTALL_ROOT}/data" ]]; then
    local bak="/root/vaultwarden-data-backup-$(date +%F-%H%M%S).tgz"
    log "Сохранение data → ${bak}"
    tar czf "$bak" -C "$INSTALL_ROOT" data
    chmod 600 "$bak"
    ok "бэкап: ${bak}"
  fi
}

remove_dir() {
  log "2/5 Удаление каталога ${INSTALL_ROOT}"
  if [[ ! -e "$INSTALL_ROOT" ]]; then
    ok "каталога нет"
    return
  fi
  if [[ "$KEEP_DATA" -eq 1 && -d "${INSTALL_ROOT}/data" ]]; then
    local tmp
    tmp="$(mktemp -d /tmp/vw-data-keep.XXXXXX)"
    mv "${INSTALL_ROOT}/data" "$tmp/data"
    rm -rf "$INSTALL_ROOT"
    mkdir -p "${INSTALL_ROOT}"
    mv "$tmp/data" "${INSTALL_ROOT}/data"
    rm -rf "$tmp"
    ok "удалено всё, кроме ${INSTALL_ROOT}/data"
  else
    rm -rf "$INSTALL_ROOT"
    ok "каталог удалён"
  fi
}

remove_images() {
  [[ "$REMOVE_IMAGES" -eq 1 ]] || return 0
  log "3/5 Удаление образов Docker"
  docker image rm -f vaultwarden/server:latest 2>/dev/null || true
  docker image rm -f nginx:alpine 2>/dev/null || true
  # любые теги vaultwarden/server
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^vaultwarden/server:' | while read -r img; do
    docker image rm -f "$img" 2>/dev/null || true
  done || true
  ok "образы удалены (если были)"
}

purge_certs() {
  [[ "$PURGE_CERTS" -eq 1 ]] || return 0
  log "4/5 Удаление рабочих сертификатов"
  rm -rf /root/vaultwarden-certs
  if [[ -n "${SUDO_USER:-}" ]]; then
    local home
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$home" ]] && rm -rf "${home}/vaultwarden-certs"
  fi
  # якоря trust, если ставили скриптом
  rm -f /etc/pki/ca-trust/source/anchors/vaultwarden-ca.crt \
        /etc/pki/ca-trust/source/anchors/vaultwarden.crt 2>/dev/null || true
  if command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust extract || true
  fi
  ok "certs очищены"
}

purge_firewall() {
  [[ "$PURGE_FIREWALL" -eq 1 ]] || return 0
  log "5/5 Firewalld: убрать порты Vaultwarden"
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    ok "firewalld нет"
    return
  fi
  # порты по умолчанию из установщика + явно указанные
  local ports=("8080" "8443")
  [[ -n "$HTTP_PORT" ]] && ports+=("$HTTP_PORT")
  [[ -n "$HTTPS_PORT" ]] && ports+=("$HTTPS_PORT")
  local p
  for p in "${ports[@]}"; do
    firewall-cmd --permanent --remove-port="${p}/tcp" 2>/dev/null || true
  done
  firewall-cmd --reload 2>/dev/null || true
  ok "попытка убрать 8080/8443 (и указанные порты) выполнена"
  log "Правила docker0/trusted не откатываем (могут нужны другим контейнерам)"
}

main() {
  print_plan
  if [[ "$YES" -ne 1 ]]; then
    cat <<EOF

Это был только план. Для удаления запустите снова с --yes, например:
  sudo $0 --yes
  sudo $0 --yes --keep-data
  sudo $0 --yes --remove-images --purge-certs
EOF
    exit 0
  fi

  stop_compose
  backup_keep_data
  remove_dir
  remove_images
  purge_certs
  purge_firewall

  cat <<EOF

========================================
  Vaultwarden удалён
========================================
  Каталог:   ${INSTALL_ROOT} $([ -d "${INSTALL_ROOT}/data" ] && echo '(остался data/)' || echo '(нет)')
  Docker:    Engine оставлен
  Vault:     HashiCorp Vault не трогали

  Проверка:
    docker ps -a | grep -i vaultwarden || echo 'контейнеров нет'
    ls -la ${INSTALL_ROOT} 2>/dev/null || echo 'каталога нет'

  Документация: docs/vaultwarden-uninstall-redos.md
========================================
EOF
}

main
