#!/usr/bin/env bash
# Установка УЖЕ ВЫПУЩЕННЫХ сертификатов специально для HashiCorp Vault (РЕД ОС).
# Корпоративный УЦ / Let's Encrypt / купленный SSL.
#
# Куда ставит:
#   /etc/ssl/certs/vault.crt
#   /etc/ssl/private/vault.key
#
# Примеры:
#   sudo ./scripts/install-vault-existing-ssl-cert.sh \
#     --cert /path/to/server.crt \
#     --key  /path/to/server.key \
#     --chain /path/to/ca-bundle.crt \
#     --force --restart
#
#   # если Vault сам слушает :443 (вариант C):
#   sudo ./scripts/install-vault-existing-ssl-cert.sh \
#     --cert ./fullchain.pem --key ./privkey.pem --for-vault-user --restart --force

set -euo pipefail

CERT=""
KEY=""
CHAIN=""
RESTART=0
FORCE=0
TRUST=0
FOR_VAULT_USER=0
VAULT_CERT="/etc/ssl/certs/vault.crt"
VAULT_KEY="/etc/ssl/private/vault.key"

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/install-vault-existing-ssl-cert.sh --cert <файл> --key <файл> [опции]

Обязательно:
  --cert FILE           сертификат сервера (.crt/.pem) или готовый fullchain
  --key FILE            закрытый ключ (.key/.pem)

Опции:
  --chain FILE          промежуточный/CA bundle (если --cert без цепочки)
  --cert-out PATH       куда положить cert (по умолчанию /etc/ssl/certs/vault.crt)
  --key-out PATH        куда положить key  (по умолчанию /etc/ssl/private/vault.key)
  --for-vault-user      права ключа root:vault 640 (вариант C: Vault на :443)
  --trust               добавить cert/CA в системное доверие (update-ca-trust)
  --restart             перезапустить nginx и vault после установки
  --force               перезаписать существующие файлы
  -h, --help

Что нужно от УЦ:
  1) сертификат сервера (server.crt / domain.crt / cert.pem)
  2) закрытый ключ (server.key / privkey.pem) — секрет
  3) цепочку CA (ca-bundle.crt / chain.pem) — если дают отдельно

После установки:
  - вариант B (nginx :443): sudo systemctl restart nginx
  - вариант C (Vault :443):  нужны --for-vault-user и restart vault
  - или полный установщик с этими же файлами:
      sudo ./scripts/install-vault-redos.sh --fqdn <имя> --ip <IP> \
        --cert-file ... --key-file ... --chain-file ...
EOF
}

log() { printf '==> %s\n' "$*"; }
ok()  { printf '    OK: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert) CERT="${2:-}"; shift 2 ;;
    --key) KEY="${2:-}"; shift 2 ;;
    --chain) CHAIN="${2:-}"; shift 2 ;;
    --cert-out) VAULT_CERT="${2:-}"; shift 2 ;;
    --key-out) VAULT_KEY="${2:-}"; shift 2 ;;
    --for-vault-user) FOR_VAULT_USER=1; shift ;;
    --trust) TRUST=1; shift ;;
    --restart) RESTART=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "запустите через sudo"
[[ -n "$CERT" && -n "$KEY" ]] || die "укажите --cert и --key (см. --help)"
[[ -f "$CERT" ]] || die "нет файла сертификата: $CERT"
[[ -f "$KEY" ]] || die "нет файла ключа: $KEY"
[[ -z "$CHAIN" || -f "$CHAIN" ]] || die "нет файла цепочки: $CHAIN"
command -v openssl >/dev/null 2>&1 || die "нужен openssl"

TMPDIR_SSL="$(mktemp -d /tmp/vault-existing-ssl.XXXXXX)"
trap 'rm -rf "$TMPDIR_SSL"' EXIT

FULLCHAIN="${TMPDIR_SSL}/fullchain.pem"
PRIVKEY="${TMPDIR_SSL}/privkey.pem"

cp "$KEY" "$PRIVKEY"
chmod 600 "$PRIVKEY"

if [[ -n "$CHAIN" ]]; then
  cat "$CERT" "$CHAIN" > "$FULLCHAIN"
else
  cp "$CERT" "$FULLCHAIN"
fi
chmod 644 "$FULLCHAIN"

log "1/4 Проверка сертификата и ключа (HashiCorp Vault)"
openssl x509 -in "$FULLCHAIN" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || \
  openssl x509 -in "$FULLCHAIN" -noout -subject -issuer -dates

cert_mod="$(openssl x509 -noout -modulus -in "$FULLCHAIN" | openssl md5)"
key_mod="$(openssl rsa -noout -modulus -in "$PRIVKEY" 2>/dev/null | openssl md5 || \
           openssl pkey -noout -modulus -in "$PRIVKEY" | openssl md5)"
[[ "$cert_mod" == "$key_mod" ]] || die "сертификат и ключ НЕ совпадают"
ok "пара cert/key совпадает"

log "2/4 Установка в ${VAULT_CERT} и ${VAULT_KEY}"
mkdir -p "$(dirname "$VAULT_CERT")" "$(dirname "$VAULT_KEY")"
if [[ -f "$VAULT_CERT" && "$FORCE" -ne 1 ]]; then
  die "уже есть ${VAULT_CERT} — укажите --force"
fi
cp "$FULLCHAIN" "$VAULT_CERT"
cp "$PRIVKEY" "$VAULT_KEY"
chmod 644 "$VAULT_CERT"
chmod 600 "$VAULT_KEY"
chown root:root "$VAULT_KEY"

if [[ "$FOR_VAULT_USER" -eq 1 ]]; then
  if getent group vault >/dev/null 2>&1; then
    chown root:vault "$VAULT_KEY"
    chmod 640 "$VAULT_KEY"
    ok "права ключа: root:vault 640 (вариант C)"
  else
    log "группа vault не найдена — оставляю root:root 600"
  fi
fi
ls -l "$VAULT_CERT" "$VAULT_KEY"
ok "файлы установлены"

if [[ "$TRUST" -eq 1 ]]; then
  log "3/4 Доверие в системе"
  mkdir -p /etc/pki/ca-trust/source/anchors
  # если есть отдельный chain — лучше доверять ему; иначе сам cert
  if [[ -n "$CHAIN" ]]; then
    cp "$CHAIN" /etc/pki/ca-trust/source/anchors/vault-issued-ca.crt
  else
    # берём только первый сертификат из fullchain как leaf — для public CA trust не нужен;
    # для корпоративного leaf иногда кладут целиком
    cp "$FULLCHAIN" /etc/pki/ca-trust/source/anchors/vault-issued.crt
  fi
  if command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust extract
    ok "update-ca-trust выполнен"
  else
    log "update-ca-trust не найден — добавьте CA вручную"
  fi
else
  log "3/4 Доверие пропущено (нужно: --trust)"
fi

if [[ "$RESTART" -eq 1 ]]; then
  log "4/4 Перезапуск nginx / vault"
  systemctl restart nginx 2>/dev/null && ok "nginx перезапущен" || log "nginx не перезапущен (нет службы?)"
  systemctl restart vault 2>/dev/null && ok "vault перезапущен" || log "vault не перезапущен (нет службы?)"
  # после restart Vault обычно sealed
  if command -v vault >/dev/null 2>&1; then
    export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
    st="$(vault status 2>&1 || true)"
    if echo "$st" | grep -qi 'Sealed.*true'; then
      log "Vault sealed после restart — нужен unseal (ключи из /root/vault-init-KEYS.txt)"
    fi
  fi
else
  log "4/4 Перезапуск пропущен (нужно: --restart)"
fi

cat <<EOF

Готово. Сертификаты HashiCorp Vault установлены.
  Cert: ${VAULT_CERT}
  Key:  ${VAULT_KEY}

Дальше:
  1) Имя в браузере/CLI = CN/SAN сертификата
  2) Если стек ещё не ставили:
       sudo ./scripts/install-vault-redos.sh --fqdn <имя> --ip <IP> \\
         --cert-file ${VAULT_CERT} --key-file ${VAULT_KEY} --force
  3) Если уже стоит nginx (вариант B):
       sudo systemctl restart nginx
  4) Если Vault на :443 сам (вариант C):
       повторите с --for-vault-user --restart
  5) CLI:
       export VAULT_ADDR='https://<имя>'
       vault status
EOF
