# РЕД ОС: команда `super` — переключение на привилегированную УЗ

Подробная инструкция: как в **РЕД ОС** сделать так, чтобы при вводе `super` пользователь переключался на другую учётную запись с правами `sudo`, а доступ к этой команде был только у выбранного пользователя.

Схема подходит для РЕД ОС 7.3 / 8 (как у семейства RHEL: `sudo`, `visudo`, группа `wheel`, `/usr/local/bin`).

| Параметр | Значение по умолчанию в примерах |
|---|---|
| Команда | `super` |
| Кому разрешено | `ivan` |
| Куда переключаемся | `admin` (в группе `wheel`, есть `sudo`) |
| Путь скрипта | `/usr/local/bin/super` |
| Правило sudoers | `/etc/sudoers.d/super-command` |

Замените `ivan` и `admin` на свои имена пользователей.

---

## Содержание

1. [Цель](#цель)
2. [Подготовка пользователей](#подготовка-пользователей)
3. [Создание команды super](#создание-команды-super)
4. [Разрешить super только одному пользователю](#разрешить-super-только-одному-пользователю)
5. [Рекомендуемый вариант (просто super)](#рекомендуемый-вариант-просто-super)
6. [Ужесточение прав на файл](#ужесточение-прав-на-файл)
7. [Примеры использования](#примеры-использования)
8. [Логирование](#логирование)
9. [Типичные ошибки](#типичные-ошибки)
10. [Минимальный рабочий набор](#минимальный-рабочий-набор)
11. [Варианты: с паролем и сразу в root](#варианты-с-паролем-и-сразу-в-root)

---

## Цель

- Команда: `super`
- Действие: вход в другую учётную запись (например `admin`) с правами `sudo`
- Ограничение: `super` доступна только конкретному пользователю (например `ivan`)

Итог для разрешённого пользователя:

```bash
super
# сессия admin
whoami          # admin
sudo whoami     # root
```

Для остальных пользователей команда не сработает.

---

## Подготовка пользователей

### Целевая УЗ (куда переключаемся)

```bash
# создать пользователя admin (если его ещё нет)
sudo useradd -m -s /bin/bash admin

# задать пароль (по желанию; при схеме через sudo пароль admin не нужен)
sudo passwd admin

# дать admin права sudo через группу wheel
sudo usermod -aG wheel admin
```

Проверка группы `wheel` в sudoers:

```bash
sudo grep -E '^%wheel|^# %wheel' /etc/sudoers
```

Должно быть что-то вроде:

```text
%wheel  ALL=(ALL)       ALL
```

Если строка закомментирована — раскомментируйте через `visudo`:

```bash
sudo visudo
```

### Пользователь, которому разрешён `super`

```bash
# пример: пользователь ivan уже существует
id ivan
```

---

## Создание команды `super`

Создайте скрипт:

```bash
sudo tee /usr/local/bin/super << 'EOF'
#!/bin/bash
# Переключение на привилегированную УЗ
TARGET_USER="admin"

# запрет запуска от root напрямую (по желанию)
if [ "$(id -u)" -eq 0 ]; then
  echo "Запустите super от имени обычного пользователя."
  exit 1
fi

# вход в интерактивную сессию TARGET_USER
exec sudo -u "$TARGET_USER" -i
EOF
```

Права:

```bash
sudo chown root:root /usr/local/bin/super
sudo chmod 755 /usr/local/bin/super
```

Пока скрипт могут видеть все, но **реально выполнить переключение** сможет только тот, кому разрешено в `sudoers` (следующий раздел).

---

## Разрешить `super` только одному пользователю

Редактируйте sudoers **только через visudo**:

```bash
sudo visudo
```

Или отдельный файл (предпочтительнее):

```bash
sudo visudo -f /etc/sudoers.d/super-command
```

Пример содержимого:

```text
# Пользователь ivan может запускать /usr/local/bin/super без пароля
ivan ALL=(root) NOPASSWD: /usr/local/bin/super

# Важно: внутри super вызывается sudo -u admin -i
# поэтому ivan должен иметь право выполнять именно это:
ivan ALL=(root) NOPASSWD: /usr/bin/sudo -u admin -i
```

Чище сделать так, чтобы `super` вызывался **через sudo**, а внутри уже шёл `su` / `runuser`.

### Более простой вариант через `su`

Перепишите `/usr/local/bin/super`:

```bash
sudo tee /usr/local/bin/super << 'EOF'
#!/bin/bash
TARGET_USER="admin"
exec /usr/bin/su - "$TARGET_USER"
EOF

sudo chown root:root /usr/local/bin/super
sudo chmod 755 /usr/local/bin/super
```

Sudoers:

```bash
sudo visudo -f /etc/sudoers.d/super-command
```

```text
# Только ivan может запускать команду super
Defaults!/usr/local/bin/super !requiretty
ivan ALL=(root) NOPASSWD: /usr/local/bin/super
```

Тогда пользователь запускает:

```bash
sudo super
```

Чтобы писать просто `super` (без `sudo`), добавьте alias **только** пользователю `ivan`:

```bash
# от имени ivan
echo 'alias super="sudo /usr/local/bin/super"' >> ~/.bashrc
source ~/.bashrc
```

---

## Рекомендуемый вариант (просто `super`)

Скрипт с проверкой пользователя и автозапуском через `sudo`:

```bash
sudo tee /usr/local/bin/super << 'EOF'
#!/bin/bash
ALLOWED_USER="ivan"
TARGET_USER="admin"

# кто реально запустил (учитываем sudo)
REAL_USER="${SUDO_USER:-$USER}"

if [ "$REAL_USER" != "$ALLOWED_USER" ]; then
  echo "Доступ запрещён: команду super может использовать только $ALLOWED_USER"
  exit 1
fi

# если уже root (через sudo), просто переключаемся
if [ "$(id -u)" -eq 0 ]; then
  exec /sbin/runuser -l "$TARGET_USER"
fi

# иначе перезапускаем себя через sudo
exec /usr/bin/sudo /usr/local/bin/super
EOF

sudo chown root:root /usr/local/bin/super
sudo chmod 755 /usr/local/bin/super
```

Sudoers:

```bash
sudo visudo -f /etc/sudoers.d/super-command
```

```text
ivan ALL=(root) NOPASSWD: /usr/local/bin/super
```

Проверка синтаксиса:

```bash
sudo visudo -c
```

> На РЕД ОС удобно использовать `/sbin/runuser -l admin` вместо `su - admin`: не спрашивает пароль целевой УЗ, когда скрипт уже выполняется от root.

---

## Ужесточение прав на файл

Если нужно, чтобы файл `super` вообще не мог запускать никто, кроме `ivan` (и root):

```bash
# создать группу только для этой команды
sudo groupadd superusers
sudo usermod -aG superusers ivan

# права: читать/выполнять только владелец и группа
sudo chown root:superusers /usr/local/bin/super
sudo chmod 750 /usr/local/bin/super
```

После смены группы пользователь должен перелогиниться:

```bash
# выход и новый вход в сессию
# либо:
newgrp superusers
```

Это **дополнение** к sudoers, не замена: sudoers контролирует повышение привилегий, права файла — видимость и запуск бинарника.

---

## Примеры использования

### От разрешённого пользователя

```bash
su - ivan
super
# попадаете в сессию admin
whoami
# admin
sudo whoami
# root
```

### От другого пользователя

```bash
su - petr
super
# Доступ запрещён: команду super может использовать только ivan
# или: Sorry, user petr is not allowed to execute ...
```

### Проверка правил sudo

```bash
sudo -l -U ivan
sudo -l -U petr
```

У `ivan` должно быть разрешение на `/usr/local/bin/super`, у `petr` — нет.

---

## Логирование

В sudoers:

```text
Defaults!/usr/local/bin/super log_output
ivan ALL=(root) NOPASSWD: /usr/local/bin/super
```

Смотреть журнал:

```bash
sudo journalctl -u sudo -e
# или
sudo grep super /var/log/secure
```

В РЕД ОС / RHEL аутентификация sudo обычно пишется в `/var/log/secure`.

---

## Типичные ошибки

| Симптом | Причина | Что сделать |
|---|---|---|
| `command not found` | нет в PATH | путь `/usr/local/bin` должен быть в `$PATH` |
| `Sorry, user ... is not allowed` | нет правила sudoers | проверить `/etc/sudoers.d/super-command` |
| `authentication failed` / просит пароль | нет `NOPASSWD` | добавить `NOPASSWD:` |
| `Permission denied` на файле | chmod/chown | `750` + группа `superusers` |
| `su: Authentication failure` | `su` без root | запускать `super` через sudo; внутри — `runuser` / `su` от root |

---

## Минимальный рабочий набор

```bash
# 1) целевая УЗ
sudo useradd -m -s /bin/bash admin
sudo usermod -aG wheel admin

# 2) команда
sudo tee /usr/local/bin/super << 'EOF'
#!/bin/bash
ALLOWED_USER="ivan"
TARGET_USER="admin"
REAL_USER="${SUDO_USER:-$USER}"
[ "$REAL_USER" = "$ALLOWED_USER" ] || { echo "Доступ запрещён"; exit 1; }
[ "$(id -u)" -eq 0 ] || exec /usr/bin/sudo "$0"
exec /sbin/runuser -l "$TARGET_USER"
EOF
sudo chown root:root /usr/local/bin/super
sudo chmod 755 /usr/local/bin/super

# 3) sudoers только для ivan
echo 'ivan ALL=(root) NOPASSWD: /usr/local/bin/super' | sudo tee /etc/sudoers.d/super-command
sudo chmod 440 /etc/sudoers.d/super-command
sudo visudo -c
```

После этого у `ivan`:

```bash
super
```

откроется сессия `admin` с правами `sudo`, а у остальных пользователей команда не сработает.

---

## Варианты: с паролем и сразу в root

### С запросом пароля (без `NOPASSWD`)

В `/etc/sudoers.d/super-command`:

```text
ivan ALL=(root) /usr/local/bin/super
```

Тогда при каждом `super` у `ivan` будет запрашиваться **его** пароль (не пароль `admin`).

### Переключение сразу в root

В скрипте замените целевую УЗ:

```bash
TARGET_USER="root"
# ...
exec /sbin/runuser -l root
# или:
# exec /bin/bash -l
```

И в sudoers оставьте разрешение только на `/usr/local/bin/super` для нужного пользователя.

> Давать прямой вход в root через `super` удобно, но риск выше: любой, кто скомпрометировал разрешённую УЗ, сразу получает root. Предпочтительнее отдельная УЗ `admin` в `wheel`.
