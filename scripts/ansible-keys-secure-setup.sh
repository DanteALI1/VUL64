#!/usr/bin/env bash
# Создать (или ужесточить) защищённый каталог SSH-ключей Ansible
# без полной переустановки Ansible.
#
# По умолчанию:
#   каталог  /var/lib/ansible-keys   chmod 0700
#   владелец ansible-keys           (создаётся, пароль блокируется)
#   ключ     id_ed25519             (если ещё нет)
#
# Пример:
#   sudo ./scripts/ansible-keys-secure-setup.sh
#   sudo ./scripts/ansible-keys-secure-setup.sh --key-dir /var/lib/ansible-keys --key-owner ansible-keys
#   sudo ./scripts/ansible-keys-secure-setup.sh --force   # пересоздать ключ, старый → archive/

set -euo pipefail

KEY_DIR="/var/lib/ansible-keys"
KEY_OWNER="ansible-keys"
FORCE=0
PATCH_CFG=1
SYSTEM_CFG="/etc/ansible/ansible.cfg"

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/ansible-keys-secure-setup.sh [опции]

Опции:
  --key-dir PATH      каталог (по умолчанию /var/lib/ansible-keys)
  --key-owner NAME    единственный владелец (по умолчанию ansible-keys)
  --force             переместить старый ключ в archive/ и создать новый
  --no-patch-cfg      не прописывать private_key_file в /etc/ansible/ansible.cfg
  -h, --help          справка
EOF
}

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    OK: %s\n' "$*"; }
hint() { printf '    💡 %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-dir) KEY_DIR="${2:-}"; shift 2 ;;
    --key-owner) KEY_OWNER="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-patch-cfg) PATCH_CFG=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "запустите через sudo"
[[ "$KEY_DIR" == /* ]] || die "--key-dir должен быть абсолютным"

log "1/4 Пользователь-владелец: $KEY_OWNER"
if ! id "$KEY_OWNER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$KEY_DIR" \
    --shell /bin/bash --comment "Ansible SSH key owner" "$KEY_OWNER"
  passwd -l "$KEY_OWNER" >/dev/null
  ok "создан $KEY_OWNER (пароль заблокирован)"
else
  ok "пользователь уже есть"
fi

log "2/4 Каталог $KEY_DIR"
mkdir -p "$KEY_DIR" "$KEY_DIR/archive"
chmod 0700 "$KEY_DIR" "$KEY_DIR/archive"
chown -R "$KEY_OWNER:$KEY_OWNER" "$KEY_DIR"
chmod -R go-rwx "$KEY_DIR" 2>/dev/null || true
command -v restorecon >/dev/null 2>&1 && restorecon -RFv "$KEY_DIR" 2>/dev/null || true
ok "права 0700, владелец $KEY_OWNER"

cat >"$KEY_DIR/README" <<EOF
Защищённое хранилище SSH-ключей Ansible
Владелец: $KEY_OWNER
Только этот пользователь (кроме root) может читать и перемещать ключи.
Архив: $KEY_DIR/archive/
Запуск: sudo -u $KEY_OWNER -H ansible all -m ping
EOF
chown "$KEY_OWNER:$KEY_OWNER" "$KEY_DIR/README"
chmod 0600 "$KEY_DIR/README"

KEY_PATH="${KEY_DIR}/id_ed25519"
log "3/4 Ключ $KEY_PATH"
if [[ -f "$KEY_PATH" && "$FORCE" -eq 0 ]]; then
  ok "ключ уже есть (не трогаем; --force для ротации в archive/)"
else
  if [[ -f "$KEY_PATH" && "$FORCE" -eq 1 ]]; then
    TS="$(date +%Y%m%d%H%M%S)"
    sudo -u "$KEY_OWNER" mv "$KEY_PATH" "${KEY_DIR}/archive/id_ed25519.${TS}"
    [[ -f "${KEY_PATH}.pub" ]] && sudo -u "$KEY_OWNER" mv "${KEY_PATH}.pub" "${KEY_DIR}/archive/id_ed25519.pub.${TS}" || true
    ok "старый ключ → archive/"
  fi
  sudo -u "$KEY_OWNER" ssh-keygen -t ed25519 \
    -C "${KEY_OWNER}@$(hostname)-ansible-$(date -I)" \
    -f "$KEY_PATH" -N ""
  chmod 0600 "$KEY_PATH"
  chmod 0640 "${KEY_PATH}.pub"
  chown "$KEY_OWNER:$KEY_OWNER" "$KEY_PATH" "${KEY_PATH}.pub"
  ok "ключ создан"
fi

log "4/4 ansible.cfg"
if [[ "$PATCH_CFG" -eq 1 && -f "$SYSTEM_CFG" ]]; then
  if grep -q '^[[:space:]]*private_key_file[[:space:]]*=' "$SYSTEM_CFG"; then
    sed -i "s|^[[:space:]]*private_key_file[[:space:]]*=.*|private_key_file = ${KEY_PATH}|" "$SYSTEM_CFG"
  else
    # вставить в секцию [defaults], если есть
    if grep -q '^\[defaults\]' "$SYSTEM_CFG"; then
      sed -i "/^\[defaults\]/a private_key_file = ${KEY_PATH}" "$SYSTEM_CFG"
    else
      printf '\n[defaults]\nprivate_key_file = %s\n' "$KEY_PATH" >>"$SYSTEM_CFG"
    fi
  fi
  ok "прописан private_key_file = $KEY_PATH в $SYSTEM_CFG"
else
  hint "конфиг не меняли (--no-patch-cfg или нет $SYSTEM_CFG)"
fi

cat <<EOF

Готово.
  Каталог:  $KEY_DIR (0700)
  Владелец: $KEY_OWNER — единственный обычный пользователь с доступом к ключам
  Ключ:     $KEY_PATH

Переместить ключ в архив:
  sudo -u $KEY_OWNER ./scripts/ansible-keys-ctl.sh move-archive

Запуск Ansible:
  sudo -u $KEY_OWNER -H ansible all -m ping

Ограничение: root всё ещё может читать файлы (без HSM/шифрования это нормально для Linux).
EOF
