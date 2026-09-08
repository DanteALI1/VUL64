#!/usr/bin/env bash
# Подготовка ОДНОГО managed node под схему svcsec:
#   - пользователь svcsec
#   - ~/.ssh
#   - ограниченный sudoers (noshell | allowlist)
#   - опционально: добавить публичный ключ оператора в authorized_keys
#
# Запускать на узле от root (или скопировать и выполнить по SSH).
# Документация: docs/ansible-svcsec-svcsecadmin.md
#
# Примеры:
#   sudo ./scripts/deploy-svcsec-node.sh --mode noshell
#   sudo ./scripts/deploy-svcsec-node.sh --mode allowlist --pubkey /tmp/svcsecadmin.pub
#   sudo ./scripts/deploy-svcsec-node.sh --mode noshell --remove-old-sudoers

set -euo pipefail

MODE="noshell"          # noshell | allowlist
PUBKEY=""
REMOVE_OLD=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUDOERS_SRC=""

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/deploy-svcsec-node.sh [--mode noshell|allowlist] [--pubkey FILE] [--remove-old-sudoers]

  --mode noshell|allowlist   шаблон sudoers (по умолчанию noshell)
  --pubkey FILE              добавить этот .pub в /home/svcsec/.ssh/authorized_keys
  --remove-old-sudoers       удалить другие файлы sudoers.d, где упоминается svcsec ALL
  -h, --help                 справка
EOF
}

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    OK: %s\n' "$*"; }
hint() { printf '    💡 %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "запустите через sudo/root"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --pubkey) PUBKEY="${2:-}"; shift 2 ;;
    --remove-old-sudoers) REMOVE_OLD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

case "$MODE" in
  noshell) SUDOERS_SRC="${SCRIPT_DIR}/sudoers/svcsec-noshell" ;;
  allowlist) SUDOERS_SRC="${SCRIPT_DIR}/sudoers/svcsec-allowlist" ;;
  *) die "--mode: noshell|allowlist" ;;
esac
[[ -f "$SUDOERS_SRC" ]] || die "нет шаблона: $SUDOERS_SRC"

log "1/5 Пользователь svcsec"
if id svcsec >/dev/null 2>&1; then
  ok "уже существует"
else
  useradd -m -s /bin/bash -c "Ansible managed account" svcsec
  passwd -l svcsec >/dev/null || true
  ok "создан svcsec (пароль заблокирован)"
fi

log "2/5 Каталог SSH"
install -d -m 700 -o svcsec -g svcsec /home/svcsec/.ssh
touch /home/svcsec/.ssh/authorized_keys
chown svcsec:svcsec /home/svcsec/.ssh/authorized_keys
chmod 600 /home/svcsec/.ssh/authorized_keys
ok "/home/svcsec/.ssh готов"

if [[ -n "$PUBKEY" ]]; then
  [[ -f "$PUBKEY" ]] || die "нет файла --pubkey $PUBKEY"
  PUB_LINE="$(tr -d '\r' <"$PUBKEY" | head -1)"
  [[ -n "$PUB_LINE" ]] || die "пустой pubkey"
  if grep -qxF "$PUB_LINE" /home/svcsec/.ssh/authorized_keys; then
    ok "ключ уже в authorized_keys"
  else
    printf '%s\n' "$PUB_LINE" >>/home/svcsec/.ssh/authorized_keys
    chown svcsec:svcsec /home/svcsec/.ssh/authorized_keys
    chmod 600 /home/svcsec/.ssh/authorized_keys
    ok "ключ добавлен в authorized_keys"
  fi
else
  hint "публичный ключ не передавали — добавьте позже (ssh-copy-id / --pubkey)"
fi

log "3/5 Старые широкие права sudo"
if [[ "$REMOVE_OLD" -eq 1 ]]; then
  # Не трогаем наш целевой файл до замены; ищем ALL для svcsec в других файлах
  shopt -s nullglob
  for f in /etc/sudoers.d/*; do
    [[ "$(basename "$f")" == "svcsec" ]] && continue
    if grep -Eq '^[[:space:]]*svcsec[[:space:]].*\bALL\b' "$f" 2>/dev/null; then
      bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
      mv "$f" "$bak"
      ok "отложен широкий sudoers: $f → $bak"
    fi
  done
  if grep -Eq '^[[:space:]]*svcsec[[:space:]].*\bALL\b' /etc/sudoers 2>/dev/null; then
    hint "в /etc/sudoers есть правила svcsec ALL — уберите их вручную через visudo"
  fi
else
  hint "пропуск очистки (добавьте --remove-old-sudoers)"
fi

log "4/5 Установка sudoers ($MODE)"
install -m 440 -o root -g root "$SUDOERS_SRC" /etc/sudoers.d/svcsec
visudo -cf /etc/sudoers.d/svcsec
visudo -cf /etc/sudoers
ok "/etc/sudoers.d/svcsec установлен и валиден"

log "5/5 Проверки"
if sudo -u svcsec sudo -n /bin/bash -c 'true' 2>/dev/null; then
  die "ОШИБКА: svcsec всё ещё может sudo /bin/bash — проверьте другие sudoers"
else
  ok "sudo /bin/bash для svcsec запрещён (ожидаемо)"
fi
if sudo -u svcsec sudo -n su -c 'true' 2>/dev/null; then
  die "ОШИБКА: svcsec всё ещё может sudo su"
else
  ok "sudo su для svcsec запрещён (ожидаемо)"
fi
if [[ "$MODE" == "noshell" ]]; then
  sudo -u svcsec sudo -n true
  ok "sudo -n true (вариант noshell) работает"
else
  if sudo -u svcsec sudo -n /usr/bin/dnf repolist >/dev/null 2>&1; then
    ok "sudo dnf (allowlist) работает"
  else
    hint "sudo dnf не прошёл — нормально, если dnf недоступен; проверьте список Cmnd_Alias"
  fi
fi

cat <<EOF

Готово на этом узле.
  Пользователь: svcsec
  sudoers:      /etc/sudoers.d/svcsec ($MODE)
  authorized_keys: /home/svcsec/.ssh/authorized_keys

С control node:
  ssh-copy-id -i <pubkey> svcsec@$(hostname -f)
  ansible this-host -u svcsec -m ping
  ansible this-host -u svcsec -b -a 'id'

Документация: docs/ansible-svcsec-svcsecadmin.md
EOF
