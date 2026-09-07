# VUL64

Документация и инструкции по развёртыванию сервисов.

## Документы

- [HashiCorp Vault на РЕД ОС: веб-UI (порты 80 / 443)](docs/vault-redos-web.md) — установка, init/unseal, секреты; HTTP :80 / HTTPS :443
- **Скрипт «всё сразу»:** [`scripts/install-vault-redos.sh`](scripts/install-vault-redos.sh) — ставит Vault, nginx, SSL, firewall, делает init/unseal и запускает UI
- Только сертификат: [`scripts/create-vault-ssl-cert.sh`](scripts/create-vault-ssl-cert.sh)
