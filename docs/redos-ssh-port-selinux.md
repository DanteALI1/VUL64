# РЕД ОС: SSH — смена порта, SELinux, доступ только с определённых IP

Пошаговая инструкция: как на **РЕД ОС** перенести SSH с порта `22` на `2242` (или любой другой), корректно настроить **SELinux**, **firewalld**, `/etc/ssh/sshd_config` и ограничить подключения по IP.

Схема подходит для РЕД ОС 7.3 / 8 (семейство RHEL: `sshd`, `firewalld`, SELinux в режиме Enforcing).

| Параметр | Значение в примерах |
|---|---|
| Старый порт | `22` |
| Новый порт | `2242` |
| Разрешённый IP клиента | `203.0.113.50` |
| Опционально: подсеть | `203.0.113.0/24` |
| Конфиг сервера | `/etc/ssh/sshd_config` |
| Конфиг клиента | `~/.ssh/config` |

Замените порт и IP на свои.

> **Важно:** не закрывайте текущую SSH-сессию, пока не проверите вход на новом порту из **второй** сессии. Иначе можно потерять доступ к серверу.

---

## Содержание

1. [Цель и порядок работ](#цель-и-порядок-работ)
2. [Перед началом: проверка и бэкап](#перед-началом-проверка-и-бэкап)
3. [SELinux: разрешить новый порт](#selinux-разрешить-новый-порт)
4. [firewalld: открыть новый порт](#firewalld-открыть-новый-порт)
5. [Ограничение доступа по IP в firewalld](#ограничение-доступа-по-ip-в-firewalld)
6. [Настройка sshd_config](#настройка-sshd_config)
7. [Ограничение по IP в SSH](#ограничение-по-ip-в-ssh)
8. [Перезапуск sshd и проверка](#перезапуск-sshd-и-проверка)
9. [Закрыть старый порт 22](#закрыть-старый-порт-22)
10. [Клиентский SSH-конфиг](#клиентский-ssh-конфиг)
11. [Дополнительные рекомендации по безопасности](#дополнительные-рекомендации-по-безопасности)
12. [Откат](#откат)
13. [Типичные ошибки](#типичные-ошибки)
14. [Чек-лист от начала до конца](#чек-лист-от-начала-до-конца)

---

## Цель и порядок работ

Нужно получить:

```bash
ssh -p 2242 user@server
# подключение только с разрешённого IP
```

**Правильный порядок** (чтобы не потерять доступ и не упереться в SELinux/firewall):

1. Бэкап конфигов, оставить текущую сессию открытой  
2. SELinux — разрешить порт `2242` для SSH  
3. firewalld — открыть `2242/tcp` (пока **не** закрывать `22`)  
4. Ограничить источник по IP (firewalld и/или sshd)  
5. Правки в `sshd_config` (временно слушать и `22`, и `2242`)  
6. `sshd -t` → restart → проверка со **второго** терминала  
7. Только после успешной проверки — убрать порт `22`

Если сначала сменить порт в `sshd` и сразу закрыть `22`, а SELinux/firewall не настроить — сервис либо не поднимется на новом порту, либо вход будет заблокирован.

---

## Перед началом: проверка и бэкап

Выполняйте от пользователя с `sudo` (или от root).

### Текущее состояние

```bash
# версия ОС
cat /etc/redos-release 2>/dev/null || cat /etc/os-release

# статус SSH
systemctl status sshd --no-pager

# на каких портах слушает sshd
ss -tlnp | grep sshd

# SELinux
getenforce
sestatus

# firewall
systemctl is-active firewalld
sudo firewall-cmd --state
sudo firewall-cmd --list-all
```

Ожидаемо на РЕД ОС:

- `getenforce` → `Enforcing` (или `Permissive`)
- активен `firewalld`
- SSH слушает `0.0.0.0:22` и/или `[::]:22`

### Бэкап

```bash
sudo cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F_%H%M%S)"
sudo cp -a /etc/ssh/sshd_config.d "/etc/ssh/sshd_config.d.bak.$(date +%F_%H%M%S)" 2>/dev/null || true

# если уже есть кастомные правила SELinux/firewall — полезно сохранить вывод
sudo semanage port -l | grep ssh > /tmp/selinux-ssh-ports.txt
sudo firewall-cmd --list-all > /tmp/firewall-before.txt
```

### Пакеты для SELinux (если нет `semanage`)

```bash
# РЕД ОС 8 / 7.3
sudo dnf install -y policycoreutils-python-utils
# на части сборок пакет может называться:
# sudo dnf install -y policycoreutils-python
```

Проверка:

```bash
which semanage
semanage port -l | grep ssh_port_t
```

Обычно по умолчанию:

```text
ssh_port_t     tcp      22
```

---

## SELinux: разрешить новый порт

В режиме **Enforcing** SSH на нестандартном порту **не заработает**, пока порт не помечен типом `ssh_port_t`.

### Добавить порт 2242

```bash
# добавить новый порт (если ещё не добавлен)
sudo semanage port -a -t ssh_port_t -p tcp 2242
```

Если порт уже был в политике ранее:

```bash
# изменить существующую запись
sudo semanage port -m -t ssh_port_t -p tcp 2242
```

Если получите ошибку вроде `Port tcp/2242 already defined` — используйте `-m` (modify) или сначала удалите:

```bash
sudo semanage port -d -t ssh_port_t -p tcp 2242
sudo semanage port -a -t ssh_port_t -p tcp 2242
```

### Проверка

```bash
sudo semanage port -l | grep ssh_port_t
```

Ожидаемый результат (пример):

```text
ssh_port_t     tcp      2242, 22
```

### Если SELinux выключен

```bash
getenforce
# Disabled
```

Тогда шаг с `semanage` не блокирует SSH, но **всё равно рекомендуется** добавить порт: при будущем включении SELinux сервис снова «сломается» на нестандартном порту.

Просмотр отказов SELinux (если что-то не так):

```bash
sudo ausearch -m AVC -ts recent | grep ssh
# или
sudo journalctl -t setroubleshoot -e
```

---

## firewalld: открыть новый порт

Пока **не закрывайте** порт `22`. Сначала откройте новый.

### Вариант A — просто открыть порт (без ограничения по IP)

```bash
# runtime + permanent
sudo firewall-cmd --add-port=2242/tcp
sudo firewall-cmd --permanent --add-port=2242/tcp
sudo firewall-cmd --reload
```

Проверка:

```bash
sudo firewall-cmd --list-ports
sudo firewall-cmd --list-all
```

### Вариант B — через сервис ssh (если меняете стандартный порт сервиса)

Можно переопределить порты сервиса `ssh` в firewalld, но для явного контроля чаще удобнее работать с портом `2242/tcp` напрямую (вариант A + rich rules ниже).

---

## Ограничение доступа по IP в firewalld

Рекомендуемый слой защиты на сети: принимать SSH **только** с нужных адресов.

Пример: разрешить `203.0.113.50` → порт `2242/tcp`, остальным — отказ.

```bash
# разрешить конкретный IP
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="203.0.113.50" port port="2242" protocol="tcp" accept'

# (опционально) разрешить подсеть
# sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="203.0.113.0/24" port port="2242" protocol="tcp" accept'

# явно отклонять остальных на этом порту (если порт/сервис уже открыт широко)
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port port="2242" protocol="tcp" drop'

sudo firewall-cmd --reload
```

> Порядок rich rules важен: более специфичные `accept` должны срабатывать до общего `drop`. В firewalld rich rules обычно обрабатываются до простых `--add-port`, но безопаснее **не** держать «открыто для всех» `--add-port=2242/tcp`, если уже используете rich rules с `accept` + `drop`.

Если ранее открывали порт для всех:

```bash
sudo firewall-cmd --permanent --remove-port=2242/tcp
sudo firewall-cmd --reload
```

И оставьте только rich rules.

Просмотр правил:

```bash
sudo firewall-cmd --list-rich-rules
sudo firewall-cmd --list-all
```

### Несколько IP

```bash
for ip in 203.0.113.50 198.51.100.10; do
  sudo firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"$ip\" port port=\"2242\" protocol=\"tcp\" accept"
done
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port port="2242" protocol="tcp" drop'
sudo firewall-cmd --reload
```

### IPv6 (если нужно)

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv6" source address="2001:db8::1" port port="2242" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv6" port port="2242" protocol="tcp" drop'
sudo firewall-cmd --reload
```

---

## Настройка sshd_config

Основной файл: `/etc/ssh/sshd_config`.  
На РЕД ОС 8 часто используют дропы в `/etc/ssh/sshd_config.d/*.conf` — так чище и проще откатывать.

### Рекомендуемый способ: отдельный drop-in

```bash
sudo tee /etc/ssh/sshd_config.d/99-custom-port.conf << 'EOF'
# Временно слушаем оба порта (22 и 2242).
# После проверки со второго терминала уберите строку Port 22.
Port 22
Port 2242

# По желанию: слушать только на конкретном интерфейсе/IP сервера
# ListenAddress 192.0.2.10
# ListenAddress 192.0.2.10:2242
EOF
```

Если в основном `sshd_config` уже есть активный `Port 22`, наличие нескольких директив `Port` допустимо: sshd будет слушать все указанные порты.  
Убедитесь, что нет конфликтующих include-файлов:

```bash
grep -RniE '^\s*Port\s+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
```

### Правка основного файла (альтернатива)

```bash
sudo cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo sed -i 's/^#\?Port .*/Port 2242/' /etc/ssh/sshd_config
# если строки Port не было — добавьте:
grep -qE '^\s*Port\s+' /etc/ssh/sshd_config || echo 'Port 2242' | sudo tee -a /etc/ssh/sshd_config
```

Для безопасного перехода лучше **сначала** держать оба порта (`Port 22` и `Port 2242`), как в drop-in выше.

### Проверка синтаксиса (обязательно)

```bash
sudo sshd -t
# тишина = OK
# при ошибке — НЕ перезапускайте сервис, сначала исправьте конфиг
```

---

## Ограничение по IP в SSH

Firewall — первый рубеж. Второй — сам `sshd` (на случай ошибки в firewall или доступа «изнутри»).

### Способ 1: `AllowUsers` / `AllowGroups` с хостами

В drop-in:

```bash
sudo tee /etc/ssh/sshd_config.d/99-allow-from.conf << 'EOF'
# Разрешить пользователя ivan только с одного IP
AllowUsers ivan@203.0.113.50

# Несколько пользователей / IP:
# AllowUsers ivan@203.0.113.50 admin@203.0.113.50 ivan@198.51.100.10

# Или по группе:
# AllowGroups wheel
EOF
```

Формат `user@host` ограничивает и пользователя, и источник.

Для схемы «по SSH только `svcsec`, дальше `super` → `svcsecadmin`» используйте:

```text
AllowUsers svcsec
# или с IP: AllowUsers svcsec@203.0.113.50
```

Подробности цепочки доступа: [`redos-super-command.md`](redos-super-command.md).

### Способ 2: блок `Match Address` (гибче)

```bash
sudo tee /etc/ssh/sshd_config.d/99-match-address.conf << 'EOF'
# По умолчанию запретить вход паролем всем (пример политики)
PasswordAuthentication no
PubkeyAuthentication yes

# Для разрешённого IP можно ослабить/уточнить правила
Match Address 203.0.113.50
    PasswordAuthentication no
    PubkeyAuthentication yes

# Пример: запретить всех остальных явным Match в конце
# (если не используете AllowUsers)
# Match Address *,!203.0.113.50
#     DenyUsers *
EOF
```

Практичный минимальный вариант «только с IP X»:

```bash
sudo tee /etc/ssh/sshd_config.d/99-allow-from.conf << 'EOF'
AllowUsers ivan@203.0.113.50
Port 22
Port 2242
EOF
```

> Директивы `Match` должны стоять **в конце** логики конфига; после `Match` обычные глобальные директивы уже не действуют так, как до блока. Поэтому для кастомизации удобны отдельные файлы с говорящими именами и проверка `sshd -T`.

Показать итоговые параметры:

```bash
sudo sshd -T | grep -Ei 'port|allowusers|allowgroups|listenaddress|passwordauthentication|pubkeyauthentication'
```

Снова проверка синтаксиса:

```bash
sudo sshd -t
```

---

## Перезапуск sshd и проверка

```bash
sudo systemctl restart sshd
sudo systemctl status sshd --no-pager
ss -tlnp | grep sshd
```

Ожидаемо увидеть и `:22`, и `:2242` (на этапе перехода).

### Проверка с клиента (второй терминал)

```bash
# с разрешённого IP
ssh -p 2242 ivan@SERVER_IP

# явно
ssh -vvv -p 2242 ivan@SERVER_IP
```

Проверка, что чужой IP не пускает (с другой машины / через VPN с другим адресом):

```bash
ssh -p 2242 ivan@SERVER_IP
# timeout / No route / Connection refused / Permission denied — в зависимости от слоя (firewall vs sshd)
```

Пока старая сессия на порту `22` открыта — не закрывайте её.

Логи на сервере:

```bash
sudo journalctl -u sshd -e --no-pager
sudo tail -n 50 /var/log/secure
```

---

## Закрыть старый порт 22

Только после успешного входа на `2242` из второй сессии.

### 1) Убрать Port 22 из sshd

Отредактируйте drop-in:

```bash
sudo tee /etc/ssh/sshd_config.d/99-custom-port.conf << 'EOF'
Port 2242
EOF
```

Если `AllowUsers` у вас в том же файле — сохраните их. Пример итогового файла:

```bash
sudo tee /etc/ssh/sshd_config.d/99-custom-port.conf << 'EOF'
Port 2242
AllowUsers ivan@203.0.113.50
EOF
```

Проверка и restart:

```bash
sudo sshd -t && sudo systemctl restart sshd
ss -tlnp | grep sshd
```

Должен остаться только `2242`.

### 2) Закрыть 22 в firewalld

```bash
# если был открыт сервис ssh на 22
sudo firewall-cmd --permanent --remove-service=ssh

# если порт 22 добавляли явно
sudo firewall-cmd --permanent --remove-port=22/tcp

# на всякий случай — drop на 22 (опционально)
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port port="22" protocol="tcp" drop'

sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```

### 3) SELinux: порт 22 можно оставить в политике

Оставлять `22` в `ssh_port_t` обычно безопасно (это дефолт). Удалять не обязательно. Если хотите только новый порт в политике:

```bash
# не удаляйте 22 без необходимости — на части политик это дефолтная запись
sudo semanage port -l | grep ssh_port_t
```

---

## Клиентский SSH-конфиг

На машине, с которой подключаетесь (`~/.ssh/config`):

```sshconfig
Host redos-prod
    HostName 192.0.2.10
    User ivan
    Port 2242
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    # ServerAliveInterval 30
    # ServerAliveCountMax 3
```

Подключение:

```bash
ssh redos-prod
```

Несколько серверов / прыжок через bastion:

```sshconfig
Host bastion
    HostName 203.0.113.50
    User ivan
    Port 2242
    IdentityFile ~/.ssh/id_ed25519

Host redos-internal
    HostName 10.0.0.20
    User ivan
    Port 2242
    ProxyJump bastion
    IdentityFile ~/.ssh/id_ed25519
```

Права на клиенте:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub
```

Проверка с клиента без алиаса:

```bash
ssh -p 2242 ivan@192.0.2.10
```

---

## Дополнительные рекомендации по безопасности

Не обязательно для смены порта, но полезно сразу зафиксировать в том же drop-in:

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
# Только нужный протокол
Protocol 2
EOF

sudo sshd -t && sudo systemctl restart sshd
```

Перед отключением паролей убедитесь, что вход по ключу уже работает.

Ключ на сервер (с клиента):

```bash
ssh-copy-id -p 2242 ivan@192.0.2.10
# или вручную: публичный ключ в ~/.ssh/authorized_keys на сервере, chmod 600
```

---

## Откат

Если новый порт не принял соединения, а старая сессия ещё жива:

```bash
# вернуть конфиг из бэкапа
sudo cp -a /etc/ssh/sshd_config.bak.YYYY-MM-DD_HHMMSS /etc/ssh/sshd_config
sudo rm -f /etc/ssh/sshd_config.d/99-custom-port.conf
sudo rm -f /etc/ssh/sshd_config.d/99-allow-from.conf
sudo rm -f /etc/ssh/sshd_config.d/99-match-address.conf

sudo sshd -t && sudo systemctl restart sshd

# firewall: вернуть ssh/22 при необходимости
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload
```

Удалить порт из SELinux (если добавляли ошибочно):

```bash
sudo semanage port -d -t ssh_port_t -p tcp 2242
```

---

## Типичные ошибки

| Симптом | Частая причина | Что сделать |
|---|---|---|
| `Connection refused` на 2242 | sshd не слушает порт / конфиг не применился | `ss -tlnp \| grep sshd`, `sshd -t`, `systemctl status sshd` |
| `Connection timed out` | firewalld / внешний ACL / неверный IP | `firewall-cmd --list-all`, проверить rich rules и source IP |
| После смены порта sshd не стартует | SELinux блокирует порт | `semanage port -a -t ssh_port_t -p tcp 2242`, смотреть AVC в `ausearch` |
| Вход есть с любого IP | открыт `--add-port` для всех и нет `AllowUsers` | убрать широкий порт, добавить rich rule + `AllowUsers user@ip` |
| `Permission denied` с правильного IP | неверный пользователь/ключ или `AllowUsers` | `sshd -T \| grep allowusers`, логи `/var/log/secure` |
| Работает только пока сессия жива | забыли `permanent` в firewalld | правила с `--permanent` + `--reload` |
| Конфликт include-файлов | несколько `Port` / `Match` в разных drop-in | `grep -RniE 'Port\|Match\|AllowUsers' /etc/ssh/` |

Диагностика SELinux:

```bash
sudo ausearch -m AVC -ts recent
sudo sealert -a /var/log/audit/audit.log 2>/dev/null | head
```

Диагностика firewall:

```bash
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --list-all
sudo firewall-cmd --list-rich-rules
```

---

## Чек-лист от начала до конца

Выполняйте по порядку на сервере РЕД ОС.

```bash
# === 0) подготовка ===
sudo cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F_%H%M%S)"
getenforce
sudo dnf install -y policycoreutils-python-utils

# === 1) SELinux ===
sudo semanage port -a -t ssh_port_t -p tcp 2242 || sudo semanage port -m -t ssh_port_t -p tcp 2242
sudo semanage port -l | grep ssh_port_t

# === 2) firewalld: доступ только с IP 203.0.113.50 на 2242 ===
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="203.0.113.50" port port="2242" protocol="tcp" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port port="2242" protocol="tcp" drop'
# пока НЕ удаляйте service ssh / порт 22
sudo firewall-cmd --reload

# === 3) sshd: оба порта + allow с IP ===
sudo tee /etc/ssh/sshd_config.d/99-custom-port.conf << 'EOF'
Port 22
Port 2242
AllowUsers ivan@203.0.113.50
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
sudo sshd -t

# === 4) применить ===
sudo systemctl restart sshd
ss -tlnp | grep sshd

# === 5) со ВТОРОГО терминала с разрешённого IP ===
# ssh -p 2242 ivan@SERVER_IP

# === 6) после успешной проверки — только 2242 ===
sudo tee /etc/ssh/sshd_config.d/99-custom-port.conf << 'EOF'
Port 2242
AllowUsers ivan@203.0.113.50
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
sudo sshd -t && sudo systemctl restart sshd

sudo firewall-cmd --permanent --remove-service=ssh
sudo firewall-cmd --permanent --remove-port=22/tcp 2>/dev/null || true
sudo firewall-cmd --reload

# === 7) клиент ~/.ssh/config ===
# Host redos-prod
#   HostName SERVER_IP
#   User ivan
#   Port 2242
#   IdentityFile ~/.ssh/id_ed25519
```

Итог:

- SSH слушает **2242**
- SELinux знает порт как `ssh_port_t`
- firewalld пускает только выбранный IP
- `sshd` дополнительно ограничивает `AllowUsers user@ip`
- клиент подключается через `~/.ssh/config` без ручного `-p`

Если нужен другой порт — везде замените `2242` на нужный (SELinux + firewalld + `Port` + клиентский конфиг).
