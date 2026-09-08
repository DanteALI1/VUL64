# Установка Vaultwarden на РЕД ОС (Docker) — от и до

Полная инструкция по развёртыванию [Vaultwarden](https://github.com/dani-garcia/vaultwarden) на **РЕД ОС** через Docker Compose.

| Параметр | Значение |
|---|---|
| Проект | [dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden) |
| Образ | `vaultwarden/server:latest` (Docker Hub / ghcr.io) |
| ОС | РЕД ОС 8 (x86_64) |
| БД | встроенный **SQLite** (отдельно ставить не нужно) |
| Данные | `/opt/vaultwarden/data` |

Vaultwarden — неофициальный совместимый с Bitwarden сервер паролей (Rust). Клиенты: веб, расширение, мобильные/десктоп приложения Bitwarden.

| Вариант | Порт | TLS | Когда |
|---|---|---|---|
| [A. HTTP](#вариант-a-http-порт-80) | **80** (вручную) / **8080** (скрипт) | нет | LAN / тест |
| [B. HTTPS + nginx](#вариант-b-https-порт-443) | **443** (вручную) / **8443** (скрипт) | да | рекомендуется |
| [Готовый скрипт](#готовый-скрипт-установить-всё-сразу) | **8080 / 8443** | по флагу | одной командой |

> **Важно:** HTTP передаёт пароли открытым текстом. В интернет без HTTPS не выставляйте. Отдельная БД (PostgreSQL/MySQL) не обязательна — SQLite уже внутри образа.

---

## Готовый скрипт: установить всё сразу

```bash
# из корня репозитория на сервере РЕД ОС
chmod +x scripts/install-vaultwarden-redos.sh scripts/create-vaultwarden-ssl-cert.sh

# HTTPS (рекомендуется): Docker + SSL + nginx на портах 8080/8443
sudo ./scripts/install-vaultwarden-redos.sh \
  --fqdn vault.example.local \
  --ip 192.168.1.50

# UI по умолчанию: https://vault.example.local:8443/

# HTTP без TLS (порт 8080)
sudo ./scripts/install-vaultwarden-redos.sh \
  --fqdn vault.example.local \
  --ip 192.168.1.50 \
  --access http

# Классические 80/443 (если свободны):
sudo ./scripts/install-vaultwarden-redos.sh \
  --fqdn vault.example.local \
  --ip 192.168.1.50 \
  --http-port 80 --https-port 443 --force
```

Скрипт:

1. Ставит Docker / Compose (если нет)  
2. Создаёт `/opt/vaultwarden`  
3. Для HTTPS — выпускает сертификат (своя CA или self-signed)  
4. Пишет `docker-compose.yml` (+ nginx при HTTPS)  
5. Открывает firewall, запускает контейнеры  
6. Печатает URL, admin-токен и следующие шаги  

Справка: `./scripts/install-vaultwarden-redos.sh --help`.

---

## Готовые сертификаты от УЦ (выпустили вам)

Если сертификат выдаёт корпоративный УЦ / Let's Encrypt / провайдер — **не генерируйте self-signed**. Нужны файлы:

| Файл | Что это | Примеры имён |
|---|---|---|
| Сертификат сервера | публичная часть | `server.crt`, `domain.crt`, `cert.pem` |
| Закрытый ключ | секрет | `server.key`, `privkey.pem` |
| Цепочка CA (часто) | intermediate + root | `ca-bundle.crt`, `chain.pem`, `fullchain.pem` |

> Ключ никому не отправляйте и не кладите в git.

### Способ 1. Только положить сертификаты

```bash
chmod +x scripts/install-existing-ssl-cert.sh

sudo ./scripts/install-existing-ssl-cert.sh \
  --target vaultwarden \
  --cert /path/to/server.crt \
  --key  /path/to/server.key \
  --chain /path/to/ca-bundle.crt \
  --force --restart
```

Скрипт проверит, что cert и key совпадают, и запишет:

- `/opt/vaultwarden/ssl/fullchain.pem`
- `/opt/vaultwarden/ssl/privkey.pem`

`--target vault` — для HashiCorp Vault (`/etc/ssl/certs/vault.crt`).  
`--target both` — сразу для обоих.

### Способ 2. Установка Vaultwarden сразу с вашими cert

```bash
sudo ./scripts/install-vaultwarden-redos.sh \
  --fqdn vault.company.ru \
  --ip 192.168.1.57 \
  --cert-file /path/to/server.crt \
  --key-file  /path/to/server.key \
  --chain-file /path/to/ca-bundle.crt \
  --force
```

`--fqdn` должен совпадать с именем в сертификате (CN/SAN). Иначе браузер/клиент Bitwarden будут ругаться.

Если УЦ уже отдал один `fullchain.pem` (сервер + цепочка), `--chain-file` не нужен:

```bash
sudo ./scripts/install-vaultwarden-redos.sh \
  --fqdn vault.company.ru \
  --ip 192.168.1.57 \
  --cert-file /path/to/fullchain.pem \
  --key-file  /path/to/privkey.pem \
  --force
```

### Проверка после установки

```bash
openssl x509 -in /opt/vaultwarden/ssl/fullchain.pem -noout -subject -issuer -dates
cd /opt/vaultwarden && sudo docker compose ps
curl -sI https://vault.company.ru:8443/ | head
```

В клиенте Bitwarden укажите тот же URL, что в `DOMAIN` (с портом, если не 443).

Ниже — ручная установка по шагам (без готовых cert от УЦ).

---

## 1. Установка Docker на РЕД ОС

```bash
sudo dnf upgrade -y
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Перелогиньтесь, затем:

```bash
docker --version
docker compose version
```

---

## 2. Каталог и admin-токен

```bash
sudo mkdir -p /opt/vaultwarden/{data,ssl,nginx}
cd /opt/vaultwarden

# длинный токен для /admin (сохраните!)
openssl rand -base64 48
```

---

## Вариант A: HTTP, порт 80

Только доверенная сеть.

### A1. Firewall

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
```

### A2. docker-compose.yml

Файл `/opt/vaultwarden/docker-compose.yml`:

```yaml
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "http://192.168.1.50"          # или http://vault.example.local
      SIGNUPS_ALLOWED: "true"
      ADMIN_TOKEN: "ВСТАВЬТЕ_ТОКЕН"
    volumes:
      - ./data:/data
    ports:
      - "80:80"
```

### A3. Запуск

```bash
cd /opt/vaultwarden
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
sudo docker compose logs -f
```

Откройте `http://IP/` → создайте аккаунт → затем поставьте `SIGNUPS_ALLOWED: "false"` и:

```bash
sudo docker compose up -d
```

---

## Создание SSL-сертификата (для HTTPS)

Нужно для варианта B. Можно скриптом:

```bash
sudo ./scripts/create-vaultwarden-ssl-cert.sh \
  --fqdn vault.example.local \
  --ip 192.168.1.50
```

Файлы:

| Путь | Назначение |
|---|---|
| `/opt/vaultwarden/ssl/fullchain.pem` | сертификат (+ CA) |
| `/opt/vaultwarden/ssl/privkey.pem` | ключ |
| `~/vaultwarden-certs/` | рабочие файлы / CA |

Или вручную (краткий self-signed):

```bash
export VW_FQDN="vault.example.local"
export VW_IP="192.168.1.50"
mkdir -p ~/vaultwarden-certs && cd ~/vaultwarden-certs

cat > vw.cnf <<EOF
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = req_ext
prompt = no
[ req_distinguished_name ]
C = RU
O = Org
CN = ${VW_FQDN}
[ req_ext ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = ${VW_FQDN}
DNS.2 = localhost
IP.1 = 127.0.0.1
IP.2 = ${VW_IP}
EOF

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out privkey.pem
chmod 600 privkey.pem
openssl req -new -x509 -days 825 -key privkey.pem -config vw.cnf -extensions req_ext -out fullchain.pem

sudo mkdir -p /opt/vaultwarden/ssl
sudo cp fullchain.pem privkey.pem /opt/vaultwarden/ssl/
sudo chmod 600 /opt/vaultwarden/ssl/privkey.pem
```

---

## Вариант B: HTTPS, порт 443

Схема: браузер → **nginx :443** → Vaultwarden `:80` (внутри Docker-сети).

### B1. Firewall

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

### B2. nginx

`/opt/vaultwarden/nginx/nginx.conf`:

```nginx
worker_processes auto;
events { worker_connections 1024; }

http {
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen 80;
        server_name vault.example.local;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl;
        http2 on;
        server_name vault.example.local;

        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        client_max_body_size 128M;

        location / {
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            # Docker DNS (избегает 502 Host is unreachable со старым IP)
            # resolver 127.0.0.11 valid=10s ipv6=off;
            # set $vw_upstream vaultwarden;
            # proxy_pass http://$vw_upstream:80;
            proxy_pass http://vaultwarden:80;
        }
    }
}
```

### B3. docker-compose.yml

`/opt/vaultwarden/docker-compose.yml`:

```yaml
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "https://vault.example.local"
      SIGNUPS_ALLOWED: "true"
      ADMIN_TOKEN: "ВСТАВЬТЕ_ТОКЕН"
    volumes:
      - ./data:/data
    networks:
      - vwnet

  nginx:
    image: nginx:alpine
    container_name: vaultwarden-nginx
    restart: unless-stopped
    depends_on:
      - vaultwarden
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/certs:ro
    networks:
      - vwnet

networks:
  vwnet:
```

`DOMAIN` должен совпадать со схемой и именем/IP, которыми вы заходите в браузер (без двойных слэшей в URL).

### B4. Запуск

```bash
cd /opt/vaultwarden
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
curl -skI https://vault.example.local/ | head
```

Откройте `https://vault.example.local/` (один слэш после хоста). При self-signed подтвердите исключение в браузере.

1. Создайте аккаунт.  
2. `SIGNUPS_ALLOWED: "false"` → `sudo docker compose up -d`.  
3. Админка (если задан токен): `https://vault.example.local/admin`.

---

## Клиент Bitwarden

В настройках клиента укажите свой сервер:

```text
https://vault.example.local
# или
http://192.168.1.50
```

Без лишнего пути и без `//` в URL.

---

## Полезные команды

| Действие | Команда |
|---|---|
| Статус | `cd /opt/vaultwarden && sudo docker compose ps` |
| Логи | `sudo docker compose logs -f` |
| Обновление | `sudo docker compose pull && sudo docker compose up -d` |
| Стоп | `sudo docker compose down` |
| Бэкап | `sudo tar czf vw-backup-$(date +%F).tgz -C /opt/vaultwarden data` |

---

## Типовые проблемы

| Симптом | Что проверить |
|---|---|
| 502 Bad Gateway / Host is unreachable | контейнер `vaultwarden` не запущен или nginx держит старый IP — см. ниже |
| Порт занят (`address already in use`) | На хосте уже слушают 80/443 (часто nginx HashiCorp Vault). См. ниже |
| `paths must be canonical` | URL с `//ui/` — откройте `https://HOST/` или `https://HOST/ui` **без** двойного слэша |
| Браузер ругается на cert | self-signed — ожидаемо; импортируйте CA или используйте `--mode ca` |
| Клиент не логинится | `DOMAIN` = тот же URL, что в клиенте (`http://` vs `https://`) |
| Порт занят | `ss -tlnp \| grep -E ':80\|:443'` |
| Нет данных после recreate | том `./data` не удаляйте |

### 502 Bad Gateway / Host is unreachable

В логах nginx часто:

```text
connect() failed (113: Host is unreachable) while connecting to upstream, upstream: "http://172.x.x.x:80/"
```

Значит nginx жив, а контейнер **Vaultwarden** недоступен (упал, сменил IP, или **firewalld режет Docker-сеть** на РЕД ОС).

```bash
cd /opt/vaultwarden
sudo docker compose ps
sudo docker compose logs --tail=50 vaultwarden

# 1) починить firewalld для Docker bridge (частая причина на РЕД ОС)
sudo firewall-cmd --permanent --zone=public --add-masquerade
sudo firewall-cmd --permanent --zone=trusted --add-interface=docker0
sudo firewall-cmd --permanent --zone=trusted --add-source=172.16.0.0/12
sudo firewall-cmd --reload
sudo systemctl restart docker

# 2) поднять стек заново
cd /opt/vaultwarden
sudo docker compose up -d
sudo docker compose ps

# 3) проверка связи nginx → vaultwarden
sudo docker exec vaultwarden-nginx wget -qO- http://vaultwarden:80/ | head

# сети контейнеров должны совпадать
sudo docker inspect vaultwarden --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}{{"\n"}}{{end}}'
sudo docker inspect vaultwarden-nginx --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}{{"\n"}}{{end}}'
```

Если `wget` из nginx всё ещё `Host is unreachable` — пришлите вывод двух `docker inspect` выше.

Если `vaultwarden` в статусе `Exit`/`Restarting` — смотрите его логи. После починки откройте снова `https://vaultwarden.cloud.novatek.ru:8443/` (без `//`).

### Порты 80/443 уже заняты

Типичная ошибка:

```text
failed to bind host port 0.0.0.0:80/tcp: address already in use
```

Проверка:

```bash
ss -tlnp | grep -E ':80|:443'
```

**Вариант 1 — другие порты** (по умолчанию скрипт уже использует **8080/8443**):

```bash
sudo ./scripts/install-vaultwarden-redos.sh \
  --fqdn vuln --ip 192.168.1.57 --force
```

UI: `https://vuln:8443/`

Если и они заняты:

```bash
sudo ./scripts/install-vaultwarden-redos.sh \
  --fqdn vuln --ip 192.168.1.57 \
  --http-port 9080 --https-port 9443 --force
```

**Вариант 2 — освободить 80/443** (остановить nginx Vault / старый контейнер):

```bash
sudo systemctl stop nginx
# или
sudo docker stop vaultwarden-nginx
sudo ss -tlnp | grep -E ':80|:443'
```

Затем на классических портах:

```bash
sudo ./scripts/install-vaultwarden-redos.sh \
  --fqdn vuln --ip 192.168.1.57 \
  --http-port 80 --https-port 443 --force
```

---

## Ссылки

- Репозиторий: https://github.com/dani-garcia/vaultwarden  
- Wiki Docker Compose: https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose  
- Enabling HTTPS: https://github.com/dani-garcia/vaultwarden/wiki/Enabling-HTTPS  
- Образ: https://hub.docker.com/r/vaultwarden/server  

---

## Краткая шпаргалка

```text
Нужен веб быстро в LAN без TLS?
  → sudo ./scripts/install-vaultwarden-redos.sh --fqdn ... --ip ... --access http

Нужен HTTPS?
  → sudo ./scripts/install-vaultwarden-redos.sh --fqdn ... --ip ...
    UI: https://…:8443/  (порты по умолчанию 8080/8443)

Только сертификат?
  → sudo ./scripts/create-vaultwarden-ssl-cert.sh --fqdn ... --ip ...

Бэкап данных?
  → /opt/vaultwarden/data
```
