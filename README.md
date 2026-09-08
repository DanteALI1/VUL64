# VUL64

Документация и инструкции по развёртыванию сервисов.

## Документы

### HashiCorp Vault
- [Vault на РЕД ОС: веб-UI (порты 80 / 443)](docs/vault-redos-web.md)
- Скрипт «всё сразу»: [`scripts/install-vault-redos.sh`](scripts/install-vault-redos.sh)
- Самоподписанный SSL: [`scripts/create-vault-ssl-cert.sh`](scripts/create-vault-ssl-cert.sh)

### Vaultwarden (Bitwarden-совместимый сервер)
- Репозиторий проекта: https://github.com/dani-garcia/vaultwarden
- [Установка на РЕД ОС (Docker) — от и до](docs/vaultwarden-redos-docker.md)
- Скрипт «всё сразу»: [`scripts/install-vaultwarden-redos.sh`](scripts/install-vaultwarden-redos.sh)
- Самоподписанный SSL: [`scripts/create-vaultwarden-ssl-cert.sh`](scripts/create-vaultwarden-ssl-cert.sh)

### Готовые сертификаты от УЦ
- [`scripts/install-existing-ssl-cert.sh`](scripts/install-existing-ssl-cert.sh) — положить выданный cert/key в Vaultwarden и/или Vault
- В установщиках: `--cert-file` / `--key-file` / `--chain-file`
