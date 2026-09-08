# РЕД ОС: команда `super` (svcsec → svcsecadmin → root)

Полная инструкция под вашу схему доступа на **РЕД ОС**:

1. По **SSH** на сервер заходит **только** УЗ `svcsec`
2. У `svcsec` есть команда **`super`**
3. После `super` запрашивается **пароль УЗ `svcsecadmin`**
4. Открывается сессия `svcsecadmin` (есть права `sudo`)
5. Уже из `svcsecadmin` можно перейти в `root` через `sudo`

Схема для РЕД ОС 7.3 / 8 (RHEL-подобная: `sshd`, `sudo`, `wheel`, SELinux).

| Роль | УЗ | Назначение |
|---|---|---|
| Вход по SSH | `svcsec` | единственный пользователь для удалённого входа |
| Команда `super` | запускает `svcsec` | переключение на `svcsecadmin` с запросом пароля |
| Админ с sudo | `svcsecadmin` | локальная привилегированная УЗ, вход по SSH запрещён |
| Root | `root` | только через `sudo` от `svcsecadmin` |

| Параметр | Значение |
|---|---|
| Команда | `/usr/local/bin/super` |
| SSH-ограничение | `AllowUsers svcsec` |
| Группа для файла `super` | `superusers` (только `svcsec`) |

---

## Содержание

1. [Целевая схема](#целевая-схема)
2. [Порядок настройки](#порядок-настройки)
3. [Создание пользователей](#создание-пользователей)
4. [Права sudo у svcsecadmin](#права-sudo-у-svcsecadmin)
5. [Команда super](#команда-super)
6. [SSH: вход только для svcsec](#ssh-вход-только-для-svcsec)
7. [Проверка от начала до конца](#проверка-от-начала-до-конца)
8. [Клиентский SSH-конфиг](#клиентский-ssh-конфиг)
9. [Логирование и аудит](#логирование-и-аудит)
10. [Типичные ошибки](#типичные-ошибки)
11. [Откат](#откат)
12. [Итоговый чек-лист](#итоговый-чек-лист)

---

## Целевая схема

```text
Клиент SSH
    │
    │  ssh svcsec@server   (другие УЗ по SSH — отказ)
    ▼
сессия svcsec
    │
    │  super
    │  Password: ********   ← пароль svcsecadmin
    ▼
сессия svcsecadmin
    │
    │  sudo -i   (или sudo su -)
    │  [sudo] password for svcsecadmin:
    ▼
root
```

Что **не** должно работать:

- SSH под `svcsecadmin`
- SSH под `root`
- запуск `super` от любого пользователя, кроме `svcsec`
- прямой `sudo` у `svcsec` к root (по этой схеме не нужен)

---

## Порядок настройки

Делайте на консоли или из уже рабочей SSH-сессии с правами администратора.  
Если настраиваете удалённо — **не закрывайте** текущую сессию, пока не проверите вход под `svcsec` из второго терминала.

1. Создать/проверить УЗ `svcsec` и `svcsecadmin`  
2. Дать `svcsecadmin` права `sudo` (группа `wheel`)  
3. Создать команду `/usr/local/bin/super` (только для `svcsec`, внутри — `su - svcsecadmin`)  
4. Ограничить SSH: только `svcsec`  
5. Проверить цепочку: SSH → `super` → `sudo -i`

---

## Создание пользователей

### svcsec — вход по SSH

```bash
# если пользователя ещё нет
sudo useradd -m -s /bin/bash svcsec
sudo passwd svcsec

# для входа по ключу (предпочтительно)
sudo mkdir -p /home/svcsec/.ssh
sudo chmod 700 /home/svcsec/.ssh
# положите публичный ключ в authorized_keys
# sudo tee /home/svcsec/.ssh/authorized_keys < /path/to/svcsec.pub
sudo chmod 600 /home/svcsec/.ssh/authorized_keys
sudo chown -R svcsec:svcsec /home/svcsec/.ssh
```

`svcsec` **не** обязан быть в группе `wheel`. Для повседневной работы ему достаточно `super`.

### svcsecadmin — локальный админ с sudo

```bash
sudo useradd -m -s /bin/bash svcsecadmin
sudo passwd svcsecadmin
sudo usermod -aG wheel svcsecadmin
```

Проверка групп:

```bash
id svcsec
id svcsecadmin
# svcsecadmin должен содержать wheel
```

> Пароль `svcsecadmin` будет запрашиваться при каждом `super`. Храните его отдельно от пароля/ключа `svcsec`.

---

## Права sudo у svcsecadmin

Проверьте, что группа `wheel` разрешена в sudoers:

```bash
sudo grep -E '^%wheel|^# %wheel' /etc/sudoers
```

Нужна активная строка:

```text
%wheel  ALL=(ALL)       ALL
```

Если закомментировано:

```bash
sudo visudo
```

Раскомментируйте `%wheel ALL=(ALL) ALL`.

Проверка от имени `svcsecadmin` (локально или после `super`):

```bash
sudo -l
sudo whoami
# root
```

Опционально: отдельное правило только для `svcsecadmin` (вместо/дополнительно к wheel):

```bash
sudo visudo -f /etc/sudoers.d/svcsecadmin
```

```text
svcsecadmin ALL=(ALL) ALL
```

```bash
sudo chmod 440 /etc/sudoers.d/svcsecadmin
sudo visudo -c
```

---

## Команда `super`

Идея: `super` — обёртка над `su - svcsecadmin`.  
`su` запросит **пароль `svcsecadmin`**.  
Запускать файл может только `svcsec` (права на бинарник + проверка внутри скрипта).

### 1) Группа доступа к команде

```bash
sudo groupadd -f superusers
sudo usermod -aG superusers svcsec
```

Пользователь `svcsec` должен перелогиниться (или `newgrp superusers`), чтобы группа применилась в текущей сессии.

### 2) Скрипт

```bash
sudo tee /usr/local/bin/super << 'EOF'
#!/bin/bash
# super: svcsec -> svcsecadmin (пароль svcsecadmin)
set -euo pipefail

ALLOWED_USER="svcsec"
TARGET_USER="svcsecadmin"

CURRENT_USER="$(id -un)"

if [ "$CURRENT_USER" != "$ALLOWED_USER" ]; then
  echo "Доступ запрещён: команду super может запускать только ${ALLOWED_USER}" >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "Не запускайте super от root. Войдите как ${ALLOWED_USER}." >&2
  exit 1
fi

# Запрос пароля TARGET_USER и login-shell
exec /usr/bin/su - "$TARGET_USER"
EOF
```

Права: владелец root, группа `superusers`, выполнять могут только они:

```bash
sudo chown root:superusers /usr/local/bin/super
sudo chmod 750 /usr/local/bin/super
# проверка
ls -l /usr/local/bin/super
# -rwxr-x---. 1 root superusers ... /usr/local/bin/super
```

Почему так:

- `750` + группа `superusers` → другие локальные УЗ файл не запустят  
- проверка `CURRENT_USER` → даже при ошибочных правах сработает отказ  
- `su - svcsecadmin` → нужен пароль именно `svcsecadmin`, без NOPASSWD sudo

### 3) PATH

`/usr/local/bin` обычно уже в PATH. Проверка от `svcsec`:

```bash
su - svcsec -c 'command -v super; type super'
```

Если команда не находится:

```bash
# в профиле svcsec
echo 'export PATH="/usr/local/bin:$PATH"' | sudo tee -a /home/svcsec/.bashrc
```

### 4) Важно: не путать с sudo NOPASSWD

Для этой схемы **не нужно** правило вида:

```text
svcsec ALL=(root) NOPASSWD: /usr/local/bin/super
```

Иначе можно случайно обойти запрос пароля `svcsecadmin` (если внутри скрипта использовать `runuser`/`sudo -u` от root).  
Здесь намеренно используется обычный `su`, чтобы пароль спрашивался всегда.

---

## SSH: вход только для svcsec

Нужно запретить SSH для `svcsecadmin`, `root` и любых других УЗ.

### Drop-in конфиг (предпочтительно)

```bash
sudo tee /etc/ssh/sshd_config.d/99-allow-svcsec-only.conf << 'EOF'
# Удалённый вход только под svcsec
AllowUsers svcsec

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
```

Если парольный вход для `svcsec` всё же нужен (хуже по безопасности):

```text
PasswordAuthentication yes
```

Но лучше ключи.

### Проверка, что нет конфликтов

```bash
grep -RniE '^\s*(AllowUsers|DenyUsers|PermitRootLogin)\b' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
```

Если где-то уже есть другой `AllowUsers` — оставьте **один** итоговый список. При нескольких `AllowUsers` поведение зависит от порядка include; надёжнее держать правило в одном файле.

### Применить

```bash
sudo sshd -t
sudo systemctl restart sshd
sudo systemctl status sshd --no-pager
```

### Проверки доступа

Со **второго** терминала:

```bash
# должно работать
ssh svcsec@SERVER_IP

# должно быть отказано
ssh svcsecadmin@SERVER_IP
ssh root@SERVER_IP
```

Дополнительно можно явно запретить админскую УЗ:

```text
DenyUsers svcsecadmin root
AllowUsers svcsec
```

`AllowUsers svcsec` уже достаточно, если других пользователей в списке нет.

> Если у вас также сменён порт SSH / ограничение по IP — совместите с инструкцией [`redos-ssh-port-selinux.md`](redos-ssh-port-selinux.md): в `AllowUsers` должен остаться только `svcsec` (при необходимости `svcsec@IP`).

Пример совмещения с IP:

```text
AllowUsers svcsec@203.0.113.50
PermitRootLogin no
```

---

## Проверка от начала до конца

### 1) SSH под svcsec

```bash
ssh svcsec@SERVER_IP
whoami
# svcsec
```

### 2) Команда super

```bash
super
# Password:   ← введите пароль svcsecadmin
whoami
# svcsecadmin
id
# ... groups=...wheel...
```

### 3) Root через sudo

```bash
sudo -i
# [sudo] password for svcsecadmin:
whoami
# root
```

Или без полной login-shell:

```bash
sudo whoami
# root
sudo -u root -i
```

### 4) Негативные проверки

```bash
# от другого локального пользователя (если есть)
su - otheruser -c 'super'
# Permission denied / Доступ запрещён

# SSH чужой УЗ
ssh svcsecadmin@SERVER_IP
# Permission denied
```

---

## Клиентский SSH-конфиг

На рабочей станции (`~/.ssh/config`):

```sshconfig
Host redos-sec
    HostName 192.0.2.10
    User svcsec
    Port 22
    # Port 2242
    IdentityFile ~/.ssh/id_ed25519_svcsec
    IdentitiesOnly yes
```

Подключение:

```bash
ssh redos-sec
super
sudo -i
```

Права на клиенте:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config ~/.ssh/id_ed25519_svcsec
```

---

## Логирование и аудит

Полезные журналы на РЕД ОС:

```bash
# SSH-входы
sudo grep -E 'sshd|Accepted|Failed' /var/log/secure | tail -n 50

# su / super
sudo grep -E 'su:|sudo:' /var/log/secure | tail -n 50

# journald
sudo journalctl -u sshd -e --no-pager
```

Успешный `super` обычно виден как `su` от `svcsec` к `svcsecadmin`.  
`sudo` от `svcsecadmin` к root — отдельными записями `sudo`.

---

## Типичные ошибки

| Симптом | Причина | Решение |
|---|---|---|
| `super: command not found` | нет в PATH / нет файла | проверить `/usr/local/bin/super`, PATH у `svcsec` |
| `Permission denied` при запуске `super` | не в группе `superusers` или chmod не 750 | `id svcsec`, перелогин, `chown root:superusers`, `chmod 750` |
| `Доступ запрещён: ... только svcsec` | запущено не от `svcsec` | войти по SSH как `svcsec` |
| `su: Authentication failure` | неверный пароль `svcsecadmin` | `passwd svcsecadmin` (от уже имеющегося админа) |
| `svcsecadmin is not in the sudoers file` | нет `wheel` / правила sudo | `usermod -aG wheel svcsecadmin`, проверить `%wheel` в sudoers |
| SSH пускает `svcsecadmin` | нет/не применён `AllowUsers` | drop-in + `sshd -t` + `systemctl restart sshd` |
| После правки SSH потеряли доступ | ошибочный `AllowUsers` | чинить с консоли/IPMI; вернуть бэкап `sshd_config` |
| `super` не просит пароль и сразу root | ошибочно настроен NOPASSWD/`runuser` от root | вернуть скрипт на `exec /usr/bin/su - svcsecadmin` |

Бэкап SSH перед правками:

```bash
sudo cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F_%H%M%S)"
```

---

## Откат

```bash
# убрать команду
sudo rm -f /usr/local/bin/super
sudo groupdel superusers 2>/dev/null || true

# убрать SSH-ограничение (осторожно: снова откроет вход другим УЗ)
sudo rm -f /etc/ssh/sshd_config.d/99-allow-svcsec-only.conf
sudo sshd -t && sudo systemctl restart sshd

# при необходимости удалить УЗ (только если уверены)
# sudo userdel -r svcsecadmin
```

---

## Итоговый чек-лист

```bash
# === пользователи ===
sudo useradd -m -s /bin/bash svcsec        2>/dev/null || true
sudo useradd -m -s /bin/bash svcsecadmin   2>/dev/null || true
sudo passwd svcsec
sudo passwd svcsecadmin
sudo usermod -aG wheel svcsecadmin

# === группа и команда super ===
sudo groupadd -f superusers
sudo usermod -aG superusers svcsec

sudo tee /usr/local/bin/super << 'EOF'
#!/bin/bash
set -euo pipefail
ALLOWED_USER="svcsec"
TARGET_USER="svcsecadmin"
CURRENT_USER="$(id -un)"
[ "$CURRENT_USER" = "$ALLOWED_USER" ] || { echo "Доступ запрещён: только ${ALLOWED_USER}" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Не запускайте super от root." >&2; exit 1; }
exec /usr/bin/su - "$TARGET_USER"
EOF
sudo chown root:superusers /usr/local/bin/super
sudo chmod 750 /usr/local/bin/super

# === SSH только svcsec ===
sudo tee /etc/ssh/sshd_config.d/99-allow-svcsec-only.conf << 'EOF'
AllowUsers svcsec
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
sudo sshd -t && sudo systemctl restart sshd

# === проверки ===
# 1) ssh svcsec@SERVER
# 2) newgrp superusers   # если группа ещё не подхватилась
# 3) super               # пароль svcsecadmin
# 4) sudo -i             # пароль svcsecadmin
# 5) ssh svcsecadmin@SERVER  → отказ
```

Итог после настройки:

- по SSH заходит только `svcsec`
- `super` доступен только `svcsec` и спрашивает пароль `svcsecadmin`
- `svcsecadmin` получает shell с `sudo`
- `root` — только через `sudo` от `svcsecadmin`
