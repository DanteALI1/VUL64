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
#   6) (опционально) генерирует SSH-ключ для подключений к узлам
#   7) выводит чеклист следующих шагов (ssh-copy-id, ansible ping, плейбук)
#
# Документация: docs/ansible-redos.md
# БЗ РЕД ОС 8:  https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-remote-admin/8_0-ansible/
# БЗ РЕД ОС 7.3: https://redos.red-soft.ru/base/redos-7_3/7_3-administation/7_3-remote-admin/7_3-ansible/
#
# Примеры:
#   sudo ./scripts/install-ansible-redos.sh
#   sudo ./scripts/install-ansible-redos.sh --ansible6
#   sudo ./scripts/install-ansible-redos.sh --hosts '10.0.0.11,10.0.0.12' --remote-user admin
#   sudo ./scripts/install-ansible-redos.sh --generate-ssh-key --ssh-user admin
#   sudo ./scripts/install-ansible-redos.sh --project-dir /opt/ansible --force
#
# =============================================================================

set -euo pipefail

# --------------------------- значения по умолчанию ---------------------------
# ANSIBLE6=1  — сначала поставить ansible6-release (РЕД ОС 7.3, Ansible 6.x)
ANSIBLE6=0
# Список хостов через запятую → попадут в inventory (IP или DNS)
HOSTS=""
# Пользователь SSH на удалённых узлах (ansible_user)
REMOTE_USER=""
# Создать SSH-ключ для пользователя, от которого потом будете запускать ansible
GENERATE_SSH_KEY=0
# Для кого генерировать ключ: если скрипт через sudo — берём SUDO_USER, иначе root
SSH_USER=""
# Каталог «проектного» ansible (ansible.cfg + inventory рядом) — удобно для команды
PROJECT_DIR=""
# Перезаписывать уже существующие конфиги
FORCE=0
# Ставить sshpass (нужен для ansible -k / парольной аутентификации)
INSTALL_SSHPASS=1
# Пути системных файлов Ansible
SYSTEM_CFG="/etc/ansible/ansible.cfg"
SYSTEM_HOSTS="/etc/ansible/hosts"

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/install-ansible-redos.sh [опции]

Опции:
  --ansible6              РЕД ОС 7.3: подключить ansible6-release, затем поставить ansible
  --hosts LIST            хосты через запятую (пример: 192.168.0.10,web1.local)
  --remote-user NAME      ansible_user для всех хостов в inventory
  --generate-ssh-key      сгенерировать ~/.ssh/id_ed25519 (если ещё нет)
  --ssh-user NAME         от чьего имени создать ключ (по умолчанию $SUDO_USER)
  --project-dir PATH      дополнительно создать проект: PATH/ansible.cfg + PATH/inventory/hosts
  --no-sshpass            не устанавливать sshpass
  --force                 перезаписать ansible.cfg / hosts, если уже есть
  -h, --help              эта справка

Типовые сценарии:
  # 1) Только поставить Ansible на РЕД ОС 8
  sudo ./scripts/install-ansible-redos.sh

  # 2) РЕД ОС 7.3 + Ansible 6.x
  sudo ./scripts/install-ansible-redos.sh --ansible6

  # 3) Сразу прописать 2 сервера и пользователя SSH
  sudo ./scripts/install-ansible-redos.sh \
    --hosts '192.168.1.10,192.168.1.11' \
    --remote-user admin \
    --generate-ssh-key

После установки разложите ключ и проверьте связь:
  ssh-copy-id -i ~/.ssh/id_ed25519.pub admin@192.168.1.10
  ansible all -m ping
EOF
}

# --------------------------- вспомогательные функции ------------------------
# Подсказка: все сообщения идут в stderr/stdout явно, чтобы было видно прогресс.
log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    OK: %s\n' "$*"; }
hint() { printf '    💡 %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
  # Подсказка: dnf и запись в /etc/ansible требуют root.
  [[ "${EUID}" -eq 0 ]] || die "запустите через sudo (нужны права root)"
}

pkg_install() {
  # Подсказка: на РЕД ОС основной менеджер — dnf; yum оставляем как запасной вариант.
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  else
    die "нужен dnf или yum (РЕД ОС / RHEL-подобные дистрибутивы)"
  fi
}

detect_redos() {
  # Подсказка: не блокируем установку на «похожих» системах, но предупреждаем.
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

# --------------------------- разбор аргументов ------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ansible6) ANSIBLE6=1; shift ;;
    --hosts) HOSTS="${2:-}"; shift 2 ;;
    --remote-user) REMOTE_USER="${2:-}"; shift 2 ;;
    --generate-ssh-key) GENERATE_SSH_KEY=1; shift ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --no-sshpass) INSTALL_SSHPASS=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

# Если запускали через sudo — ключ лучше делать для обычного пользователя, не для root.
if [[ -z "$SSH_USER" ]]; then
  SSH_USER="${SUDO_USER:-root}"
fi

need_root

# --------------------------- шаги установки ---------------------------------
log "0/7 Проверка окружения"
detect_redos
ok "пользователь для SSH-ключа: $SSH_USER"
hint "Ansible ставится на УПРАВЛЯЮЩУЮ машину. На узлах агент не нужен — только SSH + Python 3."

log "1/7 Подготовка репозиториев"
if [[ "$ANSIBLE6" -eq 1 ]]; then
  # Подсказка (РЕД ОС 7.3): Ansible 6.x лежит в подключаемом репозитории.
  # Цепочка из БЗ: ansible6-release → clean → makecache → install ansible
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

log "2/7 Установка пакетов"
# Подсказка: python3-pip / git часто полезны для ansible-galaxy и коллекций, но не обязательны.
PKGS=(ansible)
[[ "$INSTALL_SSHPASS" -eq 1 ]] && PKGS+=(sshpass)
# sshpass — только для режима с паролем: ansible ... -k
hint "пакеты к установке: ${PKGS[*]}"
pkg_install "${PKGS[@]}"
ok "пакеты установлены"

if command -v ansible >/dev/null 2>&1; then
  ansible --version | sed 's/^/    /'
else
  die "команда ansible не найдена после установки — проверьте репозитории (dnf repolist)"
fi

log "3/7 Каталог /etc/ansible"
mkdir -p /etc/ansible
ok "/etc/ansible готов"

log "4/7 Запись ${SYSTEM_CFG}"
backup_if_exists "$SYSTEM_CFG"
# Подсказка: приоритет конфигов Ansible (сверху вниз):
#   1) переменная ANSIBLE_CONFIG
#   2) ./ansible.cfg в текущем каталоге
#   3) ~/.ansible.cfg
#   4) /etc/ansible/ansible.cfg
cat >"$SYSTEM_CFG" <<'EOF'
# Сгенерировано scripts/install-ansible-redos.sh
# Документация: docs/ansible-redos.md
#
# Подсказка: для отдельного проекта лучше свой ./ansible.cfg (он перекрывает этот файл).

[defaults]
# Файл/каталог инвентаризации по умолчанию
inventory = /etc/ansible/hosts

# Не создавать .retry-файлы рядом с плейбуками
retry_files_enabled = False

# Тише про выбор интерпретатора Python на узлах
interpreter_python = auto_silent

# Параллелизм (увеличьте на мощной управляющей машине)
forks = 20

# Таймаут SSH (секунды)
timeout = 30

# Подсказка: в лаборатории False удобнее; в проде лучше True (проверка known_hosts)
host_key_checking = False

# Формат вывода (опционально раскомментируйте при установленном ansible.posix / community)
# stdout_callback = yaml

[privilege_escalation]
# become = sudo на удалённом хосте (как ansible -b)
become = True
become_method = sudo
# Если на узлах sudo требует пароль — запускайте с -K или поставьте True:
become_ask_pass = False

[ssh_connection]
# Ускорение повторных подключений (ControlMaster)
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
EOF
ok "записан $SYSTEM_CFG"
hint "host_key_checking=False и StrictHostKeyChecking=no — удобно для теста; для прода ужесточите."

log "5/7 Запись inventory ${SYSTEM_HOSTS}"
backup_if_exists "$SYSTEM_HOSTS"

# Собираем блок хостов из --hosts
HOST_BLOCK=""
if [[ -n "$HOSTS" ]]; then
  IFS=',' read -r -a HOST_ARR <<<"$HOSTS"
  for h in "${HOST_ARR[@]}"; do
    # trim spaces
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
# Примеры записей (раскомментируйте и правьте):
#   [web]
#   web1.example.ru
#   192.168.0.100
#
#   # псевдоним + явный IP + пользователь SSH
#   [app]
#   app1 ansible_host=10.0.0.5 ansible_user=admin
#
#   # диапазон имён node01 … node10
#   [batch]
#   node[01:10].example.ru
#
#   # объединение групп
#   [prod:children]
#   web
#   app
#
# Проверка связи (не ICMP!):  ansible all -m ping
# С паролем SSH:              ansible all -m ping -k
# С паролем sudo:             ansible all -m ping -K

[all]
# Локальный хост — полезно для проверки самого Ansible без сети
localhost ansible_connection=local

[servers]
${HOST_BLOCK}
EOF
ok "записан $SYSTEM_HOSTS"
if [[ -n "$HOSTS" ]]; then
  hint "хосты из --hosts добавлены в группу [servers]"
else
  hint "хосты не переданы — допишите их вручную в $SYSTEM_HOSTS"
fi

# --------------------------- проектный каталог (опционально) ---------------
if [[ -n "$PROJECT_DIR" ]]; then
  log "5b/7 Проектный каталог: $PROJECT_DIR"
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

[privilege_escalation]
become = True
become_method = sudo
EOF

  cp -a "$SYSTEM_HOSTS" "$PROJECT_DIR/inventory/hosts"

  # Мини-плейбук-пример с подсказками
  cat >"$PROJECT_DIR/playbooks/ping.yml" <<'EOF'
---
# Подсказка: запуск из каталога проекта:
#   cd /path/to/project && ansible-playbook playbooks/ping.yml
- name: Проверка доступности узлов
  hosts: all
  gather_facts: false
  tasks:
    - name: Ansible ping (SSH + Python)
      ansible.builtin.ping:
EOF

  cat >"$PROJECT_DIR/playbooks/install-packages.yml" <<'EOF'
---
# Пример установки пакетов на РЕД ОС через модуль dnf
# Запуск: ansible-playbook playbooks/install-packages.yml -K
# Подсказка: параметр name у dnf — это СПИСОК ПАКЕТОВ, не имя задачи.
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

  ok "проект: $PROJECT_DIR (ansible.cfg, inventory/, playbooks/)"
  hint "работайте из каталога проекта: cd $PROJECT_DIR"
fi

# --------------------------- SSH-ключ (опционально) ------------------------
log "6/7 SSH-ключ"
if [[ "$GENERATE_SSH_KEY" -eq 1 ]]; then
  # Определяем домашний каталог целевого пользователя
  if ! id "$SSH_USER" >/dev/null 2>&1; then
    die "пользователь --ssh-user=$SSH_USER не существует"
  fi
  SSH_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
  [[ -n "$SSH_HOME" && -d "$SSH_HOME" ]] || die "не найден home для $SSH_USER"
  SSH_DIR="${SSH_HOME}/.ssh"
  KEY_PATH="${SSH_DIR}/id_ed25519"

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  chown "$SSH_USER":"$SSH_USER" "$SSH_DIR"

  if [[ -f "$KEY_PATH" && "$FORCE" -eq 0 ]]; then
    ok "ключ уже есть: $KEY_PATH (не трогаем; --force для пересоздания)"
  else
    if [[ -f "$KEY_PATH" && "$FORCE" -eq 1 ]]; then
      mv "$KEY_PATH" "${KEY_PATH}.bak.$(date +%Y%m%d%H%M%S)"
      mv "${KEY_PATH}.pub" "${KEY_PATH}.pub.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    # Подсказка: ed25519 короче и современнее RSA; -N "" = без passphrase (удобно для автоматизации).
    # Для повышенной безопасности задайте passphrase и ssh-agent.
    sudo -u "$SSH_USER" ssh-keygen -t ed25519 \
      -C "${SSH_USER}@$(hostname)-ansible-$(date -I)" \
      -f "$KEY_PATH" -N ""
    ok "создан ключ $KEY_PATH"
  fi
  hint "скопируйте публичный ключ на узлы:"
  printf '      ssh-copy-id -i %s.pub %s@<ХОСТ>\n' "$KEY_PATH" "${REMOTE_USER:-$SSH_USER}"
  if [[ -f "${KEY_PATH}.pub" ]]; then
    printf '\n    Публичный ключ (%s.pub):\n' "$KEY_PATH"
    sed 's/^/      /' "${KEY_PATH}.pub"
  fi
else
  hint "ключ не создавался (добавьте --generate-ssh-key). Без ключа можно: ansible all -m ping -k"
fi

# --------------------------- финальная проверка ----------------------------
log "7/7 Быстрая самопроверка"
# localhost с ansible_connection=local не требует SSH
if ansible localhost -m ping >/tmp/ansible-localhost-ping.out 2>&1; then
  ok "ansible localhost -m ping → SUCCESS"
  sed 's/^/    /' /tmp/ansible-localhost-ping.out || true
else
  hint "локальный ping не прошёл — смотрите вывод:"
  sed 's/^/    /' /tmp/ansible-localhost-ping.out || true
fi
rm -f /tmp/ansible-localhost-ping.out

# --------------------------- чеклист ---------------------------------------
cat <<EOF

==============================================================================
  Ansible установлен и базовая конфигурация записана.
==============================================================================

Версия:     $(ansible --version 2>/dev/null | head -1)
Конфиг:     $SYSTEM_CFG
Inventory:  $SYSTEM_HOSTS
$( [[ -n "$PROJECT_DIR" ]] && echo "Проект:     $PROJECT_DIR" )

Что сделать дальше (чеклист):

  1. Допишите управляемые узлы в inventory (если ещё не указали --hosts):
       sudo nano $SYSTEM_HOSTS

  2. Разложите SSH-ключ на каждый узел:
       ssh-copy-id -i ~/.ssh/id_ed25519.pub ${REMOTE_USER:-user}@<ХОСТ>
     Подсказка: пользователь должен совпадать с ansible_user в inventory.

  3. Проверьте связь:
       ansible all -m ping
       ansible servers -m ping
     По паролю (если нет ключа):
       ansible all -m ping -k
     Если sudo на узле с паролем:
       ansible all -m ping -K

  4. Ad-hoc команда:
       ansible servers -a "uptime"

  5. Плейбук (пример из docs/ansible-redos.md):
       ansible-playbook playbook.yml
       ansible-playbook --syntax-check playbook.yml

Подсказки по безопасности:
  • Не оставляйте host_key_checking=False в открытом интернете без необходимости.
  • Файлы с паролями/vault-секретами храните отдельно (ansible-vault).
  • На узлах лучше NOPASSWD sudo только для нужной группы команд / пользователя автоматизации.

Документация в репозитории: docs/ansible-redos.md
Справка скрипта:            $0 --help
==============================================================================
EOF
