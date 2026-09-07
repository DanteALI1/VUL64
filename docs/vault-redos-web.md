# HashiCorp Vault на РЕД ОС 8: развёртывание и веб-интерфейс (порты 80 / 443)

Инструкция по установке и использованию [HashiCorp Vault](https://www.vaultproject.io/) на **РЕД ОС 8** на основе [базы знаний РЕД ОС](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-monitoring/8_0-infrastructure-automation/8_0-Vault/), с акцентом на **веб-UI** и доступ через стандартные порты **80** (HTTP) и **443** (HTTPS).

| Параметр | Значение |
|---|---|
| Версия ОС | РЕД ОС 8 |
| Конфигурация | Рабочая станция, Сервер графический |
| Редакция | Стандартная, Образовательная |
| Архитектура | x86_64 |
| Версия ПО (из БЗ) | vault-1.21.2-1 |

Vault — клиент-серверное хранилище секретов (пароли, сертификаты, токены): хранение, выдача по запросу, PKI-процессы, шифрование данных для приложений.

Выберите сценарий доступа к веб-интерфейсу:

| Вариант | Порт | TLS | Когда использовать |
|---|---|---|---|
| [A. HTTP через nginx](#вариант-a-http-порт-80-без-tls) | **80** | нет | локальная сеть / тест, сертификата нет |
| [B. HTTPS через nginx](#вариант-b-https-порт-443-через-nginx) | **443** | да (nginx) | продакшен / удалённый доступ |
| [C. Vault слушает 80/443 сам](#вариант-c-vault-слушает-80-или-443-напрямую) | **80** или **443** | по конфигу | без reverse proxy |
| [Dev-режим](#быстрый-старт-режим-разработки) | 8200 | нет | только локальная разработка |

Для HTTPS сначала подготовьте сертификат по шагам 1–8 (или одной командой скриптом): [создание своего SSL-сертификата](#создание-своего-ssl-сертификата).

Либо поставьте всё сразу: [готовый скрипт установки](#готовый-скрипт-установить-всё-сразу).

> **Важно:** HTTP (порт 80) передаёт токены и секреты открытым текстом. В интернет без TLS не выставляйте. Для продакшена используйте вариант B.

---

## Готовый скрипт: установить всё сразу

Одна команда ставит Vault, создаёт SSL-сертификаты, настраивает nginx (HTTPS), firewall и запускает службы.

```bash
# из корня репозитория на сервере РЕД ОС
chmod +x scripts/install-vault-redos.sh scripts/create-vault-ssl-cert.sh

sudo ./scripts/install-vault-redos.sh \
  --fqdn vault.example.local \
  --ip 192.168.1.50
```

Что делает [`scripts/install-vault-redos.sh`](../scripts/install-vault-redos.sh):

1. Ставит пакеты (`vault`, `openssl`, `nginx`, …)  
2. Создаёт пользователя/каталоги, `vault.hcl`, systemd unit  
3. Выпускает и ставит SSL (через [`create-vault-ssl-cert.sh`](../scripts/create-vault-ssl-cert.sh))  
4. Настраивает nginx :443 и firewall  
5. Запускает Vault  
6. **Сразу** делает `vault operator init` + unseal ×3, сохраняет ключи в `/root/vault-init-KEYS.txt` (chmod 600)

Отключить init: добавьте `--no-init`.

Другие режимы:

```bash
# HTTP без TLS (только доверенная LAN)
sudo ./scripts/install-vault-redos.sh --fqdn vault.example.local --ip 192.168.1.50 --access http

# Vault сам слушает 443 (без nginx)
sudo ./scripts/install-vault-redos.sh --fqdn vault.example.local --ip 192.168.1.50 --access direct-https

# короткий self-signed вместо своей CA
sudo ./scripts/install-vault-redos.sh --fqdn vault.example.local --ip 192.168.1.50 --cert-mode selfsigned

# только поставить систему, без init
sudo ./scripts/install-vault-redos.sh --fqdn vault.example.local --ip 192.168.1.50 --no-init
```

Справка: `./scripts/install-vault-redos.sh --help`.

После установки UI: `https://vault.example.local` (или `http://…` при `--access http`).

Ниже — ручная установка по шагам, если скрипт не используете.

---

## Рекомендации по безопасности (из БЗ РЕД ОС)

При настройке Vault:

- отключите swap (чтобы секреты не писались на диск);
- запретите снимки процесса Vault;
- ограничьте сетевой доступ firewall’ом;
- задайте короткое TTL для выдаваемых учётных данных;
- включите блокировку при превышении лимита неудачных входов;
- ведите audit-логи всех операций;
- синхронизируйте время через NTP;
- настройте автоматические бэкапы;
- для отказоустойчивости — кластер минимум из 3 узлов;
- для auto-unseal — HSM или облачный KMS;
- не храните секреты в конфигах в открытом виде;
- проверяйте права на файлы Vault;
- продумайте отзыв доступа при удалении пользователей;
- запускайте Vault как единственный процесс на сервере.

---

## 1. Установка

```bash
sudo dnf install -y vault
vault --version
```

Ожидаемый вывод похож на: `Vault v1.21.x ...`

---

## 2. Быстрый старт (режим разработки)

Сервер `-dev` слушает `127.0.0.1:8200` **без TLS**, сразу инициализирован и распечатан. Корневой токен выводится в консоль. **Не используйте `-dev` в продакшене.**

### 2.1. Запуск

```bash
vault server -dev -dev-root-token-id=root -dev-listen-address=127.0.0.1:8200 &
```

Сохраните **Root Token** из вывода (в примере он задан явно: `root`).

### 2.2. Окружение CLI

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
echo $VAULT_ADDR
vault status
```

Успех: `"initialized": true`, `"sealed": false`.

### 2.3. Вход

```bash
vault login root
vault token lookup
```

### 2.4. Веб-интерфейс (dev)

В браузере на этой же машине:

```text
http://127.0.0.1:8200
```

или `http://127.0.0.1:8200/ui/`.

На странице входа:

1. Метод аутентификации: **Token**
2. Токен: `root` (или ваш Root Token)
3. **Sign in**

После входа откроется панель управления (секреты, политики, auth-методы).

### 2.5. Остановка dev-сервера

```bash
sudo ss -tlnp | grep 8200
sudo kill -15 <pid>
```

---

## 3. Боевой режим: подготовка сервера

В рабочем окружении Vault **не** запускается в `-dev`: нужны конфиг, `vault operator init` и `vault operator unseal`.

### 3.1. Каталоги и пользователь

Пакет обычно создаёт пользователя `vault`. Если нет — создайте вручную:

```bash
sudo useradd --system --home /var/lib/vault --shell /sbin/nologin vault 2>/dev/null || true
sudo mkdir -p /etc/vault.d /var/lib/vault/data /var/log/vault
sudo chown -R vault:vault /etc/vault.d /var/lib/vault /var/log/vault
sudo chmod 750 /etc/vault.d /var/lib/vault /var/log/vault
```

### 3.2. Базовый конфиг Vault (слушает только localhost:8200)

Создайте `/etc/vault.d/vault.hcl`:

```hcl
ui = true

storage "file" {
  path = "/var/lib/vault/data"
}

# Vault слушает только localhost — снаружи доступ через nginx на 80/443
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}

api_addr     = "http://127.0.0.1:8200"
disable_mlock = false
```

Права:

```bash
sudo chown vault:vault /etc/vault.d/vault.hcl
sudo chmod 640 /etc/vault.d/vault.hcl
```

> Для вариантов A/B этот конфиг оптимален: API/UI на `127.0.0.1:8200`, наружу — nginx.

### 3.3. systemd-юнит

Создайте `/etc/systemd/system/vault.service`:

```ini
[Unit]
Description=HashiCorp Vault
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
```

Запуск:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now vault
sudo systemctl status vault --no-pager
```

### 3.4. Инициализация и распечатка (unseal)

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
vault status
```

Первый запуск — `Initialized: false`, `Sealed: true`:

```bash
vault operator init -key-shares=5 -key-threshold=3
```

**Сохраните в безопасное место:**

- 5 Unseal Keys
- Initial Root Token

Распечатка (нужно ввести **3** разных ключа из 5):

```bash
vault operator unseal
# вставьте Unseal Key 1
vault operator unseal
# Unseal Key 2
vault operator unseal
# Unseal Key 3
```

Проверка:

```bash
vault status
# Sealed: false
vault login <Initial_Root_Token>
```

После каждой перезагрузки службы Vault снова **sealed** — повторите `vault operator unseal` (или настройте auto-unseal).

---

## Вариант A: HTTP, порт 80 (без TLS)

Схема: браузер → **nginx :80** → Vault `127.0.0.1:8200`.

Подходит, если сертификата нет и доступ только из доверенной сети.

### A1. Установка nginx и firewall

```bash
sudo dnf install -y nginx
sudo systemctl enable --now nginx

sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
```

### A2. Конфиг nginx для Vault

Создайте `/etc/nginx/conf.d/vault.conf`:

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name vault.example.local;   # или IP / FQDN сервера

    client_max_body_size 16m;

    location / {
        proxy_pass http://127.0.0.1:8200;
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
    }
}
```

Если в `/etc/nginx/nginx.conf` уже есть `default_server` на порту 80 — уберите `default_server` из одного из блоков или отключите дефолтный сайт, чтобы не было конфликта.

Проверка и перезапуск:

```bash
sudo nginx -t
sudo systemctl restart nginx
```

SELinux (если включён):

```bash
sudo setsebool -P httpd_can_network_connect 1
```

### A3. api_addr для внешнего HTTP

В `/etc/vault.d/vault.hcl` укажите адрес, по которому клиенты открывают UI:

```hcl
api_addr = "http://vault.example.local"
# или: api_addr = "http://192.168.1.50"
```

Перезапуск:

```bash
sudo systemctl restart vault
# затем снова unseal, если нужно
```

### A4. Доступ к веб-UI

В браузере:

```text
http://vault.example.local
http://IP_СЕРВЕРА
http://vault.example.local/ui/
```

CLI с другой машины (если порт 80 проброшен):

```bash
export VAULT_ADDR='http://vault.example.local'
vault login <token>
```

Проверка:

```bash
curl -s http://127.0.0.1/v1/sys/health | head
curl -sI http://127.0.0.1/ui/ | head
```

---

## Создание своего SSL-сертификата

Пошаговый сценарий **от настройки параметров до установки** на сервер. Нужен для вариантов **B** и **C (HTTPS)**.

### Готовый скрипт (рекомендуется)

Скрипт сам проходит шаги 1–8: ставит OpenSSL (если нужно), создаёт CA и сертификат, кладёт файлы в `/etc/ssl`, добавляет доверие и запись в `/etc/hosts`.

```bash
# из корня репозитория
chmod +x scripts/create-vault-ssl-cert.sh

# своя CA + установка (вариант по умолчанию)
sudo ./scripts/create-vault-ssl-cert.sh --fqdn vault.example.local --ip 192.168.1.50

# для варианта C (Vault сам на :443) — права ключа для пользователя vault
sudo ./scripts/create-vault-ssl-cert.sh --fqdn vault.example.local --ip 192.168.1.50 --for-vault-user

# короткий self-signed без своей CA
sudo ./scripts/create-vault-ssl-cert.sh --fqdn vault.example.local --ip 192.168.1.50 --mode selfsigned

# только сгенерировать файлы, без установки в систему
./scripts/create-vault-ssl-cert.sh --fqdn vault.example.local --ip 192.168.1.50 --no-install --no-trust --no-hosts
```

После успеха файлы будут здесь:

| Путь | Назначение |
|---|---|
| `~/vault-certs/` | рабочие файлы (CA, ключи, CSR) |
| `/etc/ssl/certs/vault.crt` | сертификат (цепочка) для nginx / Vault |
| `/etc/ssl/private/vault.key` | закрытый ключ |

Дальше — [шаг 9](#шаг-9-дальше--настройка-https) (вариант B или C). Справка: `./scripts/create-vault-ssl-cert.sh --help`.

Ниже — те же действия **вручную**, по шагам.

---

Если уже есть готовый `.crt` / `.key` (Let's Encrypt, корпоративный CA) — переходите сразу к [шагу 7](#шаг-7-установка-сертификата-на-сервер) и положите свои файлы в те же пути.

Рекомендуемый путь вручную: **своя CA → сертификат сервера → установка → доверие на клиентах**. Для быстрой лабы есть [короткий self-signed](#альтернатива-короткий-self-signed-без-своей-ca) после шага 6.

Порядок шагов:

| Шаг | Что делаете |
|---|---|
| 1 | Установка OpenSSL |
| 2 | Задание имени и IP |
| 3 | Каталог и конфиг корневого CA |
| 4 | Создание корневого CA |
| 5 | Конфиг и CSR сервера Vault |
| 6 | Подпись сертификата сервера |
| 7 | Установка на сервер |
| 8 | Доверие на клиентах |
| 9 | Переход к HTTPS (вариант B или C) |

> Не публикуйте `*.key` и не коммитьте их в git. Self-signed / своя CA — для LAN и лаборатории; в интернет лучше Let's Encrypt или корпоративный CA.

### Шаг 1. Установка OpenSSL

```bash
sudo dnf install -y openssl
openssl version
```

### Шаг 2. Задайте имя хоста и IP

Замените значения на свои и сохраните в переменные (будут использоваться в следующих шагах):

```bash
export VAULT_FQDN="vault.example.local"
export VAULT_IP="192.168.1.50"   # IP сервера; если не нужен — оставьте пустым: ""
```

Проверка:

```bash
echo "FQDN=$VAULT_FQDN  IP=$VAULT_IP"
```

При необходимости добавьте DNS/hosts (на сервере и на клиентах):

```bash
echo "$VAULT_IP $VAULT_FQDN" | sudo tee -a /etc/hosts
```

### Шаг 3. Каталог и настройка конфига корневого CA

```bash
mkdir -p ~/vault-certs/ca
cd ~/vault-certs/ca

cat > ca.cnf <<EOF
[ req ]
default_bits       = 4096
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
C  = RU
ST = Region
L  = City
O  = MyOrg Vault CA
CN = MyOrg Vault Root CA

[ v3_ca ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage         = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
```

При необходимости отредактируйте `C`, `ST`, `L`, `O`, `CN` в `ca.cnf` под свою организацию.

### Шаг 4. Создание корневого CA

```bash
cd ~/vault-certs/ca

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out ca.key
chmod 600 ca.key

openssl req -new -x509 -days 3650 -key ca.key -config ca.cnf -out ca.crt

openssl x509 -in ca.crt -noout -subject -dates
```

Ожидаемый результат: файлы `ca.key` (секрет) и `ca.crt` (его потом ставят в доверенные на клиентах).

### Шаг 5. Настройка конфига сервера и создание CSR

```bash
cd ~/vault-certs

# SAN: DNS + localhost + IP (если задан)
SAN_LINES="DNS.1 = ${VAULT_FQDN}
DNS.2 = localhost
IP.1  = 127.0.0.1"
if [ -n "$VAULT_IP" ]; then
  SAN_LINES="${SAN_LINES}
IP.2  = ${VAULT_IP}"
fi

cat > vault.cnf <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt             = no

[ req_distinguished_name ]
C  = RU
ST = Region
L  = City
O  = MyOrg
CN = ${VAULT_FQDN}

[ req_ext ]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[ alt_names ]
${SAN_LINES}
EOF

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out vault.key
chmod 600 vault.key

openssl req -new -key vault.key -config vault.cnf -out vault.csr

openssl req -in vault.csr -noout -subject -verify
```

### Шаг 6. Подпись сертификата сервера своим CA

```bash
cd ~/vault-certs

# те же SAN, что в vault.cnf
SAN_LINES="DNS.1 = ${VAULT_FQDN}
DNS.2 = localhost
IP.1  = 127.0.0.1"
if [ -n "$VAULT_IP" ]; then
  SAN_LINES="${SAN_LINES}
IP.2  = ${VAULT_IP}"
fi

cat > vault-sign.cnf <<EOF
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ alt_names ]
${SAN_LINES}
EOF

openssl x509 -req -in vault.csr -CA ca/ca.crt -CAkey ca/ca.key \
  -CAcreateserial -out vault.crt -days 825 \
  -extfile vault-sign.cnf

# цепочка для nginx (серверный сертификат + CA)
cat vault.crt ca/ca.crt > vault-fullchain.crt

openssl verify -CAfile ca/ca.crt vault.crt
openssl x509 -in vault.crt -noout -subject -issuer -dates -ext subjectAltName
```

Файлы после шагов 3–6:

| Файл | Назначение |
|---|---|
| `~/vault-certs/ca/ca.crt` | корневой CA — в доверенные на клиентах |
| `~/vault-certs/ca/ca.key` | ключ CA — только офлайн / в сейфе |
| `~/vault-certs/vault.crt` | сертификат сервера |
| `~/vault-certs/vault.key` | ключ сервера |
| `~/vault-certs/vault-fullchain.crt` | сервер + CA (удобно отдать nginx) |

### Шаг 7. Установка сертификата на сервер

```bash
sudo mkdir -p /etc/ssl/certs /etc/ssl/private

# для nginx (вариант B) лучше полная цепочка:
sudo cp ~/vault-certs/vault-fullchain.crt /etc/ssl/certs/vault.crt
# если цепочки нет (короткий self-signed) — так:
# sudo cp ~/vault-certs/vault.crt /etc/ssl/certs/vault.crt

sudo cp ~/vault-certs/vault.key /etc/ssl/private/vault.key
sudo chmod 644 /etc/ssl/certs/vault.crt
sudo chmod 600 /etc/ssl/private/vault.key
sudo chown root:root /etc/ssl/private/vault.key
```

Если дальше пойдёте по **варианту C** (Vault сам слушает 443), дайте читать ключ пользователю `vault`:

```bash
sudo chown root:vault /etc/ssl/private/vault.key
sudo chmod 640 /etc/ssl/private/vault.key
```

Проверка установки:

```bash
sudo ls -l /etc/ssl/certs/vault.crt /etc/ssl/private/vault.key
openssl x509 -in /etc/ssl/certs/vault.crt -noout -subject -issuer -dates
```

### Шаг 8. Доверие сертификату на клиентах

На машинах, с которых открываете UI / вызываете CLI, установите **корневой CA** (не ключ сервера):

```bash
sudo cp ~/vault-certs/ca/ca.crt /etc/pki/ca-trust/source/anchors/vault-ca.crt
sudo update-ca-trust extract
```

Если используете [короткий self-signed](#альтернатива-короткий-self-signed-без-своей-ca) без CA — в anchors кладите сам `vault.crt`:

```bash
# sudo cp ~/vault-certs/vault.crt /etc/pki/ca-trust/source/anchors/vault.crt
# sudo update-ca-trust extract
```

Проверка CLI (после того как поднимется HTTPS):

```bash
export VAULT_ADDR="https://${VAULT_FQDN}"
# без доверия временно: export VAULT_SKIP_VERIFY=1
vault status
```

В браузере перезапустите окно; на Windows/macOS импортируйте `ca.crt` в «Доверенные корневые центры» / Keychain.

### Шаг 9. Дальше — настройка HTTPS

Сертификат готов и лежит в `/etc/ssl/...`. Продолжите одним из вариантов:

1. [Вариант B: HTTPS через nginx :443](#вариант-b-https-порт-443-через-nginx) — рекомендуется  
2. [Вариант C2: Vault слушает 443 сам](#c2-https-на-порту-443)

---

### Альтернатива: короткий self-signed (без своей CA)

Только для лаборатории. Вместо шагов 3–6 выполните один блок, затем снова [шаг 7](#шаг-7-установка-сертификата-на-сервер) и [шаг 8](#шаг-8-доверие-сертификату-на-клиентах) (в доверенные — сам `vault.crt`).

```bash
# шаги 1–2 уже выполнены (OpenSSL + VAULT_FQDN / VAULT_IP)
mkdir -p ~/vault-certs && cd ~/vault-certs

SAN_LINES="DNS.1 = ${VAULT_FQDN}
DNS.2 = localhost
IP.1  = 127.0.0.1"
if [ -n "$VAULT_IP" ]; then
  SAN_LINES="${SAN_LINES}
IP.2  = ${VAULT_IP}"
fi

cat > vault.cnf <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt             = no

[ req_distinguished_name ]
C  = RU
ST = Region
L  = City
O  = Org
CN = ${VAULT_FQDN}

[ req_ext ]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[ alt_names ]
${SAN_LINES}
EOF

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out vault.key
chmod 600 vault.key

openssl req -new -x509 -days 825 -key vault.key \
  -config vault.cnf -extensions req_ext -out vault.crt

# для шага 7 (полная цепочка = сам сертификат)
cp vault.crt vault-fullchain.crt

openssl x509 -in vault.crt -noout -subject -dates -ext subjectAltName
```

Дальше: шаг 7 → шаг 8 → шаг 9.

---

## Вариант B: HTTPS, порт 443 (через nginx)

Схема: браузер → **nginx :443 (TLS)** → Vault `127.0.0.1:8200` (без TLS на localhost).

Рекомендуемый способ для веб-доступа.

> Перед B1–B5 выполните [создание сертификата: шаги 1–8](#создание-своего-ssl-сертификата), чтобы файлы уже лежали в `/etc/ssl/certs/vault.crt` и `/etc/ssl/private/vault.key`.

### B1. DNS / hosts

Если ещё не сделали на [шаге 2](#шаг-2-задайте-имя-хоста-и-ip):

```bash
echo '<IP_СЕРВЕРА> vault.example.local' | sudo tee -a /etc/hosts
```

Замените `vault.example.local` на ваш FQDN.

### B2. Проверка сертификатов

Убедитесь, что установка из [шага 7](#шаг-7-установка-сертификата-на-сервер) прошла:

```bash
sudo ls -l /etc/ssl/certs/vault.crt /etc/ssl/private/vault.key
openssl x509 -in /etc/ssl/certs/vault.crt -noout -subject -issuer -dates
```

Если сертификат уже есть с другой машины — скопируйте вручную:

```bash
sudo mkdir -p /etc/ssl/certs /etc/ssl/private
sudo cp /path/to/your.crt /etc/ssl/certs/vault.crt
sudo cp /path/to/your.key /etc/ssl/private/vault.key
sudo chmod 644 /etc/ssl/certs/vault.crt
sudo chmod 600 /etc/ssl/private/vault.key
```

### B3. nginx: HTTP → HTTPS и прокси на Vault

`/etc/nginx/conf.d/vault.conf`:

```nginx
# Редирект HTTP → HTTPS
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name vault.example.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name vault.example.local;

    ssl_certificate     /etc/ssl/certs/vault.crt;
    ssl_certificate_key /etc/ssl/private/vault.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    client_max_body_size 16m;

    location / {
        proxy_pass http://127.0.0.1:8200;
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
    }
}
```

```bash
sudo dnf install -y nginx
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl restart nginx

sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload

sudo setsebool -P httpd_can_network_connect 1
sudo setsebool -P httpd_read_user_content 1
```

### B4. api_addr для HTTPS

В `/etc/vault.d/vault.hcl`:

```hcl
api_addr = "https://vault.example.local"
```

```bash
sudo systemctl restart vault
# unseal при необходимости
```

### B5. Доступ к веб-UI

```text
https://vault.example.local
https://vault.example.local/ui/
```

CLI:

```bash
export VAULT_ADDR='https://vault.example.local'
# при self-signed без доверия в OS:
# export VAULT_SKIP_VERIFY=1
vault status
vault login <token>
```

Проверка:

```bash
curl -sk https://vault.example.local/v1/sys/health
curl -skI https://vault.example.local/ui/
```

В браузере при self-signed подтвердите исключение безопасности (или импортируйте CA).

---

## Вариант C: Vault слушает 80 или 443 напрямую

Без nginx. Порты &lt; 1024 требуют capabilities.

### C1. HTTP на порту 80

`/etc/vault.d/vault.hcl`:

```hcl
ui = true

storage "file" {
  path = "/var/lib/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:80"
  tls_disable = 1
}

api_addr = "http://vault.example.local"
```

В `vault.service` добавьте возможность bind на привилегированный порт:

```ini
AmbientCapabilities=CAP_IPC_LOCK CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK CAP_NET_BIND_SERVICE
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart vault
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
```

UI: `http://vault.example.local` или `http://IP_СЕРВЕРА`.

### C2. HTTPS на порту 443

Сначала выполните [создание сертификата: шаги 1–7](#создание-своего-ssl-сертификата) (на шаге 7 обязательно права `root:vault` на ключ). Файлы должны быть:

- `/etc/ssl/certs/vault.crt`
- `/etc/ssl/private/vault.key`

```hcl
ui = true

storage "file" {
  path = "/var/lib/vault/data"
}

listener "tcp" {
  address       = "0.0.0.0:443"
  tls_cert_file = "/etc/ssl/certs/vault.crt"
  tls_key_file  = "/etc/ssl/private/vault.key"
  # tls_min_version = "tls12"
}

api_addr = "https://vault.example.local"
```

Права на ключ для пользователя `vault` (если ещё не сделали на шаге 7):

```bash
sudo chown root:vault /etc/ssl/private/vault.key
sudo chmod 640 /etc/ssl/private/vault.key
```

Те же `CAP_NET_BIND_SERVICE` в unit-файле, firewall `https`, restart + unseal.

UI: `https://vault.example.local`.

CLI:

```bash
export VAULT_ADDR='https://vault.example.local'
vault status
```

> Для продакшена удобнее вариант B: TLS и сертификаты централизованно в nginx, Vault остаётся на localhost.

---

## 4. Работа с веб-интерфейсом

После входа по Token доступны разделы:

| Раздел | Назначение |
|---|---|
| **Secrets Engines** | движки секретов (KV, database, PKI и т.д.) |
| **Access** | методы auth, сущности, группы |
| **Policies** | политики ACL |
| **Tools** | wrap/unwrap, генерация хешей и т.п. |
| **Status** | seal/unseal, health (зависит от версии UI) |

### Типовой сценарий в UI (KV)

1. Войдите токеном (Root или с политикой на `secret/`).
2. **Secrets** → движок `secret/` (в `-dev` KV v2 уже включён).
3. **Create secret** → путь, например `myapp/config`.
4. Добавьте пары: `username=admin`, `password=secret123`.
5. **Save** → читайте / обновляйте версии через UI.

В production после init включите KV:

```bash
vault secrets enable -path=secret kv-v2
```

или в UI: **Enable new engine** → **KV** → Version 2 → path `secret`.

---

## 5. Работа с секретами через CLI

Команды из БЗ РЕД ОС (после `export VAULT_ADDR=...` и `vault login`).

### Запись

```bash
vault kv put secret/myapp/config username=admin password=secret123

vault kv put secret/myapp/database \
    host=localhost \
    port=5432 \
    username=app_user \
    password=secure_pass_123 \
    ssl_mode=require
```

### Чтение

```bash
vault kv get secret/myapp/config
vault kv get -field=username secret/myapp/config
vault kv get -format=json secret/myapp/config
```

### Версии

```bash
vault kv get -version=1 secret/myapp/config
vault kv metadata get secret/myapp/config
```

### Удаление

```bash
vault kv delete secret/myapp/config                 # soft-delete
vault kv destroy -versions=1 secret/myapp/config  # уничтожить версию
vault kv metadata delete secret/myapp/config      # всё + метаданные
```

### Навигация

```bash
vault kv list secret/
vault kv list secret/myapp/
```

### Токены

```bash
vault token lookup
vault token create -policy=default -ttl=1h
vault token revoke hvs.CAESIJRk1...
vault token revoke -self
rm -f ~/.vault-token
```

---

## 6. Полный пример (как в БЗ + веб)

1. Установите Vault, поднимите боевой сервер (раздел 3) или `-dev`.
2. Для внешнего веб-доступа настройте **вариант A (80)** или **B (443)**.
3. Откройте UI, войдите токеном.
4. Через CLI или UI создайте секреты:

```bash
vault kv put secret/myapp/database host=localhost port=5432 user=app_user password=secure_pass
vault kv put secret/myapp/api key=abc123 secret=xyz789
vault kv list secret/myapp/
vault kv get -field=password secret/myapp/database
vault kv put secret/myapp/database password=new_secure_pass
vault kv get -version=1 secret/myapp/database
vault kv get -version=2 secret/myapp/database
vault token create -policy=default -ttl=30m
```

5. Завершение сессии:

```bash
vault token revoke -self
rm -f ~/.vault-token
```

---

## 7. Firewall: сводка

| Сценарий | Правила |
|---|---|
| Только CLI/UI на localhost | внешние порты не открывать |
| Вариант A | `firewall-cmd --permanent --add-service=http` |
| Вариант B | `http` + `https` (редирект 80→443) |
| Вариант C :80 | `http` |
| Вариант C :443 | `https` |
| Dev 8200 снаружи (не рекомендуется) | `--add-port=8200/tcp` |

```bash
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```

Порт **8200** снаружи открывать не нужно, если используете nginx на 80/443.

---

## 8. Проверка работоспособности

```bash
# служба
sudo systemctl status vault nginx --no-pager

# слушатели
sudo ss -tlnp | grep -E ':80|:443|:8200'

# health Vault напрямую
curl -s http://127.0.0.1:8200/v1/sys/health

# через HTTP :80
curl -s http://127.0.0.1/v1/sys/health

# через HTTPS :443
curl -sk https://127.0.0.1/v1/sys/health

# UI
curl -sI http://127.0.0.1/ui/ | head
curl -skI https://127.0.0.1/ui/ | head
```

`vault status` должен показывать `Initialized: true`, `Sealed: false`.

---

## 9. Типовые проблемы

| Симптом | Что проверить |
|---|---|
| UI не открывается | `ui = true`, служба vault запущена, unseal выполнен |
| 502 Bad Gateway (nginx) | Vault слушает `127.0.0.1:8200`, `setsebool -P httpd_can_network_connect 1` |
| Браузер ругается на сертификат | выполните [шаг 8](#шаг-8-доверие-сертификату-на-клиентах); лучше путь со своей CA (шаги 3–6) |
| `permission denied` на :80/:443 | нет `CAP_NET_BIND_SERVICE` у unit-файла |
| `Sealed: true` после reboot | выполните `vault operator unseal` (× threshold) |
| CLI: certificate signed by unknown authority | `update-ca-trust` или временно `VAULT_SKIP_VERIFY=1` |
| Конфликт nginx default_server | один `default_server` на порт; правьте `nginx.conf` / `conf.d` |

---

## 10. Ссылки

- [Vault — база знаний РЕД ОС](https://redos.red-soft.ru/base/redos-8_0/8_0-administation/8_0-monitoring/8_0-infrastructure-automation/8_0-Vault/)
- [SSL для веб-серверов — РЕД ОС](https://redos.red-soft.ru/base/redos-8_0/8_0-security/8_0-ssl/8_0-ssl-for-webserv/)
- [Официальная документация Vault](https://developer.hashicorp.com/vault/docs)
- [TCP listener / TLS](https://developer.hashicorp.com/vault/docs/configuration/listener/tcp)

---

## Краткая шпаргалка: что выбрать

```text
Нужен веб быстро на этой же машине?
  → vault server -dev … → http://127.0.0.1:8200

Нужен веб в LAN без сертификата?
  → Вариант A: nginx :80 → Vault :8200 → http://IP/

Нужен нормальный HTTPS в браузере?
  → sudo ./scripts/install-vault-redos.sh --fqdn ... --ip ...
    (init/unseal сразу; ключи в /root/vault-init-KEYS.txt)

Без nginx, один процесс?
  → sudo ./scripts/install-vault-redos.sh ... --access direct-https
```
