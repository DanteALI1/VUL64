# Установка Vaultwarden на РЕД ОС (Docker + HTTPS)

Пошаговая инструкция по развёртыванию [Vaultwarden](https://github.com/dani-garcia/vaultwarden) на сервере **РЕД ОС** через Docker с доступом по **443** и **самоподписанным сертификатом**.

Vaultwarden — неофициальный совместимый с Bitwarden сервер паролей.

Рекомендуемый способ: **Vaultwarden + nginx** (reverse proxy) с вашим TLS-сертификатом.

---

## 0. Подготовка

Замените в примерах:

| Плейсхолдер | Что подставить |
|---|---|
| `vault.example.local` | DNS-имя или IP сервера |
| `/path/to/cert.crt` | путь к вашему сертификату |
| `/path/to/cert.key` | путь к вашему приватному ключу |

Предполагаемые файлы сертификата:

- `/path/to/cert.crt` (или `.pem`)
- `/path/to/cert.key`

> **Важно:** клиенты Bitwarden плохо работают с недоверенным self-signed. Добавьте ваш CA/сертификат в доверенные на ПК и телефонах.

---

## 1. Установка Docker на РЕД ОС

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

Откройте порт HTTPS в firewall (если включён):

```bash
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

---

## 2. Каталог и сертификаты

```bash
sudo mkdir -p /opt/vaultwarden/{data,ssl,nginx}
sudo cp /path/to/cert.crt /opt/vaultwarden/ssl/fullchain.pem
sudo cp /path/to/cert.key /opt/vaultwarden/ssl/privkey.pem
sudo chmod 600 /opt/vaultwarden/ssl/privkey.pem
```

---

## 3. Конфиг nginx

Создайте файл `/opt/vaultwarden/nginx/nginx.conf`:

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

---

## 4. Docker Compose

Создайте файл `/opt/vaultwarden/docker-compose.yml`:

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

Сгенерировать админ-токен (опционально):

```bash
openssl rand -base64 48
```

Вставьте значение в `ADMIN_TOKEN` в `docker-compose.yml`.

---

## 5. Запуск

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

Откройте в браузере: `https://vault.example.local`

1. Создайте аккаунт.
2. Сразу отключите регистрации — в `docker-compose.yml` поставьте:

```yaml
SIGNUPS_ALLOWED: "false"
```

3. Перезапустите:

```bash
sudo docker compose up -d
```

---

## Альтернатива: TLS без nginx

Проще, но менее предпочтительно по официальным рекомендациям Vaultwarden.

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

Запуск:

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

1. В `DOMAIN` обязательно указывайте `https://...` — иначе могут ломаться вложения и ссылки.
2. Self-signed: в клиентах Bitwarden нужно доверить CA вручную, иначе sync может не работать.
3. После создания первого пользователя выставьте `SIGNUPS_ALLOWED=false`.
4. Данные лежат в `/opt/vaultwarden/data` — делайте регулярные бэкапы.
5. Порт 443 не должен быть занят другим сервисом:

```bash
ss -tlnp | grep :443
```

---

## Ссылки

- Репозиторий: https://github.com/dani-garcia/vaultwarden
- Wiki Docker Compose: https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose
- Enabling HTTPS: https://github.com/dani-garcia/vaultwarden/wiki/Enabling-HTTPS
