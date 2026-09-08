# Ansible на РЕД ОС: установка и базовая настройка

Подробная инструкция по установке [Ansible](https://docs.ansible.com/) на **РЕД ОС** (управляющая машина — control node) и первичной настройке для управления удалёнными узлами.

Основано на [базе знаний РЕД ОС 8](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-remote-admin/8_0-ansible/) и [РЕД ОС 7.3](https://redos.red-soft.ru/base/redos-7_3/7_3-administation/7_3-remote-admin/7_3-ansible/).

| Параметр | РЕД ОС 8 | РЕД ОС 7.3 |
|---|---|---|
| Менеджер пакетов | `dnf` | `dnf` |
| Типичный пакет | `ansible` (из основных репозиториев) | `ansible` (2.9.x) или Ansible 6.x через `ansible6-release` |
| Пример версии из БЗ | ansible-9.2.0-1 | ansible-2.9.21-2 / ansible-6.7.0-1 |
| Протокол к узлам | SSH (ключи или пароль + `sshpass`) | то же |

Ansible — система управления конфигурациями: описываете желаемое состояние в **плейбуках** (YAML), агент на управляемых узлах **не нужен** (достаточно SSH и Python).

> **Роли:** Ansible ставится на **управляющую** машину. На управляемых узлах достаточно SSH и Python 3 (на РЕД ОС обычно уже есть).

Готовый скрипт «всё сразу»: [`scripts/install-ansible-redos.sh`](../scripts/install-ansible-redos.sh).

---

## Содержание

1. [Требования](#требования)
2. [Установка на РЕД ОС 8](#установка-на-ред-ос-8)
3. [Установка на РЕД ОС 7.3](#установка-на-ред-ос-73)
4. [Проверка установки](#проверка-установки)
5. [Инвентаризация (hosts)](#инвентаризация-hosts)
6. [SSH-ключи на управляемые узлы](#ssh-ключи-на-управляемые-узлы)
7. [Защищённый каталог ключей (один владелец)](#защищённый-каталог-ключей-один-владелец)
8. [Проверка связи (ping)](#проверка-связи-ping)
9. [Аутентификация по паролю](#аутентификация-по-паролю)
10. [Собственные inventory](#собственные-inventory)
11. [Одиночные команды](#одиночные-команды)
12. [Плейбук: пример](#плейбук-пример)
13. [Привилегии become / sudo](#привилегии-become--sudo)
14. [Проверка синтаксиса](#проверка-синтаксиса)
15. [Базовый ansible.cfg](#базовый-ansiblecfg)
16. [Типичные проблемы](#типичные-проблемы)
17. [Готовый скрипт](#готовый-скрипт)

---

## Требования

**Управляющая машина (control node):**

- РЕД ОС 7.3 или 8 (x86_64)
- доступ в интернет / к репозиториям РЕД ОС
- права `sudo` / root
- исходящий SSH на управляемые узлы (порт 22 или ваш)

**Управляемые узлы (managed nodes):**

- SSH-сервер
- Python 3 (`/usr/bin/python3`)
- для установки пакетов через модуль `dnf` — привилегии sudo/root на узле

---

## Установка на РЕД ОС 8

Пакет Ansible есть в стандартных репозиториях.

```bash
# обновить кэш метаданных (по желанию)
sudo dnf makecache

# установить Ansible
sudo dnf install -y ansible

# полезно для подключения по паролю SSH (не только по ключу)
sudo dnf install -y sshpass
```

Проверка:

```bash
ansible --version
```

Ожидается вывод с версией ansible / ansible-core и путями к конфигу.

---

## Установка на РЕД ОС 7.3

### Вариант A — Ansible из основных репозиториев (часто 2.9.x)

```bash
sudo dnf install -y ansible
sudo dnf install -y sshpass
```

### Вариант B — Ansible 6.x (подключаемый репозиторий)

Пакеты Ansible 6.x лежат в отдельном репозитории. Порядок из БЗ РЕД ОС:

```bash
sudo dnf install -y ansible6-release
sudo dnf clean all
sudo dnf makecache
sudo dnf install -y ansible
sudo dnf install -y sshpass
```

Скрипт установки поддерживает флаг `--ansible6` для этого сценария.

---

## Проверка установки

```bash
ansible --version
which ansible ansible-playbook ansible-galaxy
rpm -q ansible || rpm -qa 'ansible*'
```

Если команда `ansible` не найдена — проверьте, что пакет установился и `$PATH` содержит `/usr/bin`.

---

## Инвентаризация (hosts)

Список управляемых узлов по умолчанию: **`/etc/ansible/hosts`**.

```bash
sudo nano /etc/ansible/hosts
```

Пример:

```ini
# Группа серверов
[web]
web1.example.ru
192.168.0.100

[db]
db1.example.ru ansible_host=192.168.0.101

# Диапазон имён: node01 … node10
[batch]
node[01:10].example.ru

# Псевдоним: обращение по короткому имени
[aliases]
app1 ansible_host=node.example.ru ansible_user=admin
```

Пояснения:

| Запись | Смысл |
|---|---|
| `[group_name]` | имя группы хостов |
| `host ansible_host=IP` | DNS/алиас → реальный адрес |
| `ansible_user=login` | пользователь SSH на этом хосте |
| `node[01:10].example.ru` | диапазон хостов |

Группы можно объединять:

```ini
[prod:children]
web
db
```

---

## SSH-ключи на управляемые узлы

Рекомендуемый способ — **ключи**, без пароля при каждом запуске.

### 1. Сгенерировать ключ на управляющей машине

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)-$(date -I)" -f ~/.ssh/id_ed25519 -N ""
```

(можно RSA: `ssh-keygen -t rsa -b 4096 …`)

### 2. Скопировать публичный ключ на каждый узел

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@192.168.0.100
```

Пример для root:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.0.100
```

### 3. Проверить вход без пароля

```bash
ssh user@192.168.0.100 'hostname && python3 --version'
```

> Подробнее про SSH-ключи — в документации РЕД ОС по аутентификации SSH.

---

## Защищённый каталог ключей (один владелец)

Обычный `~/.ssh` доступен владельцу домашнего каталога. Если нужно **изолировать ключи** так, чтобы их мог читать и перемещать только **один** пользователь ОС — используйте режим `--secure-keys`.

### Что создаётся

| Объект | Значение по умолчанию |
|---|---|
| Каталог | `/var/lib/ansible-keys` (`chmod 0700`) |
| Владелец | пользователь `ansible-keys` (создаётся скриптом, пароль заблокирован) |
| Приватный ключ | `/var/lib/ansible-keys/id_ed25519` (`chmod 600`) |
| Публичный ключ | `/var/lib/ansible-keys/id_ed25519.pub` |
| Архив старых ключей | `/var/lib/ansible-keys/archive/` |
| `ansible.cfg` | `private_key_file = /var/lib/ansible-keys/id_ed25519` |
| Inventory vars | `[servers:vars]` → `ansible_ssh_private_key_file=...` |
| Group vars | `/etc/ansible/group_vars/all.yml` → `ansible_ssh_private_key_file: ...` |

Другие **обычные** пользователи системы в каталог не зайдут и ключи не скопируют/не переместят.  
**Ограничение Linux:** пользователь `root` по-прежнему может читать любые файлы. Полная защита от root — только HSM / шифрование с секретом вне этой машины.

### Установка

```bash
sudo ./scripts/install-ansible-redos.sh --secure-keys \
  --hosts '192.168.1.10,192.168.1.11' \
  --remote-user admin
```

Свои пути/владелец:

```bash
sudo ./scripts/install-ansible-redos.sh --secure-keys \
  --key-dir /var/lib/ansible-keys \
  --key-owner ansible-keys
```

Или отдельной командой после установки — см. [`scripts/ansible-keys-secure-setup.sh`](../scripts/ansible-keys-secure-setup.sh).

### Работа только от владельца ключей

```bash
# Ansible
sudo -u ansible-keys -H ansible all -m ping
sudo -u ansible-keys -H ansible-playbook playbook.yml

# Разложить публичный ключ на узел
sudo -u ansible-keys ssh-copy-id \
  -i /var/lib/ansible-keys/id_ed25519.pub admin@192.168.1.10

# Переместить (ротация) ключа — только ansible-keys
sudo -u ansible-keys mv \
  /var/lib/ansible-keys/id_ed25519 \
  /var/lib/ansible-keys/archive/id_ed25519.$(date +%Y%m%d)
```

Вспомогательные команды: [`scripts/ansible-keys-ctl.sh`](../scripts/ansible-keys-ctl.sh) (`list`, `move-archive`, `show-pub`).

---

## Проверка связи (ping)

Модуль `ping` в Ansible — не ICMP, а проверка, что узел отвечает по SSH и Python доступен.

```bash
# все хосты из /etc/ansible/hosts
ansible all -m ping

# только группа
ansible web -m ping
```

Успех выглядит так:

```text
192.168.0.100 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

---

## Аутентификация по паролю

Если ключи ещё не разложены:

```bash
sudo dnf install -y sshpass
ansible all -m ping -k
```

`-k` / `--ask-pass` — спросить пароль SSH.

Для sudo на удалённом хосте дополнительно:

```bash
ansible all -m ping -k -K
```

`-K` / `--ask-become-pass` — пароль для `become` (sudo).

---

## Собственные inventory

Не обязательно править `/etc/ansible/hosts`. Свой файл:

```bash
ansible all -i /path/to/inventory.ini -m ping
```

Несколько файлов:

```bash
ansible all -i inv1 -i inv2 -m ping
```

Список хостов прямо в команде:

```bash
ansible all -i '192.168.0.100,192.168.0.101,' -m ping
```

(запятая в конце важна, если хост один)

Каталог с несколькими inventory:

```text
inventory/
  web.ini
  db.ini
```

```bash
ansible all -i inventory/ -m ping
```

---

## Одиночные команды

Без плейбука — ad-hoc:

```bash
# выполнить shell-команду
ansible all -a "free -h"

# модуль package / dnf на РЕД ОС
ansible web -b -m dnf -a "name=htop state=present"
```

`-b` — become (sudo). `-a` — аргументы модуля/команды.

---

## Плейбук: пример

Создайте файл `playbook.yml`:

```yaml
---
- name: Установка утилит на все хосты
  hosts: all
  become: true
  vars:
    packages:
      - unrar
      - p7zip
  tasks:
    - name: Установить пакеты через dnf
      ansible.builtin.dnf:
        name: "{{ packages }}"
        state: present
```

Запуск:

```bash
ansible-playbook playbook.yml
```

Если нужен пароль sudo на узлах:

```bash
ansible-playbook playbook.yml -K
```

> В модуле `dnf` параметр `name` — это **список пакетов**, а не имя задачи. Имя задачи задаётся ключом `- name:` у task.

---

## Привилегии become / sudo

В плейбуке:

```yaml
become: true
# при необходимости:
# become_user: root
# become_method: sudo
```

Или в командной строке:

```bash
ansible-playbook playbook.yml -b -K
```

На управляемых узлах пользователь Ansible должен иметь право sudo (часто без пароля для автоматизации, либо с `-K`).

---

## Проверка синтаксиса

```bash
ansible-playbook --syntax-check playbook.yml
ansible-playbook --check playbook.yml   # dry-run (не все модули идеально поддерживают)
```

---

## Базовый ansible.cfg

Удобно положить рядом с проектом (текущий каталог имеет высокий приоритет):

```ini
[defaults]
inventory = ./inventory/hosts
host_key_checking = False
interpreter_python = auto_silent
forks = 20
timeout = 30
retry_files_enabled = False

[privilege_escalation]
become = True
become_method = sudo
become_ask_pass = False
```

> `host_key_checking = False` удобно в лаборатории; в проде лучше оставить проверку ключей хостов.

Расположение конфигов (приоритет сверху вниз): `ANSIBLE_CONFIG` → `./ansible.cfg` → `~/.ansible.cfg` → `/etc/ansible/ansible.cfg`.

---

## Типичные проблемы

| Симптом | Что проверить |
|---|---|
| `UNREACHABLE` / timeout | сеть, firewall, порт SSH, `ansible_host` / `ansible_port` |
| `Permission denied (publickey)` | ключ, `ansible_user`, `ssh-copy-id`, права на `~/.ssh` |
| нет `python` / interpreter | на узле `python3`; в inventory: `ansible_python_interpreter=/usr/bin/python3` |
| `Missing sudo password` | `-K` или NOPASSWD в sudoers на узле |
| пакет `ansible` не находится | `dnf repolist`, для 7.3 + Ansible 6: `ansible6-release` |
| `sshpass` / `-k` не работает | `sudo dnf install sshpass` |

Лог подробнее:

```bash
ansible all -m ping -vvv
```

---

## Готовый скрипт

Скрипт ставит Ansible, `sshpass`, создаёт `/etc/ansible/ansible.cfg`, шаблон inventory и (по желанию) SSH-ключ.

```bash
# из корня репозитория на сервере РЕД ОС
chmod +x scripts/install-ansible-redos.sh

# РЕД ОС 8 / обычная установка
sudo ./scripts/install-ansible-redos.sh

# РЕД ОС 7.3, Ansible 6.x
sudo ./scripts/install-ansible-redos.sh --ansible6

# сразу прописать хосты в inventory + обычный ключ в ~/.ssh
sudo ./scripts/install-ansible-redos.sh \
  --hosts '192.168.0.100,192.168.0.101' \
  --remote-user admin \
  --generate-ssh-key

# защищённый каталог ключей (один владелец ansible-keys)
sudo ./scripts/install-ansible-redos.sh --secure-keys \
  --hosts '192.168.0.100,192.168.0.101' \
  --remote-user admin
```

Справка: `./scripts/install-ansible-redos.sh --help`.

После скрипта:

1. при необходимости допишите хосты в `/etc/ansible/hosts` или `./inventory/hosts`;
2. разложите ключ: `ssh-copy-id` (в режиме `--secure-keys` — от `ansible-keys`);
3. проверьте: `ansible all -m ping` (или `sudo -u ansible-keys -H ansible all -m ping`).

---

## Полезные ссылки

- [Ansible в БЗ РЕД ОС 8](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-remote-admin/8_0-ansible/)
- [Ansible в БЗ РЕД ОС 7.3](https://redos.red-soft.ru/base/redos-7_3/7_3-administation/7_3-remote-admin/7_3-ansible/)
- [Документация Ansible](https://docs.ansible.com/)
