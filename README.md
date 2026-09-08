# VUL64

Документация и инструкции по развёртыванию сервисов.

## Документы

### Ansible (РЕД ОС)
- [Установка Ansible на РЕД ОС — подробно](docs/ansible-redos.md)
- Скрипт полной установки и настройки (со всеми подсказками): [`scripts/install-ansible-redos.sh`](scripts/install-ansible-redos.sh)

### HashiCorp Vault
- [Vault на РЕД ОС: веб-UI (порты 80 / 443)](docs/vault-redos-web.md)
- Скрипт «всё сразу»: [`scripts/install-vault-redos.sh`](scripts/install-vault-redos.sh)
- Самоподписанный SSL: [`scripts/create-vault-ssl-cert.sh`](scripts/create-vault-ssl-cert.sh)
- **Готовые cert от УЦ:** [`scripts/install-vault-existing-ssl-cert.sh`](scripts/install-vault-existing-ssl-cert.sh)

### Vaultwarden (Bitwarden-совместимый сервер)
- Репозиторий проекта: https://github.com/dani-garcia/vaultwarden
- [Установка на РЕД ОС (Docker) — от и до](docs/vaultwarden-redos-docker.md)
- Скрипт «всё сразу»: [`scripts/install-vaultwarden-redos.sh`](scripts/install-vaultwarden-redos.sh)
- Самоподписанный SSL: [`scripts/create-vaultwarden-ssl-cert.sh`](scripts/create-vaultwarden-ssl-cert.sh)
- Готовые cert (Vaultwarden / оба): [`scripts/install-existing-ssl-cert.sh`](scripts/install-existing-ssl-cert.sh)

### Готовые сертификаты от УЦ
- Vault: [`scripts/install-vault-existing-ssl-cert.sh`](scripts/install-vault-existing-ssl-cert.sh)
- Vaultwarden / оба: [`scripts/install-existing-ssl-cert.sh`](scripts/install-existing-ssl-cert.sh)
- В установщиках: `--cert-file` / `--key-file` / `--chain-file`
