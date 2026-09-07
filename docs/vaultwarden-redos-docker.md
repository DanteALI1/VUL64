# Установка Vaultwarden на РЕД ОС (Docker)

Пошаговая инструкция по развёртыванию [Vaultwarden](https://github.com/dani-garcia/vaultwarden) на сервере **РЕД ОС** через Docker.

Vaultwarden — неофициальный совместимый с Bitwarden сервер паролей.

Выберите вариант:

| Вариант | Порт | Сертификат | Когда использовать |
|---|---|---|---|
| [A. HTTP без HTTPS](#вариант-a-http-порт-80-без-https) | **80** | не нужен | локальная сеть / тест, нет сертификата |
| [B. HTTPS + self-signed](#вариант-b-https-порт-443-самоподписанный-сертификат) | **443** | свой `.crt` / `.key` | нужен HTTPS |
| [C. HTTPS без nginx](#вариант-c-https-без-nginx-rocket_tls) | **443** | свой `.crt` / `.key` | простой TLS прямо в Vaultwarden |

> **Важно:** вариант A (HTTP) подходит только для доверенной локальной сети. Пароли и токены идут открытым текстом. В интернет так не выставляйте.

---

## Общее: установка Docker на РЕД ОС

```bash
sudo dnf upgrade -y
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

Перелогиньтесь, затем проверьте:

```bash
docker --version
docker compose version
```

---

## Вариант A: HTTP, порт 80, без HTTPS

Если **нет** самоподписанного сертификата — используйте этот вариант.

### A1. Firewall

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
```

### A2. Каталог

```bash
sudo mkdir -p /opt/vaultwarden/data
```

Сертификаты и nginx **не нужны**.

### A3. Docker Compose

Создайте файл `/opt/vaultwarden/docker-compose.yml`:

```yaml
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      # Для доступа по IP укажите http://IP_СЕРВЕРА
      DOMAIN: "http://vault.example.local"
      SIGNUPS_ALLOWED: "true"
      # ADMIN_TOKEN: "сгенерируйте_длинный_токен"
    volumes:
      - ./data:/data
    ports:
      - "80:80"
```

Замените `vault.example.local` на DNS-имя или IP сервера, например:

```yaml
DOMAIN: "http://192.168.1.50"
```

Админ-токен (опционально):

```bash
openssl rand -base64 48
```

### A4. Запуск

```bash
cd /opt/vaultwarden
sudo docker compose pull
sudo docker compose up -d
sudo docker compose logs -f
```

Проверка:

```bash
curl http://vault.example.local
# или
curl http://192.168.1.50
sudo docker compose ps
```

Откройте в браузере: `http://IP_или_имя`

1. Создайте аккаунт.
2. Отключите регистрации — в `docker-compose.yml`:

```yaml
SIGNUPS_ALLOWED: "false"
```

3. Перезапустите:

```bash
sudo docker compose up -d
```

### A5. Клиент Bitwarden

В настройках клиента укажите свой сервер:

```text
http://IP_или_имя
```

(без `:80` — порт 80 используется по умолчанию для HTTP.)

---

## Вариант B: HTTPS, порт 443, самоподписанный сертификат

### B1. Firewall

```bash
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

### B2. Каталог и сертификаты

```bash
sudo mkdir -p /opt/vaultwarden/{data,ssl,nginx}
sudo cp /path/to/cert.crt /opt/vaultwarden/ssl/fullchain.pem
sudo cp /path/to/cert.key /opt/vaultwarden/ssl/privkey.pem
sudo chmod 600 /opt/vaultwarden/ssl/privkey.pem
```

> Клиенты Bitwarden плохо работают с недоверенным self-signed. Добавьте CA/сертификат в доверенные на устройствах.

### B3. Конфиг nginx

Файл `/opt/vaultwarden/nginx/nginx.conf`:

Пути к сертификатам — **внутри контейнера** (`./ssl` → `/etc/nginx/certs`):

```nginx
worker_processes auto;

events {
    worker_connections 1024;
}

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
            proxy_pass http://vaultwarden:80;
        }
    }
}
```

| На хосте | В nginx (контейнер) |
|---|---|
| `/opt/vaultwarden/ssl/fullchain.pem` | `/etc/nginx/certs/fullchain.pem` |
| `/opt/vaultwarden/ssl/privkey.pem` | `/etc/nginx/certs/privkey.pem` |

### B4. Docker Compose

Файл `/opt/vaultwarden/docker-compose.yml`:

```yaml
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      DOMAIN: "https://vault.example.local"
      SIGNUPS_ALLOWED: "true"
      # ADMIN_TOKEN: "сгенерируйте_длинный_токен"
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

### B5. Запуск

```bash
cd /opt/vaultwarden
sudo docker compose pull
sudo docker compose up -d
sudo docker compose logs -f
```

Проверка:

```bash
curl -k https://vault.example.local
sudo docker compose ps
```

Откройте: `https://vault.example.local` → создайте аккаунт → поставьте `SIGNUPS_ALLOWED: "false"` → `sudo docker compose up -d`.

---

## Вариант C: HTTPS без nginx (ROCKET_TLS)

Проще, но менее предпочтительно.

```bash
sudo mkdir -p /opt/vaultwarden/{data,ssl}
sudo cp /path/to/cert.crt /opt/vaultwarden/ssl/fullchain.pem
sudo cp /path/to/cert.key /opt/vaultwarden/ssl/privkey.pem
sudo chmod 600 /opt/vaultwarden/ssl/privkey.pem
```

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
      ROCKET_TLS: '{certs="/ssl/fullchain.pem",key="/ssl/privkey.pem"}'
    volumes:
      - ./data:/data
      - ./ssl:/ssl:ro
    ports:
      - "443:80"
```

```bash
cd /opt/vaultwarden
sudo docker compose up -d
```

---

## Полезные команды

| Действие | Команда |
|---|---|
| Статус | `cd /opt/vaultwarden && sudo docker compose ps` |
| Логи | `sudo docker compose logs -f` |
| Обновление | `sudo docker compose pull && sudo docker compose up -d` |
| Стоп | `sudo docker compose down` |
| Бэкап данных | `sudo tar czf vw-backup-$(date +%F).tgz -C /opt/vaultwarden data` |

---

## Важные замечания

1. В `DOMAIN` указывайте схему (`http://` или `https://`) так же, как заходите в веб-интерфейс.
2. После первого пользователя всегда ставьте `SIGNUPS_ALLOWED=false`.
3. Данные: `/opt/vaultwarden/data` — делайте бэкапы.
4. Проверка занятых портов:

```bash
ss -tlnp | grep -E ':80|:443'
```

5. HTTP (вариант A) — только в доверенной сети; для продакшена нужен HTTPS.

---

## Ссылки

- Репозиторий: https://github.com/dani-garcia/vaultwarden
- Wiki Docker Compose: https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose
- Enabling HTTPS: https://github.com/dani-garcia/vaultwarden/wiki/Enabling-HTTPS
