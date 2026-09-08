#!/usr/bin/env bash
# =============================================================================
# Полная установка и базовая настройка Ansible на РЕД ОС (7.3 / 8)
# =============================================================================
#
# Что делает скрипт:
#   1) проверяет ОС и права root
#   2) ставит пакеты ansible (+ sshpass)
#   3) (опционально) подключает репозиторий Ansible 6.x на РЕД ОС 7.3
#   4) создаёт /etc/ansible/ansible.cfg с разумными значениями по умолчанию
#   5) создаёт /etc/ansible/hosts (и/или проектный inventory) с подсказками
#   6) (опционально) генерирует SSH-ключ
#   7) (опционально) защищённый каталог ключей + один владелец
#   8) выводит чеклист следующих шагов
#
# Документация: docs/ansible-redos.md
#
# Примеры:
#   sudo ./scripts/install-ansible-redos.sh
#   sudo ./scripts/install-ansible-redos.sh --ansible6
#   sudo ./scripts/install-ansible-redos.sh --hosts '10.0.0.11,10.0.0.12' --remote-user admin
#   sudo ./scripts/install-ansible-redos.sh --generate-ssh-key --ssh-user admin
#
#   # Защищённый каталог ключей: только пользователь ansible-keys может читать/двигать ключи
#   sudo ./scripts/install-ansible-redos.sh --secure-keys \
#     --hosts '192.168.1.10' --remote-user admin
#
# =============================================================================

set -euo pipefail

# --------------------------- значения по умолчанию ---------------------------
ANSIBLE6=0
HOSTS=""
REMOTE_USER=""
GENERATE_SSH_KEY=0
# Обычный режим: ключ в ~/.ssh пользователя
SSH_USER=""
PROJECT_DIR=""
FORCE=0
INSTALL_SSHPASS=1
SYSTEM_CFG="/etc/ansible/ansible.cfg"
SYSTEM_HOSTS="/etc/ansible/hosts"

# Защищённое хранилище ключей (режим --secure-keys)
SECURE_KEYS=0
KEY_DIR="/var/lib/ansible-keys"
KEY_OWNER="ansible-keys"
# Итоговый путь к приватному ключу (заполняется позже)
KEY_PATH=""
KEY_PUB=""

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/install-ansible-redos.sh [опции]

Опции:
  --ansible6              РЕД ОС 7.3: подключить ansible6-release, затем поставить ansible
  --hosts LIST            хосты через запятую (пример: 192.168.0.10,web1.local)
  --remote-user NAME      ansible_user для всех хостов в inventory
  --generate-ssh-key      сгенерировать SSH-ключ (см. режимы ниже)
  --ssh-user NAME         обычный режим: ключ в home этого пользователя (~/.ssh)
  --secure-keys           защищённый каталог ключей + один владелец (рекомендуется)
  --key-dir PATH          каталог ключей (по умолчанию /var/lib/ansible-keys)
  --key-owner NAME        единственный владелец каталога (по умолчанию ansible-keys)
  --project-dir PATH      дополнительно создать проект: PATH/ansible.cfg + PATH/inventory/hosts
  --no-sshpass            не устанавливать sshpass
  --force                 перезаписать ansible.cfg / hosts / ключи, если уже есть
  -h, --help              эта справка

Где лежат ключи:
  Обычный режим (--generate-ssh-key):
    /home/<ssh-user>/.ssh/id_ed25519

  Защищённый режим (--secure-keys):
    /var/lib/ansible-keys/id_ed25519          (приватный, chmod 600)
    /var/lib/ansible-keys/id_ed25519.pub      (публичный)
    /var/lib/ansible-keys/archive/            (сюда можно перемещать старые ключи)
    Владелец каталога и файлов: только --key-owner (по умолчанию ansible-keys).
    Другие обычные пользователи НЕ могут читать/перемещать ключи.
    Root по-прежнему может всё (ограничение ОС).

Типовые сценарии:
  # 1) Только поставить Ansible на РЕД ОС 8
  sudo ./scripts/install-ansible-redos.sh

  # 2) РЕД ОС 7.3 + Ansible 6.x
  sudo ./scripts/install-ansible-redos.sh --ansible6

  # 3) Ключ в домашнем каталоге admin
  sudo ./scripts/install-ansible-redos.sh --generate-ssh-key --ssh-user admin

  # 4) Максимально защищённый каталог + один владелец ключей
  sudo ./scripts/install-ansible-redos.sh --secure-keys \
    --hosts '192.168.1.10,192.168.1.11' \
    --remote-user admin

После --secure-keys работайте от имени владельца ключей:
  sudo -u ansible-keys -H ansible all -m ping
  sudo -u ansible-keys ssh-copy-id -i /var/lib/ansible-keys/id_ed25519.pub admin@HOST
  # переместить старый ключ в архив (только владелец):
  sudo -u ansible-keys mv /var/lib/ansible-keys/id_ed25519 /var/lib/ansible-keys/archive/
EOF
}

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    OK: %s\n' "$*"; }
hint() { printf '    💡 %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "запустите через sudo (нужны права root)"
}

pkg_install() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  else
    die "нужен dnf или yum (РЕД ОС / RHEL-подобные дистрибутивы)"
  fi
}

detect_redos() {
  if [[ -f /etc/redos-release ]]; then
    ok "обнаружен /etc/redos-release"
    cat /etc/redos-release | sed 's/^/    /' || true
  elif [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    hint "это не явный РЕД ОС (ID=${ID:-?}). Скрипт рассчитан на РЕД ОС, но может сработать на RHEL-клонах."
  else
    hint "не удалось определить дистрибутив — продолжаем осторожно"
  fi
}

backup_if_exists() {
  local path="$1"
  if [[ -e "$path" && "$FORCE" -eq 0 ]]; then
    die "файл уже есть: $path (перезапишите с --force или удалите вручную)"
  fi
  if [[ -e "$path" && "$FORCE" -eq 1 ]]; then
    local bak="${path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$path" "$bak"
    ok "бэкап: $path → $bak"
  fi
}

ensure_key_owner() {
  # Создаёт системного пользователя — единственного владельца каталога ключей.
  # Пароль заблокирован: вход только через «sudo -u <owner>» у тех, кто имеет sudo.
  local user="$1"
  local home="$2"
  if id "$user" >/dev/null 2>&1; then
    ok "владелец ключей уже есть: $user"
    return 0
  fi
  hint "создаём системного пользователя $user (shell /bin/bash, пароль заблокирован)"
  useradd \
    --system \
    --create-home \
    --home-dir "$home" \
    --shell /bin/bash \
    --comment "Ansible SSH key owner" \
    "$user"
  passwd -l "$user" >/dev/null
  ok "создан пользователь $user (passwd -l — вход по паролю запрещён)"
}

harden_key_dir() {
  # Максимально жёсткие права для обычных пользователей: только владелец.
  local dir="$1"
  local owner="$2"
  mkdir -p "$dir" "$dir/archive"
  # Убрать любые ACL/лишние биты, выставить 0700
  chmod 0700 "$dir" "$dir/archive"
  chown -R "$owner:$owner" "$dir"
  # sticky на каталоге не нужен при 0700; на всякий случай убираем group/other
  chmod -R go-rwx "$dir" 2>/dev/null || true
  # SELinux (если есть): домашний/секретный контекст не трогаем агрессивно;
  # restorecon может помочь на РЕД ОС с enforcing.
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -RFv "$dir" 2>/dev/null || true
  fi
  ok "каталог защищён: $dir (режим 0700, владелец $owner)"
  hint "перемещать ключи может только $owner, например:"
  printf '      sudo -u %s mv %s/id_ed25519 %s/archive/\n' "$owner" "$dir" "$dir"
}

write_key_dir_readme() {
  local dir="$1"
  local owner="$2"
  cat >"$dir/README" <<EOF
Защищённое хранилище SSH-ключей Ansible
========================================
Владелец (единственный, кто может читать/писать/перемещать ключи): $owner
Каталог: $dir  (chmod 0700)

Файлы:
  id_ed25519       — приватный ключ (600)
  id_ed25519.pub   — публичный ключ
  archive/         — сюда перемещайте старые/отозванные ключи

Важно:
  • Обычные пользователи системы сюда не попадут (нет прав).
  • root всё ещё может читать каталог — это ограничение Linux.
  • Запускайте Ansible от имени владельца:
      sudo -u $owner -H ansible all -m ping
  • Разложить публичный ключ на узел:
      sudo -u $owner ssh-copy-id -i $dir/id_ed25519.pub USER@HOST
  • Переместить ключ в архив (только $owner):
      sudo -u $owner mv $dir/id_ed25519 $dir/archive/id_ed25519.\$(date +%Y%m%d)
EOF
  chown "$owner:$owner" "$dir/README"
  chmod 0600 "$dir/README"
}

# --------------------------- разбор аргументов ------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ansible6) ANSIBLE6=1; shift ;;
    --hosts) HOSTS="${2:-}"; shift 2 ;;
    --remote-user) REMOTE_USER="${2:-}"; shift 2 ;;
    --generate-ssh-key) GENERATE_SSH_KEY=1; shift ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --secure-keys) SECURE_KEYS=1; GENERATE_SSH_KEY=1; shift ;;
    --key-dir) KEY_DIR="${2:-}"; shift 2 ;;
    --key-owner) KEY_OWNER="${2:-}"; shift 2 ;;
    --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --no-sshpass) INSTALL_SSHPASS=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

if [[ -z "$SSH_USER" ]]; then
  SSH_USER="${SUDO_USER:-root}"
fi

[[ -n "$KEY_DIR" ]] || die "пустой --key-dir"
[[ -n "$KEY_OWNER" ]] || die "пустой --key-owner"
# KEY_DIR должен быть абсолютным
[[ "$KEY_DIR" == /* ]] || die "--key-dir должен быть абсолютным путём (сейчас: $KEY_DIR)"

need_root

# --------------------------- шаги установки ---------------------------------
log "0/8 Проверка окружения"
detect_redos
if [[ "$SECURE_KEYS" -eq 1 ]]; then
  ok "режим защищённых ключей: каталог=$KEY_DIR владелец=$KEY_OWNER"
  hint "только пользователь $KEY_OWNER сможет читать и перемещать ключи (кроме root)"
else
  ok "пользователь для SSH-ключа (обычный режим): $SSH_USER"
fi
hint "Ansible ставится на УПРАВЛЯЮЩУЮ машину. На узлах агент не нужен — только SSH + Python 3."

log "1/8 Подготовка репозиториев"
if [[ "$ANSIBLE6" -eq 1 ]]; then
  hint "режим --ansible6: устанавливаем ansible6-release (РЕД ОС 7.3 / Ansible 6.x)"
  pkg_install ansible6-release
  if command -v dnf >/dev/null 2>&1; then
    dnf clean all
    dnf makecache
  fi
  ok "репозиторий Ansible 6.x подключён"
else
  hint "обычная установка из основных репозиториев (типично для РЕД ОС 8)"
  if command -v dnf >/dev/null 2>&1; then
    dnf makecache || true
  fi
fi

log "2/8 Установка пакетов"
PKGS=(ansible)
[[ "$INSTALL_SSHPASS" -eq 1 ]] && PKGS+=(sshpass)
hint "пакеты к установке: ${PKGS[*]}"
pkg_install "${PKGS[@]}"
ok "пакеты установлены"

if command -v ansible >/dev/null 2>&1; then
  ansible --version | sed 's/^/    /'
else
  die "команда ansible не найдена после установки — проверьте репозитории (dnf repolist)"
fi

# --------------------------- защищённый каталог (до ansible.cfg) ------------
PRIVATE_KEY_CFG_LINE=""
if [[ "$SECURE_KEYS" -eq 1 ]]; then
  log "3/8 Защищённый каталог ключей"
  ensure_key_owner "$KEY_OWNER" "$KEY_DIR"
  harden_key_dir "$KEY_DIR" "$KEY_OWNER"
  write_key_dir_readme "$KEY_DIR" "$KEY_OWNER"
  KEY_PATH="${KEY_DIR}/id_ed25519"
  KEY_PUB="${KEY_PATH}.pub"
  PRIVATE_KEY_CFG_LINE="private_key_file = ${KEY_PATH}"
else
  log "3/8 Защищённый каталог ключей — пропуск (нет --secure-keys)"
  hint "для жёсткой изоляции ключей перезапустите с --secure-keys"
fi

log "4/8 Каталог /etc/ansible"
mkdir -p /etc/ansible
ok "/etc/ansible готов"

log "5/8 Запись ${SYSTEM_CFG}"
backup_if_exists "$SYSTEM_CFG"
cat >"$SYSTEM_CFG" <<EOF
# Сгенерировано scripts/install-ansible-redos.sh
# Документация: docs/ansible-redos.md
#
# Подсказка: для отдельного проекта лучше свой ./ansible.cfg (он перекрывает этот файл).

[defaults]
inventory = /etc/ansible/hosts
retry_files_enabled = False
interpreter_python = auto_silent
forks = 20
timeout = 30
# Подсказка: в лаборатории False удобнее; в проде лучше True
host_key_checking = False
${PRIVATE_KEY_CFG_LINE}

[privilege_escalation]
become = True
become_method = sudo
become_ask_pass = False

[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
EOF
ok "записан $SYSTEM_CFG"
if [[ -n "$PRIVATE_KEY_CFG_LINE" ]]; then
  hint "в ansible.cfg прописан $PRIVATE_KEY_CFG_LINE"
  hint "запускайте ansible от $KEY_OWNER, иначе ключ будет недоступен"
fi

log "6/8 Запись inventory ${SYSTEM_HOSTS}"
backup_if_exists "$SYSTEM_HOSTS"

HOST_BLOCK=""
if [[ -n "$HOSTS" ]]; then
  IFS=',' read -r -a HOST_ARR <<<"$HOSTS"
  for h in "${HOST_ARR[@]}"; do
    h="$(echo "$h" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$h" ]] && continue
    if [[ -n "$REMOTE_USER" ]]; then
      HOST_BLOCK+="${h} ansible_user=${REMOTE_USER}"$'\n'
    else
      HOST_BLOCK+="${h}"$'\n'
    fi
  done
fi

if [[ -z "$HOST_BLOCK" ]]; then
  HOST_BLOCK="# добавьте сюда IP/DNS управляемых узлов, по одному в строке
# 192.168.0.100
# 192.168.0.101 ansible_user=admin
"
fi

cat >"$SYSTEM_HOSTS" <<EOF
# Сгенерировано scripts/install-ansible-redos.sh
# Подсказка: группы пишутся в [квадратных] скобках, ниже — список хостов.
#
# Проверка связи (не ICMP!):  ansible all -m ping
# С паролем SSH:              ansible all -m ping -k
# С паролем sudo:             ansible all -m ping -K

[all]
localhost ansible_connection=local

[servers]
${HOST_BLOCK}
EOF
ok "записан $SYSTEM_HOSTS"

if [[ -n "$PROJECT_DIR" ]]; then
  log "6b/8 Проектный каталог: $PROJECT_DIR"
  mkdir -p "$PROJECT_DIR/inventory" "$PROJECT_DIR/playbooks"
  backup_if_exists "$PROJECT_DIR/ansible.cfg"
  backup_if_exists "$PROJECT_DIR/inventory/hosts"

  cat >"$PROJECT_DIR/ansible.cfg" <<EOF
# Проектный конфиг (имеет приоритет над /etc/ansible/ansible.cfg в этом каталоге)
[defaults]
inventory = ./inventory/hosts
retry_files_enabled = False
interpreter_python = auto_silent
host_key_checking = False
forks = 20
${PRIVATE_KEY_CFG_LINE}

[privilege_escalation]
become = True
become_method = sudo
EOF

  cp -a "$SYSTEM_HOSTS" "$PROJECT_DIR/inventory/hosts"

  cat >"$PROJECT_DIR/playbooks/ping.yml" <<'EOF'
---
- name: Проверка доступности узлов
  hosts: all
  gather_facts: false
  tasks:
    - name: Ansible ping (SSH + Python)
      ansible.builtin.ping:
EOF

  cat >"$PROJECT_DIR/playbooks/install-packages.yml" <<'EOF'
---
- name: Установка утилит
  hosts: servers
  become: true
  vars:
    packages:
      - htop
      - curl
  tasks:
    - name: Установить пакеты
      ansible.builtin.dnf:
        name: "{{ packages }}"
        state: present
EOF

  ok "проект: $PROJECT_DIR"
fi

# --------------------------- SSH-ключ --------------------------------------
log "7/8 SSH-ключ"
if [[ "$GENERATE_SSH_KEY" -eq 1 ]]; then
  if [[ "$SECURE_KEYS" -eq 1 ]]; then
    # Ключ в защищённом каталоге, только KEY_OWNER
    KEY_PATH="${KEY_DIR}/id_ed25519"
    KEY_PUB="${KEY_PATH}.pub"
    RUN_AS="$KEY_OWNER"

    if [[ -f "$KEY_PATH" && "$FORCE" -eq 0 ]]; then
      ok "ключ уже есть: $KEY_PATH (не трогаем; --force для пересоздания)"
    else
      if [[ -f "$KEY_PATH" && "$FORCE" -eq 1 ]]; then
        # Перемещение старого ключа в archive — делает владелец
        TS="$(date +%Y%m%d%H%M%S)"
        sudo -u "$KEY_OWNER" mv "$KEY_PATH" "${KEY_DIR}/archive/id_ed25519.${TS}"
        [[ -f "$KEY_PUB" ]] && sudo -u "$KEY_OWNER" mv "$KEY_PUB" "${KEY_DIR}/archive/id_ed25519.pub.${TS}" || true
        ok "старый ключ перемещён в ${KEY_DIR}/archive/"
      fi
      # Подсказка: ключ без passphrase удобен для автоматизации;
      # для ещё большей защиты задайте passphrase и ssh-agent под KEY_OWNER.
      sudo -u "$KEY_OWNER" ssh-keygen -t ed25519 \
        -C "${KEY_OWNER}@$(hostname)-ansible-$(date -I)" \
        -f "$KEY_PATH" -N ""
      chmod 0600 "$KEY_PATH"
      chmod 0640 "$KEY_PUB"
      chown "$KEY_OWNER:$KEY_OWNER" "$KEY_PATH" "$KEY_PUB"
      ok "создан защищённый ключ $KEY_PATH"
    fi
  else
    # Обычный режим: ~/.ssh
    if ! id "$SSH_USER" >/dev/null 2>&1; then
      die "пользователь --ssh-user=$SSH_USER не существует"
    fi
    SSH_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
    [[ -n "$SSH_HOME" && -d "$SSH_HOME" ]] || die "не найден home для $SSH_USER"
    SSH_DIR="${SSH_HOME}/.ssh"
    KEY_PATH="${SSH_DIR}/id_ed25519"
    KEY_PUB="${KEY_PATH}.pub"
    RUN_AS="$SSH_USER"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chown "$SSH_USER:$SSH_USER" "$SSH_DIR"

    if [[ -f "$KEY_PATH" && "$FORCE" -eq 0 ]]; then
      ok "ключ уже есть: $KEY_PATH (не трогаем; --force для пересоздания)"
    else
      if [[ -f "$KEY_PATH" && "$FORCE" -eq 1 ]]; then
        mv "$KEY_PATH" "${KEY_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        mv "${KEY_PATH}.pub" "${KEY_PATH}.pub.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      fi
      sudo -u "$SSH_USER" ssh-keygen -t ed25519 \
        -C "${SSH_USER}@$(hostname)-ansible-$(date -I)" \
        -f "$KEY_PATH" -N ""
      ok "создан ключ $KEY_PATH"
    fi
  fi

  hint "скопируйте публичный ключ на узлы от имени владельца ключа:"
  printf '      sudo -u %s ssh-copy-id -i %s %s@<ХОСТ>\n' \
    "${RUN_AS}" "${KEY_PUB}" "${REMOTE_USER:-user}"
  if [[ -f "$KEY_PUB" ]]; then
    printf '\n    Публичный ключ (%s):\n' "$KEY_PUB"
    sed 's/^/      /' "$KEY_PUB"
  fi
else
  hint "ключ не создавался. Варианты: --generate-ssh-key или --secure-keys"
fi

# --------------------------- финальная проверка ----------------------------
log "8/8 Быстрая самопроверка"
PING_CMD=(ansible localhost -m ping)
if [[ "$SECURE_KEYS" -eq 1 ]]; then
  # Под пользователем-владельцем ключей (у него есть доступ к private_key_file)
  PING_CMD=(sudo -u "$KEY_OWNER" -H ansible localhost -m ping)
fi
if "${PING_CMD[@]}" >/tmp/ansible-localhost-ping.out 2>&1; then
  ok "ansible localhost -m ping → SUCCESS"
  sed 's/^/    /' /tmp/ansible-localhost-ping.out || true
else
  hint "локальный ping не прошёл — смотрите вывод:"
  sed 's/^/    /' /tmp/ansible-localhost-ping.out || true
fi
rm -f /tmp/ansible-localhost-ping.out

# --------------------------- чеклист ---------------------------------------
SECURE_BLOCK=""
if [[ "$SECURE_KEYS" -eq 1 ]]; then
  SECURE_BLOCK=$(cat <<EOF

Защищённые ключи:
  Каталог:   $KEY_DIR   (chmod 0700)
  Владелец:  $KEY_OWNER  — единственный обычный пользователь с доступом
  Приватный: $KEY_PATH
  Публичный: $KEY_PUB
  Архив:     $KEY_DIR/archive/

  Запуск Ansible:
    sudo -u $KEY_OWNER -H ansible all -m ping
    sudo -u $KEY_OWNER -H ansible-playbook playbook.yml

  Разложить ключ на узел:
    sudo -u $KEY_OWNER ssh-copy-id -i $KEY_PUB ${REMOTE_USER:-user}@<ХОСТ>

  Переместить ключ (только $KEY_OWNER):
    sudo -u $KEY_OWNER mv $KEY_PATH $KEY_DIR/archive/id_ed25519.\$(date +%Y%m%d)

  Ограничение: root по-прежнему видит файлы — это норма для Linux без HSM/шифрования.
EOF
)
fi

cat <<EOF

==============================================================================
  Ansible установлен и базовая конфигурация записана.
==============================================================================

Версия:     $(ansible --version 2>/dev/null | head -1)
Конфиг:     $SYSTEM_CFG
Inventory:  $SYSTEM_HOSTS
$( [[ -n "$PROJECT_DIR" ]] && echo "Проект:     $PROJECT_DIR" )
$SECURE_BLOCK

Что сделать дальше (чеклист):

  1. Допишите управляемые узлы в inventory (если ещё не указали --hosts):
       sudo nano $SYSTEM_HOSTS

  2. Разложите SSH-ключ на каждый узел (см. команды выше).

  3. Проверьте связь:
$( if [[ "$SECURE_KEYS" -eq 1 ]]; then
     echo "       sudo -u $KEY_OWNER -H ansible all -m ping"
   else
     echo "       ansible all -m ping"
   fi )

  4. Ad-hoc / плейбук — см. docs/ansible-redos.md

Подсказки по безопасности:
  • --secure-keys изолирует ключи от других пользователей ОС.
  • Не оставляйте host_key_checking=False в открытом интернете без необходимости.
  • Секреты плейбуков — через ansible-vault.
  • На узлах — минимальный sudo для пользователя автоматизации.

Документация в репозитории: docs/ansible-redos.md
Справка скрипта:            $0 --help
==============================================================================
EOF
