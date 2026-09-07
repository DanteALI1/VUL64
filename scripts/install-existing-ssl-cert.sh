#!/usr/bin/env bash
# Установка УЖЕ ВЫПУЩЕННЫХ сертификатов (корпоративный CA / Let's Encrypt / купленный SSL)
# для Vaultwarden и/или HashiCorp Vault на РЕД ОС.
#
# Нужны файлы:
#   --cert   сертификат сервера (.crt / .pem) ИЛИ полная цепочка
#   --key    закрытый ключ (.key / .pem)
#   --chain  (опционально) промежуточный/корневой CA — склеивается в fullchain
#
# Примеры:
#   sudo ./scripts/install-existing-ssl-cert.sh \
#     --target vaultwarden \
#     --cert /path/to/server.crt \
#     --key  /path/to/server.key \
#     --chain /path/to/ca-bundle.crt
#
#   sudo ./scripts/install-existing-ssl-cert.sh \
#     --target vault \
#     --cert ./fullchain.pem \
#     --key  ./privkey.pem
#
#   sudo ./scripts/install-existing-ssl-cert.sh \
#     --target both \
#     --cert ./cert.pem --key ./key.pem --restart

set -euo pipefail

TARGET="vaultwarden"   # vaultwarden | vault | both
CERT=""
KEY=""
CHAIN=""
RESTART=0
FORCE=0

VW_SSL_DIR="/opt/vaultwarden/ssl"
VAULT_CERT="/etc/ssl/certs/vault.crt"
VAULT_KEY="/etc/ssl/private/vault.key"

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/install-existing-ssl-cert.sh --cert <файл> --key <файл> [опции]

Обязательно:
  --cert FILE     сертификат сервера (.crt/.pem) или уже готовый fullchain
  --key FILE      закрытый ключ (.key/.pem)

Опции:
  --chain FILE    промежуточный/CA bundle (если --cert без цепочки)
  --target vaultwarden|vault|both
                  куда поставить (по умолчанию vaultwarden)
  --vw-dir PATH   каталог SSL Vaultwarden (по умолчанию /opt/vaultwarden/ssl)
  --restart       перезапустить сервисы после установки
  --force         перезаписать существующие файлы
  -h, --help

Куда кладётся:
  vaultwarden → /opt/vaultwarden/ssl/fullchain.pem + privkey.pem
  vault       → /etc/ssl/certs/vault.crt + /etc/ssl/private/vault.key

Что прислать/подготовить от УЦ:
  1) сертификат сервера (часто server.crt / domain.crt)
  2) закрытый ключ (server.key) — храните в секрете
  3) цепочку CA / intermediate (ca-bundle.crt) — если дают отдельно
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
    --target) TARGET="${2:-}"; shift 2 ;;
    --vw-dir) VW_SSL_DIR="${2:-}"; shift 2 ;;
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
case "$TARGET" in vaultwarden|vault|both) ;; *) die "--target: vaultwarden|vault|both" ;; esac
command -v openssl >/dev/null 2>&1 || die "нужен openssl"

TMPDIR_SSL="$(mktemp -d /tmp/existing-ssl.XXXXXX)"
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

log "Проверка сертификата и ключа"
openssl x509 -in "$FULLCHAIN" -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null || \
  openssl x509 -in "$FULLCHAIN" -noout -subject -issuer -dates

# ключ и cert должны совпадать
cert_mod="$(openssl x509 -noout -modulus -in "$FULLCHAIN" | openssl md5)"
key_mod="$(openssl rsa -noout -modulus -in "$PRIVKEY" 2>/dev/null | openssl md5 || \
           openssl pkey -noout -modulus -in "$PRIVKEY" | openssl md5)"
[[ "$cert_mod" == "$key_mod" ]] || die "сертификат и ключ НЕ совпадают (разный modulus)"
ok "пара cert/key совпадает"

install_vw() {
  log "Установка для Vaultwarden → ${VW_SSL_DIR}"
  mkdir -p "$VW_SSL_DIR"
  if [[ -f "${VW_SSL_DIR}/fullchain.pem" && "$FORCE" -ne 1 ]]; then
    die "уже есть ${VW_SSL_DIR}/fullchain.pem — укажите --force"
  fi
  cp "$FULLCHAIN" "${VW_SSL_DIR}/fullchain.pem"
  cp "$PRIVKEY" "${VW_SSL_DIR}/privkey.pem"
  chmod 644 "${VW_SSL_DIR}/fullchain.pem"
  chmod 600 "${VW_SSL_DIR}/privkey.pem"
  ls -l "${VW_SSL_DIR}/fullchain.pem" "${VW_SSL_DIR}/privkey.pem"
  ok "Vaultwarden SSL готов"
}

install_vault() {
  log "Установка для HashiCorp Vault → ${VAULT_CERT}"
  mkdir -p /etc/ssl/certs /etc/ssl/private
  if [[ -f "$VAULT_CERT" && "$FORCE" -ne 1 ]]; then
    die "уже есть ${VAULT_CERT} — укажите --force"
  fi
  cp "$FULLCHAIN" "$VAULT_CERT"
  cp "$PRIVKEY" "$VAULT_KEY"
  chmod 644 "$VAULT_CERT"
  chmod 600 "$VAULT_KEY"
  chown root:root "$VAULT_KEY"
  # если Vault слушает 443 сам — группе vault нужен доступ
  if getent group vault >/dev/null 2>&1; then
    chown root:vault "$VAULT_KEY"
    chmod 640 "$VAULT_KEY"
  fi
  ls -l "$VAULT_CERT" "$VAULT_KEY"
  ok "Vault SSL готов"
}

do_restart() {
  [[ "$RESTART" -eq 1 ]] || return 0
  log "Перезапуск сервисов"
  if [[ "$TARGET" == "vaultwarden" || "$TARGET" == "both" ]]; then
    if [[ -f /opt/vaultwarden/docker-compose.yml ]]; then
      (cd /opt/vaultwarden && docker compose up -d) || true
      ok "Vaultwarden compose обновлён"
    else
      log " /opt/vaultwarden/docker-compose.yml нет — перезапуск пропущен"
    fi
  fi
  if [[ "$TARGET" == "vault" || "$TARGET" == "both" ]]; then
    systemctl restart nginx 2>/dev/null || true
    systemctl restart vault 2>/dev/null || true
    ok "nginx/vault перезапущены (если были)"
  fi
}

case "$TARGET" in
  vaultwarden) install_vw ;;
  vault) install_vault ;;
  both) install_vw; install_vault ;;
esac

do_restart

cat <<EOF

Готово. Установлены ваши сертификаты (target=${TARGET}).

Дальше для Vaultwarden (если ещё не ставили стек):
  sudo ./scripts/install-vaultwarden-redos.sh \\
    --fqdn <имя_из_сертификата> --ip <IP> \\
    --cert-file ${VW_SSL_DIR}/fullchain.pem \\
    --key-file  ${VW_SSL_DIR}/privkey.pem \\
    --force

Или только подложить файлы и перезапустить уже установленный стек:
  cd /opt/vaultwarden && sudo docker compose up -d

Имя в браузере/клиенте должно совпадать с CN/SAN сертификата.
EOF
