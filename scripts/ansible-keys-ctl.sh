#!/usr/bin/env bash
# Управление ключами в защищённом каталоге (/var/lib/ansible-keys).
# Перемещать/читать приватные ключи может только владелец каталога.
#
# Примеры:
#   sudo -u ansible-keys ./scripts/ansible-keys-ctl.sh list
#   sudo ./scripts/ansible-keys-ctl.sh list              # сам переключится на владельца
#   sudo ./scripts/ansible-keys-ctl.sh show-pub
#   sudo ./scripts/ansible-keys-ctl.sh move-archive
#   sudo ./scripts/ansible-keys-ctl.sh move-archive --name id_ed25519

set -euo pipefail

KEY_DIR="${ANSIBLE_KEY_DIR:-/var/lib/ansible-keys}"
KEY_OWNER="${ANSIBLE_KEY_OWNER:-ansible-keys}"
CMD="${1:-}"
shift || true

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Использование:
  sudo -u $KEY_OWNER $0 list
  sudo -u $KEY_OWNER $0 show-pub
  sudo -u $KEY_OWNER $0 move-archive [--name id_ed25519]

Переменные окружения:
  ANSIBLE_KEY_DIR    (по умолчанию $KEY_DIR)
  ANSIBLE_KEY_OWNER  (по умолчанию $KEY_OWNER)
EOF
}

# Если запустили от root — переключиться на владельца ключей
reexec_as_owner() {
  if [[ "${EUID}" -eq 0 ]]; then
    exec sudo -u "$KEY_OWNER" -H env ANSIBLE_KEY_DIR="$KEY_DIR" ANSIBLE_KEY_OWNER="$KEY_OWNER" \
      "$0" "$CMD" "$@"
  fi
  local me
  me="$(id -un)"
  [[ "$me" == "$KEY_OWNER" ]] || die "нужен пользователь $KEY_OWNER (сейчас: $me). Пример: sudo -u $KEY_OWNER $0 $CMD"
}

[[ -n "$CMD" ]] || { usage; exit 1; }

case "$CMD" in
  -h|--help) usage; exit 0 ;;
esac

reexec_as_owner "$@"

[[ -d "$KEY_DIR" ]] || die "нет каталога $KEY_DIR — сначала: install-ansible-redos.sh --secure-keys"

case "$CMD" in
  list)
    echo "Каталог: $KEY_DIR (владелец $(stat -c '%U:%G %a' "$KEY_DIR" 2>/dev/null || echo '?'))"
    echo "--- содержимое ---"
    ls -la "$KEY_DIR"
    echo "--- archive ---"
    ls -la "$KEY_DIR/archive" 2>/dev/null || echo "(пусто)"
    ;;
  show-pub)
    PUB="${KEY_DIR}/id_ed25519.pub"
    [[ -f "$PUB" ]] || die "нет $PUB"
    cat "$PUB"
    ;;
  move-archive)
    NAME="id_ed25519"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) NAME="${2:-}"; shift 2 ;;
        *) die "неизвестный аргумент: $1" ;;
      esac
    done
    SRC="${KEY_DIR}/${NAME}"
    [[ -f "$SRC" ]] || die "нет файла $SRC"
    mkdir -p "${KEY_DIR}/archive"
    TS="$(date +%Y%m%d%H%M%S)"
    DEST="${KEY_DIR}/archive/${NAME}.${TS}"
    mv "$SRC" "$DEST"
    [[ -f "${SRC}.pub" ]] && mv "${SRC}.pub" "${KEY_DIR}/archive/${NAME}.pub.${TS}"
    echo "OK: перемещено → $DEST"
    ls -la "${KEY_DIR}/archive"
    ;;
  *)
    die "неизвестная команда: $CMD (list|show-pub|move-archive)"
    ;;
esac
