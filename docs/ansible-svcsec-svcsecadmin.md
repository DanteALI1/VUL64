# svcsec / svcsecadmin: роли, sudo и Ansible на РЕД ОС

Отдельная инструкция (не часть общего гайда по установке Ansible).  
Цель: правильно развести **кто запускает** автоматизацию и **кто работает на узлах**, убрать у `svcsec` бесконтрольный `sudo su`, оставить только нужные привилегии.

| Роль | Где живёт | Назначение |
|---|---|---|
| **svcsecadmin** | только управляющая машина (control node) | запускает Ansible, владеет/использует SSH-ключи к узлам |
| **svcsec** | все управляемые узлы (managed nodes) | учётка, под которой Ansible заходит по SSH; ограниченные права `sudo` |

> **Как читается «ограничить svcsec»:** убрать возможность получить **интерактивный root** (`sudo su`, `sudo -i`, `sudo bash`).  
> Привилегированные действия — только через `sudo` по **разрешённому списку команд** (или «всё, кроме оболочек» — см. варианты A/B ниже).

Связанные документы: [установка Ansible](ansible-redos.md), [защищённые ключи](ansible-redos.md#защищённый-каталог-ключей-один-владелец).

---

## Содержание

1. [Итоговая схема](#итоговая-схема)
2. [Что сломано сейчас (типично)](#что-сломано-сейчас-типично)
3. [Управляющая машина: пользователь svcsecadmin](#управляющая-машина-пользователь-svcsecadmin)
4. [Управляемые узлы: пользователь svcsec](#управляемые-узлы-пользователь-svcsec)
5. [Ограничение sudo у svcsec (вместо sudo su)](#ограничение-sudo-у-svcsec-вместо-sudo-su)
6. [SSH-ключ: svcsecadmin → svcsec](#ssh-ключ-svcsecadmin--svcsec)
7. [Настройка Ansible под эти учётки](#настройка-ansible-под-эти-учётки)
8. [Проверки](#проверки)
9. [Удаление старых прав и ключей](#удаление-старых-прав-и-ключей)
10. [Чеклист на весь парк узлов](#чеклист-на-весь-парк-узлов)
11. [Готовые файлы в репозитории](#готовые-файлы-в-репозитории)

---

## Итоговая схема

```text
┌─────────────────────────────┐
│  Control node (РЕД ОС)      │
│  пользователь: svcsecadmin  │
│  запускает: ansible-*       │
│  ключ SSH → к svcsec@узлы   │
└──────────────┬──────────────┘
               │ SSH (ключ)
               ▼
┌─────────────────────────────┐
│  Managed node               │
│  пользователь: svcsec       │
│  sudo: только разрешённые   │
│        команды (не sudo su) │
│  become → root для задач    │
└─────────────────────────────┘
```

Правила:

1. На **узлах** Ansible логинится как **`svcsec`**, не как `svcsecadmin` и не как `root`.
2. Повышение прав на узле — через Ansible `become: true` → `sudo` от имени `svcsec`.
3. **`svcsec` не должен уметь `sudo su` / открыть root-shell.**
4. **`svcsecadmin` на узлах лучше не создавать** (или без SSH и без sudo) — меньше поверхность атаки.

---

## Что сломано сейчас (типично)

Если у `svcsec` в sudoers что-то вроде:

```sudoers
svcsec ALL=(ALL) ALL
svcsec ALL=(ALL) NOPASSWD: ALL
```

или он спокойно делает:

```bash
sudo su
sudo -i
sudo /bin/bash
```

— это полный root. Любой, кто скомпрометировал `svcsec` или его SSH-ключ, получает машину целиком.

Нужно: **отозвать ALL / su / оболочки**, выдать только нужное.

---

## Управляющая машина: пользователь svcsecadmin

Выполнять на **control node** (где установлен Ansible).

### 1. Создать пользователя

```bash
sudo useradd -m -s /bin/bash -c "Ansible operator" svcsecadmin
sudo passwd svcsecadmin   # или вход только по ключу + sudo для админов
```

### 2. Дать локальный sudo (по необходимости)

`svcsecadmin` на control node может понадобиться для обслуживания самой управляющей машины.  
Это **не** те же права, что на узлах.

Минимально (пример — только просмотр журналов и перезапуск своих юнитов; подправьте под себя):

```bash
sudo tee /etc/sudoers.d/svcsecadmin <<'EOF'
# Control node only — НЕ копировать на managed nodes
Defaults:svcsecadmin !requiretty
svcsecadmin ALL=(root) NOPASSWD: /usr/bin/systemctl status *, /usr/bin/journalctl
EOF
sudo chmod 440 /etc/sudoers.d/svcsecadmin
sudo visudo -cf /etc/sudoers.d/svcsecadmin
```

Если `svcsecadmin` должен ставить пакеты на control node — расширьте список явно.  
**Не давайте** `NOPASSWD: ALL` без необходимости.

### 3. Ansible и ключи — от svcsecadmin

Вариант A — ключ в home:

```bash
sudo -u svcsecadmin ssh-keygen -t ed25519 \
  -f /home/svcsecadmin/.ssh/id_ed25519 -N "" \
  -C "svcsecadmin@$(hostname)-ansible"
```

Вариант B — защищённый каталог (см. основной гайд `--secure-keys`), а `svcsecadmin` запускает Ansible через `sudo -u ansible-keys` **или** владельцем ключей делаете именно `svcsecadmin`:

```bash
sudo ./scripts/install-ansible-redos.sh --secure-keys \
  --key-owner svcsecadmin \
  --key-dir /var/lib/ansible-keys \
  --remote-user svcsec \
  --hosts '192.168.0.10,192.168.0.11'
```

Дальше все `ansible` / `ansible-playbook` — от **svcsecadmin** (или от владельца ключей):

```bash
sudo -u svcsecadmin -H ansible all -m ping
```

---

## Управляемые узлы: пользователь svcsec

На **каждом** managed node:

### 1. Создать пользователя (если нет)

```bash
sudo useradd -m -s /bin/bash -c "Ansible managed account" svcsec
# пароль можно не задавать, если вход только по ключу
sudo passwd -l svcsec
```

### 2. Каталог .ssh

```bash
sudo install -d -m 700 -o svcsec -g svcsec /home/svcsec/.ssh
sudo touch /home/svcsec/.ssh/authorized_keys
sudo chown svcsec:svcsec /home/svcsec/.ssh/authorized_keys
sudo chmod 600 /home/svcsec/.ssh/authorized_keys
```

Публичный ключ `svcsecadmin` (или из `/var/lib/ansible-keys/id_ed25519.pub`) добавить в `authorized_keys` — см. раздел про SSH ниже.

### 3. Не давать лишнего

- не добавлять `svcsec` в группу `wheel` с полным sudo «по умолчанию» дистрибутива, если это открывает ALL;
- не класть ключ root’а для повседневной автоматизации.

---

## Ограничение sudo у svcsec (вместо sudo su)

Файл на **каждом узле**: `/etc/sudoers.d/svcsec`  
Права обязательно `0440`, проверка `visudo -cf`.

Сначала **снимите** старые широкие правила (в `/etc/sudoers` и других файлах в `sudoers.d/`), где у `svcsec` есть `ALL` или разрешение на `su`.

### Вариант A — жёсткий allowlist (максимально безопасно)

Разрешены только перечисленные бинарники. Ansible-модули, которые вызывают другие пути, будут падать — список придётся расширять под ваши плейбуки.

Готовый шаблон: [`scripts/sudoers/svcsec-allowlist`](../scripts/sudoers/svcsec-allowlist)

```sudoers
# /etc/sudoers.d/svcsec  — вариант A (allowlist)
Defaults:svcsec !requiretty
Defaults:svcsec secure_path="/usr/sbin:/usr/bin:/sbin:/bin"

Cmnd_Alias SVCSEC_PKGS = /usr/bin/dnf, /usr/bin/yum, /usr/bin/rpm
Cmnd_Alias SVCSEC_SVC  = /usr/bin/systemctl, /usr/sbin/service
Cmnd_Alias SVCSEC_NET  = /usr/bin/firewall-cmd, /usr/sbin/iptables, /usr/sbin/ip6tables
Cmnd_Alias SVCSEC_FS   = /usr/bin/install, /usr/bin/mkdir, /usr/bin/cp, /usr/bin/mv, /usr/bin/rm, /usr/bin/chmod, /usr/bin/chown, /usr/bin/tee, /usr/bin/ln
Cmnd_Alias SVCSEC_EDIT = /usr/bin/sed, /usr/bin/install, /usr/sbin/visudo
Cmnd_Alias SVCSEC_OK   = SVCSEC_PKGS, SVCSEC_SVC, SVCSEC_NET, SVCSEC_FS, SVCSEC_EDIT

# Запрет интерактивного root (на случай пересечений с другими правилами)
Cmnd_Alias SVCSEC_DENY = /bin/su, /usr/bin/su, /bin/bash, /bin/sh, /usr/bin/bash, /usr/bin/sh, /bin/zsh, /usr/bin/zsh

svcsec ALL=(root) NOPASSWD: SVCSEC_OK
svcsec ALL=(root) !SVCSEC_DENY
```

Установка:

```bash
sudo cp scripts/sudoers/svcsec-allowlist /etc/sudoers.d/svcsec
sudo chmod 440 /etc/sudoers.d/svcsec
sudo chown root:root /etc/sudoers.d/svcsec
sudo visudo -cf /etc/sudoers.d/svcsec
```

Проверка запрета shell:

```bash
sudo -u svcsec sudo su          # должно ОТКЛОНИТЬ
sudo -u svcsec sudo -i          # должно ОТКЛОНИТЬ
sudo -u svcsec sudo /bin/bash   # должно ОТКЛОНИТЬ
sudo -u svcsec sudo dnf repolist  # должно РАЗРЕШИТЬ (если dnf в списке)
```

### Вариант B — практичный для Ansible: всё, кроме оболочек и su

Удобно, когда плейбуки разные и allowlist раздувается.  
`svcsec` может делать почти всё через `sudo <команда>`, но **не** получить интерактивный root.

Готовый шаблон: [`scripts/sudoers/svcsec-noshell`](../scripts/sudoers/svcsec-noshell)

```sudoers
# /etc/sudoers.d/svcsec  — вариант B (NOPASSWD ALL, без shell/su)
Defaults:svcsec !requiretty

Cmnd_Alias SVCSEC_SHELLS = \
  /bin/su, /usr/bin/su, \
  /bin/bash, /usr/bin/bash, \
  /bin/sh, /usr/bin/sh, \
  /bin/zsh, /usr/bin/zsh, \
  /bin/dash, /usr/bin/dash, \
  /usr/bin/sudoedit

svcsec ALL=(root) NOPASSWD: ALL, !SVCSEC_SHELLS
```

> Это **не** эквивалент полной изоляции: через `sudo` всё ещё можно, например, `sudo chmod` на sudoers или поставить свой SUID. Для высокой угрозы — только вариант A + жёсткий контроль плейбуков и ключей.

### Что выбрать

| Ситуация | Вариант |
|---|---|
| Мало плейбуков, известный список команд | **A (allowlist)** |
| Много ролей Ansible, нужна работоспособность become | **B (noshell)** как компромисс |
| Максимум безопасности | A + отдельные учётки под разные задачи |

Рекомендация для старта с рабочим Ansible: **B**, затем по логам сужать до **A**.

---

## SSH-ключ: svcsecadmin → svcsec

С **control node**:

```bash
# публичный ключ оператора
sudo -u svcsecadmin cat /home/svcsecadmin/.ssh/id_ed25519.pub
# или:
sudo -u svcsecadmin cat /var/lib/ansible-keys/id_ed25519.pub
```

Разложить на узел:

```bash
sudo -u svcsecadmin ssh-copy-id -i /home/svcsecadmin/.ssh/id_ed25519.pub svcsec@192.168.0.100
```

Проверка **без** пароля:

```bash
sudo -u svcsecadmin ssh svcsec@192.168.0.100 'id; sudo -n dnf repolist'
```

`sudo -n` — без запроса пароля; если NOPASSWD настроен верно, команда из allowlist пройдёт.

---

## Настройка Ansible под эти учётки

### inventory (`/etc/ansible/hosts` или проектный)

```ini
[servers]
node1.example.ru
node2.example.ru
192.168.0.100

[servers:vars]
ansible_user=svcsec
ansible_become=true
ansible_become_method=sudo
ansible_become_user=root
# если ключ не дефолтный:
# ansible_ssh_private_key_file=/var/lib/ansible-keys/id_ed25519
# или:
# ansible_ssh_private_key_file=/home/svcsecadmin/.ssh/id_ed25519
```

### group_vars (`/etc/ansible/group_vars/all.yml`)

```yaml
---
ansible_user: svcsec
ansible_become: true
ansible_become_method: sudo
ansible_become_user: root
ansible_ssh_private_key_file: /home/svcsecadmin/.ssh/id_ed25519
```

### Плейбук

```yaml
---
- name: Пример
  hosts: servers
  become: true
  tasks:
    - name: Пакет
      ansible.builtin.dnf:
        name: htop
        state: present
```

Запуск **только** от оператора:

```bash
sudo -u svcsecadmin -H ansible servers -m ping
sudo -u svcsecadmin -H ansible-playbook playbook.yml
```

---

## Проверки

На control node:

```bash
# 1) SSH до svcsec
sudo -u svcsecadmin ssh svcsec@NODE 'echo OK'

# 2) become / sudo без пароля для разрешённой команды
sudo -u svcsecadmin ssh svcsec@NODE 'sudo -n true'          # для варианта B
sudo -u svcsecadmin ssh svcsec@NODE 'sudo -n dnf repolist' # для варианта A

# 3) интерактивный root ЗАПРЕЩЁН
sudo -u svcsecadmin ssh svcsec@NODE 'sudo -n su -'         # expect: denied
sudo -u svcsecadmin ssh svcsec@NODE 'sudo -n /bin/bash'    # expect: denied

# 4) Ansible
sudo -u svcsecadmin -H ansible NODE -m ping
sudo -u svcsecadmin -H ansible NODE -b -m command -a 'id'
# uid=0(root) при become — ОК, без интерактивного shell у svcsec
```

---

## Удаление старых прав и ключей

### Старый sudoers

```bash
# на узле
sudo grep -R "svcsec" /etc/sudoers /etc/sudoers.d/
# удалить/закомментировать строки ALL / su
sudo rm -f /etc/sudoers.d/old-svcsec-full   # пример
sudo visudo -cf /etc/sudoers
```

### Старый ключ с узлов

См. краткую схему: убрать строку публичного ключа из `/home/svcsec/.ssh/authorized_keys`.

С Ansible (с control node), подставив свой `.pub`:

```bash
PUB=$(sudo -u svcsecadmin cat /home/svcsecadmin/.ssh/id_ed25519.pub)
# удалить КОНКРЕТНЫЙ старый ключ — подставьте содержимое СТАРОГО .pub
ansible servers -b -m lineinfile \
  -a "path=/home/svcsec/.ssh/authorized_keys line='ssh-ed25519 AAAA...old...' state=absent"
```

Или вручную на узле:

```bash
sudo -u svcsec grep -vF 'ssh-ed25519 AAAA...old...' \
  /home/svcsec/.ssh/authorized_keys > /tmp/ak \
  && sudo -u svcsec install -m 600 /tmp/ak /home/svcsec/.ssh/authorized_keys
```

---

## Чеклист на весь парк узлов

На **control node**

- [ ] создан `svcsecadmin`
- [ ] установлен Ansible, inventory с `ansible_user=svcsec`
- [ ] есть SSH-ключ оператора (home или `/var/lib/ansible-keys`)
- [ ] плейбуки запускаются от `svcsecadmin`

На **каждом managed node**

- [ ] создан `svcsec`, home + `.ssh` с правами 700/600
- [ ] в `authorized_keys` только нужный публичный ключ оператора
- [ ] удалён старый широкий sudo (`ALL` / `sudo su`)
- [ ] установлен `/etc/sudoers.d/svcsec` (вариант A или B), `visudo -cf` OK
- [ ] `sudo su` / `sudo bash` от `svcsec` — **denied**
- [ ] `ansible host -m ping` и `-b -a 'id'` — **OK**
- [ ] нет лишнего пользователя `svcsecadmin` на узле (или без ключа/sudo)

---

## Готовые файлы в репозитории

| Файл | Назначение |
|---|---|
| [`scripts/sudoers/svcsec-allowlist`](../scripts/sudoers/svcsec-allowlist) | sudoers вариант A |
| [`scripts/sudoers/svcsec-noshell`](../scripts/sudoers/svcsec-noshell) | sudoers вариант B |
| [`scripts/deploy-svcsec-node.sh`](../scripts/deploy-svcsec-node.sh) | подготовка одного узла (user + sudoers + ssh dir) |
| [`scripts/ansible-svcsec-inventory.example.ini`](../scripts/ansible-svcsec-inventory.example.ini) | пример inventory |

Развёртывание sudoers на узел с control node (после копирования файла):

```bash
scp scripts/sudoers/svcsec-noshell root@NODE:/tmp/svcsec
ssh root@NODE 'install -m 440 /tmp/svcsec /etc/sudoers.d/svcsec && visudo -cf /etc/sudoers.d/svcsec'
```

Или через уже работающий Ansible (если временный доступ root ещё есть):

```yaml
- name: Установить ограниченный sudoers для svcsec
  hosts: servers
  become: true
  tasks:
    - name: Файл sudoers
      ansible.builtin.copy:
        src: scripts/sudoers/svcsec-noshell
        dest: /etc/sudoers.d/svcsec
        owner: root
        group: root
        mode: "0440"
        validate: visudo -cf %s
```

---

## Краткий ответ «что сделать, чтобы всё работало»

1. На control node — работать только под **`svcsecadmin`** (+ ключ к узлам).  
2. На всех узлах — учётка **`svcsec`**, вход по ключу.  
3. У **`svcsec` убрать `sudo su` / ALL**, поставить sudoers A или B.  
4. В Ansible: `ansible_user=svcsec`, `become=true`, ключ в vars/`ansible.cfg`.  
5. Прогнать ping + become `id` + проверку, что `sudo su` запрещён.

После этого автоматизация идёт с одной операторской УЗ, а на узлах нет интерактивного root через `svcsec`.
