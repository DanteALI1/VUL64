# Удаление Vaultwarden на РЕД ОС — от и до

Отдельная инструкция по **полному снятию** Vaultwarden, установленного по [docs/vaultwarden-redos-docker.md](vaultwarden-redos-docker.md) / скрипту `install-vaultwarden-redos.sh`.

| Что | Путь / имя |
|---|---|
| Каталог | `/opt/vaultwarden` |
| Контейнеры | `vaultwarden`, `vaultwarden-nginx` |
| Данные (пароли) | `/opt/vaultwarden/data` |
| Скрипт удаления | [`scripts/uninstall-vaultwarden-redos.sh`](../scripts/uninstall-vaultwarden-redos.sh) |

> HashiCorp Vault этим скриптом **не удаляется** (другой стек). Docker Engine тоже остаётся.

---

## Готовый скрипт (рекомендуется)

```bash
# из корня репозитория
chmod +x scripts/uninstall-vaultwarden-redos.sh

# сначала план (ничего не удаляет)
sudo ./scripts/uninstall-vaultwarden-redos.sh

# полное удаление, включая данные
sudo ./scripts/uninstall-vaultwarden-redos.sh --yes

# удалить стек, но сохранить пароли (data/)
sudo ./scripts/uninstall-vaultwarden-redos.sh --yes --keep-data

# ещё и образы + рабочие certs
sudo ./scripts/uninstall-vaultwarden-redos.sh --yes --remove-images --purge-certs
```

### Что делает скрипт при `--yes`

1. `docker compose down` в `/opt/vaultwarden`  
2. Удаляет контейнеры `vaultwarden` / `vaultwarden-nginx` и сеть compose  
3. Удаляет `/opt/vaultwarden` (или всё, кроме `data/` при `--keep-data`)  
4. Опционально: образы Docker, `~/vaultwarden-certs`, порты 8080/8443 в firewalld  

Справка: `./scripts/uninstall-vaultwarden-redos.sh --help`.

---

## Ручное удаление (по шагам)

### 1. Остановить и убрать контейнеры

```bash
cd /opt/vaultwarden
sudo docker compose down --remove-orphans
sudo docker rm -f vaultwarden vaultwarden-nginx 2>/dev/null || true
```

### 2. (Опционально) Бэкап данных перед удалением

```bash
sudo tar czf /root/vw-backup-$(date +%F).tgz -C /opt/vaultwarden data
sudo chmod 600 /root/vw-backup-*.tgz
```

### 3. Удалить каталог

```bash
# полностью
sudo rm -rf /opt/vaultwarden

# или оставить только данные:
# sudo find /opt/vaultwarden -mindepth 1 -maxdepth 1 ! -name data -exec rm -rf {} +
```

### 4. (Опционально) Удалить образы

```bash
sudo docker image rm -f vaultwarden/server:latest nginx:alpine
```

### 5. (Опционально) Убрать порты firewalld

Если открывали 8080/8443:

```bash
sudo firewall-cmd --permanent --remove-port=8080/tcp
sudo firewall-cmd --permanent --remove-port=8443/tcp
sudo firewall-cmd --reload
```

Правила `trusted` для `docker0` / `172.16.0.0/12` **не откатывайте**, если на сервере есть другие Docker-сервисы (в том числе могут быть нужны HashiCorp-стеку).

### 6. Рабочие сертификаты (если создавали скриптом)

```bash
sudo rm -rf /root/vaultwarden-certs
sudo rm -rf /home/*/vaultwarden-certs
sudo rm -f /etc/pki/ca-trust/source/anchors/vaultwarden*.crt
sudo update-ca-trust extract
```

---

## Проверка, что всё снято

```bash
sudo docker ps -a | grep -i vaultwarden || echo 'контейнеров Vaultwarden нет'
sudo docker network ls | grep -i vaultwarden || echo 'сетей Vaultwarden нет'
ls /opt/vaultwarden 2>/dev/null || echo 'каталога /opt/vaultwarden нет'
ss -tlnp | grep -E ':8080|:8443' || echo 'порты 8080/8443 свободны'
```

---

## Поставить заново

После удаления:

```bash
sudo ./scripts/install-vaultwarden-redos.sh \
  --fqdn vaultwarden.cloud.novatek.ru \
  --ip 192.168.1.57 \
  --force
```

С готовыми сертификатами от УЦ — см. [Готовые сертификаты от УЦ](vaultwarden-redos-docker.md#готовые-сертификаты-от-уц-выпустили-вам).

---

## Важно

1. Без `--keep-data` удаляются **все сейфы паролей** в SQLite (`/opt/vaultwarden/data`).  
2. `ADMIN_TOKEN` из `/opt/vaultwarden/admin-token.txt` тоже пропадёт вместе с каталогом.  
3. Клиенты Bitwarden нужно будет снова настроить на новый сервер после переустановки.
