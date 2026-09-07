#!/usr/bin/env bash
# Создание и установка SSL-сертификата для HashiCorp Vault (РЕД ОС).
# Покрывает шаги 1–8 инструкции docs/vault-redos-web.md:
#   OpenSSL → параметры → CA → CSR → подпись → /etc/ssl → trust store
#
# Примеры:
#   sudo ./scripts/create-vault-ssl-cert.sh --fqdn vault.example.local --ip 192.168.1.50
#   sudo ./scripts/create-vault-ssl-cert.sh --fqdn vault.lan --ip 10.0.0.5 --mode selfsigned
#   sudo ./scripts/create-vault-ssl-cert.sh --fqdn vault.lan --ip 10.0.0.5 --for-vault-user
#   ./scripts/create-vault-ssl-cert.sh --fqdn vault.lan --no-install   # только файлы в ~/vault-certs

set -euo pipefail

MODE="ca"                 # ca | selfsigned
FQDN=""
IP=""
CERT_DIR="${HOME}/vault-certs"
INSTALL=1
TRUST=1
UPDATE_HOSTS=1
FOR_VAULT_USER=0
ORG="MyOrg"
COUNTRY="RU"
STATE="Region"
CITY="City"
CA_DAYS=3650
SERVER_DAYS=825
FORCE=0

usage() {
  cat <<'EOF'
Использование:
  create-vault-ssl-cert.sh --fqdn <имя> [--ip <IP>] [опции]

Обязательно:
  --fqdn NAME              DNS-имя сервера Vault (CN / SAN)

Опции:
  --ip ADDR                IP в subjectAltName и /etc/hosts (рекомендуется)
  --mode ca|selfsigned     ca = своя CA + серверный cert (по умолчанию)
                           selfsigned = короткий self-signed без CA
  --dir PATH               каталог для файлов (по умолчанию ~/vault-certs)
  --org NAME               организация в DN (по умолчанию MyOrg)
  --no-install             не копировать в /etc/ssl (только генерация)
  --no-trust               не добавлять CA/cert в системное хранилище доверия
  --no-hosts               не добавлять запись в /etc/hosts
  --for-vault-user         права на ключ root:vault 640 (вариант C: Vault :443)
  --force                  перезаписать существующие файлы в --dir
  -h, --help               справка

Примеры:
  sudo ./scripts/create-vault-ssl-cert.sh --fqdn vault.example.local --ip 192.168.1.50
  sudo ./scripts/create-vault-ssl-cert.sh --fqdn vault.lan --ip 10.0.0.5 --mode selfsigned
EOF
}

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "не найдена команда: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fqdn) FQDN="${2:-}"; shift 2 ;;
    --ip) IP="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --dir) CERT_DIR="${2:-}"; shift 2 ;;
    --org) ORG="${2:-}"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    --no-trust) TRUST=0; shift ;;
    --no-hosts) UPDATE_HOSTS=0; shift ;;
    --for-vault-user) FOR_VAULT_USER=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

[[ -n "$FQDN" ]] || die "укажите --fqdn (см. --help)"
[[ "$MODE" == "ca" || "$MODE" == "selfsigned" ]] || die "--mode должен быть ca или selfsigned"

if [[ "$INSTALL" -eq 1 || "$TRUST" -eq 1 || "$UPDATE_HOSTS" -eq 1 ]]; then
  if [[ "${EUID}" -ne 0 ]]; then
    die "для установки/доверия/hosts запускайте через sudo (или добавьте --no-install --no-trust --no-hosts)"
  fi
fi

# При sudo HOME часто /root — если пользователь вызвал sudo, кладём certs в его home
if [[ -n "${SUDO_USER:-}" && "$CERT_DIR" == "/root/vault-certs" ]]; then
  CERT_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/vault-certs"
fi
# Если CERT_DIR всё ещё с ~ в пути
CERT_DIR="${CERT_DIR/#\~/$HOME}"

step_install_openssl() {
  log "Шаг 1. OpenSSL"
  if ! command -v openssl >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y openssl
    elif command -v yum >/dev/null 2>&1; then
      yum install -y openssl
    else
      die "установите openssl вручную"
    fi
  fi
  need openssl
  openssl version
}

build_san() {
  SAN_LINES="DNS.1 = ${FQDN}
DNS.2 = localhost
IP.1  = 127.0.0.1"
  if [[ -n "$IP" ]]; then
    SAN_LINES="${SAN_LINES}
IP.2  = ${IP}"
  fi
}

step_params_and_hosts() {
  log "Шаг 2. Параметры: FQDN=${FQDN} IP=${IP:-<нет>}"
  if [[ "$UPDATE_HOSTS" -eq 1 && -n "$IP" ]]; then
    local line="${IP} ${FQDN}"
    if grep -qE "[[:space:]]${FQDN}([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
      log " /etc/hosts уже содержит ${FQDN} — пропускаю"
    else
      echo "$line" >> /etc/hosts
      log " добавлено в /etc/hosts: ${line}"
    fi
  fi
}

prepare_dir() {
  if [[ -d "$CERT_DIR" && "$FORCE" -ne 1 ]]; then
    if [[ -e "$CERT_DIR/vault.key" || -e "$CERT_DIR/ca/ca.key" ]]; then
      die "в ${CERT_DIR} уже есть ключи. Укажите --force или другой --dir"
    fi
  fi
  mkdir -p "$CERT_DIR/ca"
  chmod 700 "$CERT_DIR"
}

mode_ca() {
  log "Шаги 3–4. Конфиг и создание корневого CA"
  cat > "$CERT_DIR/ca/ca.cnf" <<EOF
[ req ]
default_bits       = 4096
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
C  = ${COUNTRY}
ST = ${STATE}
L  = ${CITY}
O  = ${ORG} Vault CA
CN = ${ORG} Vault Root CA

[ v3_ca ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage         = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$CERT_DIR/ca/ca.key"
  chmod 600 "$CERT_DIR/ca/ca.key"
  openssl req -new -x509 -days "$CA_DAYS" -key "$CERT_DIR/ca/ca.key" \
    -config "$CERT_DIR/ca/ca.cnf" -out "$CERT_DIR/ca/ca.crt"
  openssl x509 -in "$CERT_DIR/ca/ca.crt" -noout -subject -dates

  log "Шаг 5. Конфиг сервера и CSR"
  build_san
  cat > "$CERT_DIR/vault.cnf" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt             = no

[ req_distinguished_name ]
C  = ${COUNTRY}
ST = ${STATE}
L  = ${CITY}
O  = ${ORG}
CN = ${FQDN}

[ req_ext ]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[ alt_names ]
${SAN_LINES}
EOF

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CERT_DIR/vault.key"
  chmod 600 "$CERT_DIR/vault.key"
  openssl req -new -key "$CERT_DIR/vault.key" -config "$CERT_DIR/vault.cnf" -out "$CERT_DIR/vault.csr"
  openssl req -in "$CERT_DIR/vault.csr" -noout -subject -verify

  log "Шаг 6. Подпись сертификата сервера"
  cat > "$CERT_DIR/vault-sign.cnf" <<EOF
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ alt_names ]
${SAN_LINES}
EOF

  openssl x509 -req -in "$CERT_DIR/vault.csr" \
    -CA "$CERT_DIR/ca/ca.crt" -CAkey "$CERT_DIR/ca/ca.key" \
    -CAcreateserial -out "$CERT_DIR/vault.crt" -days "$SERVER_DAYS" \
    -extfile "$CERT_DIR/vault-sign.cnf"

  cat "$CERT_DIR/vault.crt" "$CERT_DIR/ca/ca.crt" > "$CERT_DIR/vault-fullchain.crt"
  openssl verify -CAfile "$CERT_DIR/ca/ca.crt" "$CERT_DIR/vault.crt"
  openssl x509 -in "$CERT_DIR/vault.crt" -noout -subject -issuer -dates -ext subjectAltName
}

mode_selfsigned() {
  log "Альтернатива. Короткий self-signed (без CA)"
  build_san
  cat > "$CERT_DIR/vault.cnf" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt             = no

[ req_distinguished_name ]
C  = ${COUNTRY}
ST = ${STATE}
L  = ${CITY}
O  = ${ORG}
CN = ${FQDN}

[ req_ext ]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[ alt_names ]
${SAN_LINES}
EOF

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CERT_DIR/vault.key"
  chmod 600 "$CERT_DIR/vault.key"
  openssl req -new -x509 -days "$SERVER_DAYS" -key "$CERT_DIR/vault.key" \
    -config "$CERT_DIR/vault.cnf" -extensions req_ext -out "$CERT_DIR/vault.crt"
  cp "$CERT_DIR/vault.crt" "$CERT_DIR/vault-fullchain.crt"
  openssl x509 -in "$CERT_DIR/vault.crt" -noout -subject -dates -ext subjectAltName
}

step_install() {
  log "Шаг 7. Установка в /etc/ssl"
  mkdir -p /etc/ssl/certs /etc/ssl/private
  cp "$CERT_DIR/vault-fullchain.crt" /etc/ssl/certs/vault.crt
  cp "$CERT_DIR/vault.key" /etc/ssl/private/vault.key
  chmod 644 /etc/ssl/certs/vault.crt
  chmod 600 /etc/ssl/private/vault.key
  chown root:root /etc/ssl/private/vault.key

  if [[ "$FOR_VAULT_USER" -eq 1 ]]; then
    if getent group vault >/dev/null 2>&1; then
      chown root:vault /etc/ssl/private/vault.key
      chmod 640 /etc/ssl/private/vault.key
      log " права ключа: root:vault 640 (вариант C)"
    else
      log " группа vault не найдена — оставляю root:root 600; после useradd vault повторите chown"
    fi
  fi

  ls -l /etc/ssl/certs/vault.crt /etc/ssl/private/vault.key
  openssl x509 -in /etc/ssl/certs/vault.crt -noout -subject -issuer -dates
}

step_trust() {
  log "Шаг 8. Доверие в системе"
  mkdir -p /etc/pki/ca-trust/source/anchors
  if [[ "$MODE" == "ca" ]]; then
    cp "$CERT_DIR/ca/ca.crt" /etc/pki/ca-trust/source/anchors/vault-ca.crt
  else
    cp "$CERT_DIR/vault.crt" /etc/pki/ca-trust/source/anchors/vault.crt
  fi
  if command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust extract
  else
    log " update-ca-trust не найден — добавьте CA вручную"
  fi
}

fix_ownership() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "$CERT_DIR" || true
  fi
}

print_summary() {
  cat <<EOF

Готово.
  Каталог:     ${CERT_DIR}
  Режим:       ${MODE}
  FQDN:        ${FQDN}
  IP:          ${IP:-<не задан>}
  Сертификат:  /etc/ssl/certs/vault.crt $([ "$INSTALL" -eq 1 ] && echo '(установлен)' || echo '(не устанавливался)')
  Ключ:        /etc/ssl/private/vault.key

Дальше (шаг 9 инструкции):
  - Вариант B: nginx :443 → см. docs/vault-redos-web.md
  - Вариант C: Vault listener :443 → добавьте --for-vault-user при установке

CLI после HTTPS:
  export VAULT_ADDR='https://${FQDN}'
  vault status
EOF
}

main() {
  step_install_openssl
  step_params_and_hosts
  prepare_dir
  if [[ "$MODE" == "ca" ]]; then
    mode_ca
  else
    mode_selfsigned
  fi
  if [[ "$INSTALL" -eq 1 ]]; then
    step_install
  else
    log "Шаг 7 пропущен (--no-install)"
  fi
  if [[ "$TRUST" -eq 1 ]]; then
    step_trust
  else
    log "Шаг 8 пропущен (--no-trust)"
  fi
  fix_ownership
  print_summary
}

main
