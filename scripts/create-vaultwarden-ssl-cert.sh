#!/usr/bin/env bash
# Создание и установка SSL для Vaultwarden (РЕД ОС).
# Результат: /opt/vaultwarden/ssl/fullchain.pem + privkey.pem
#
# Пример:
#   sudo ./scripts/create-vaultwarden-ssl-cert.sh --fqdn vault.example.local --ip 192.168.1.50

set -euo pipefail

MODE="ca"
FQDN=""
IP=""
CERT_DIR="${HOME}/vaultwarden-certs"
INSTALL_DIR="/opt/vaultwarden/ssl"
INSTALL=1
TRUST=1
UPDATE_HOSTS=1
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
  create-vaultwarden-ssl-cert.sh --fqdn <имя> [--ip <IP>] [опции]

  --fqdn NAME              DNS-имя (CN / SAN)
  --ip ADDR                IP в SAN и /etc/hosts
  --mode ca|selfsigned     своя CA (по умолчанию) или короткий self-signed
  --dir PATH               рабочие файлы (по умолчанию ~/vaultwarden-certs)
  --install-dir PATH       куда класть pem (по умолчанию /opt/vaultwarden/ssl)
  --org NAME               организация в DN
  --no-install             не копировать в install-dir
  --no-trust               не добавлять в системное доверие
  --no-hosts               не трогать /etc/hosts
  --force                  перезаписать ключи в --dir
  -h, --help
EOF
}

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "нет команды: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fqdn) FQDN="${2:-}"; shift 2 ;;
    --ip) IP="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --dir) CERT_DIR="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --org) ORG="${2:-}"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    --no-trust) TRUST=0; shift ;;
    --no-hosts) UPDATE_HOSTS=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[[ -n "$FQDN" ]] || die "укажите --fqdn"
[[ "$MODE" == "ca" || "$MODE" == "selfsigned" ]] || die "--mode: ca|selfsigned"

if [[ "$INSTALL" -eq 1 || "$TRUST" -eq 1 || "$UPDATE_HOSTS" -eq 1 ]]; then
  [[ "${EUID}" -eq 0 ]] || die "нужен sudo (или --no-install --no-trust --no-hosts)"
fi

if [[ -n "${SUDO_USER:-}" && "$CERT_DIR" == "/root/vaultwarden-certs" ]]; then
  CERT_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/vaultwarden-certs"
fi
CERT_DIR="${CERT_DIR/#\~/$HOME}"

build_san() {
  SAN_LINES="DNS.1 = ${FQDN}
DNS.2 = localhost
IP.1  = 127.0.0.1"
  [[ -n "$IP" ]] && SAN_LINES="${SAN_LINES}
IP.2  = ${IP}"
}

if ! command -v openssl >/dev/null 2>&1; then
  command -v dnf >/dev/null && dnf install -y openssl || yum install -y openssl
fi
need openssl
log "OpenSSL: $(openssl version)"

if [[ "$UPDATE_HOSTS" -eq 1 && -n "$IP" ]]; then
  if ! grep -qE "[[:space:]]${FQDN}([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
    echo "${IP} ${FQDN}" >> /etc/hosts
    log "добавлено в /etc/hosts: ${IP} ${FQDN}"
  fi
fi

if [[ -d "$CERT_DIR" && "$FORCE" -ne 1 && ( -e "$CERT_DIR/privkey.pem" || -e "$CERT_DIR/ca/ca.key" ) ]]; then
  die "в ${CERT_DIR} уже есть ключи — укажите --force"
fi
mkdir -p "$CERT_DIR/ca"
chmod 700 "$CERT_DIR"

if [[ "$MODE" == "ca" ]]; then
  log "Создание CA + сертификата сервера"
  cat > "$CERT_DIR/ca/ca.cnf" <<EOF
[ req ]
default_bits = 4096
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no
[ req_distinguished_name ]
C = ${COUNTRY}
ST = ${STATE}
L = ${CITY}
O = ${ORG} Vaultwarden CA
CN = ${ORG} Vaultwarden Root CA
[ v3_ca ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$CERT_DIR/ca/ca.key"
  chmod 600 "$CERT_DIR/ca/ca.key"
  openssl req -new -x509 -days "$CA_DAYS" -key "$CERT_DIR/ca/ca.key" \
    -config "$CERT_DIR/ca/ca.cnf" -out "$CERT_DIR/ca/ca.crt"

  build_san
  cat > "$CERT_DIR/server.cnf" <<EOF
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = req_ext
prompt = no
[ req_distinguished_name ]
C = ${COUNTRY}
ST = ${STATE}
L = ${CITY}
O = ${ORG}
CN = ${FQDN}
[ req_ext ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[ alt_names ]
${SAN_LINES}
EOF
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CERT_DIR/privkey.pem"
  chmod 600 "$CERT_DIR/privkey.pem"
  openssl req -new -key "$CERT_DIR/privkey.pem" -config "$CERT_DIR/server.cnf" -out "$CERT_DIR/server.csr"

  cat > "$CERT_DIR/sign.cnf" <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
[ alt_names ]
${SAN_LINES}
EOF
  openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca/ca.crt" -CAkey "$CERT_DIR/ca/ca.key" \
    -CAcreateserial -out "$CERT_DIR/server.crt" -days "$SERVER_DAYS" -extfile "$CERT_DIR/sign.cnf"
  cat "$CERT_DIR/server.crt" "$CERT_DIR/ca/ca.crt" > "$CERT_DIR/fullchain.pem"
  openssl verify -CAfile "$CERT_DIR/ca/ca.crt" "$CERT_DIR/server.crt"
else
  log "Короткий self-signed"
  build_san
  cat > "$CERT_DIR/server.cnf" <<EOF
[ req ]
default_bits = 2048
distinguished_name = req_distinguished_name
req_extensions = req_ext
prompt = no
[ req_distinguished_name ]
C = ${COUNTRY}
ST = ${STATE}
L = ${CITY}
O = ${ORG}
CN = ${FQDN}
[ req_ext ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[ alt_names ]
${SAN_LINES}
EOF
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CERT_DIR/privkey.pem"
  chmod 600 "$CERT_DIR/privkey.pem"
  openssl req -new -x509 -days "$SERVER_DAYS" -key "$CERT_DIR/privkey.pem" \
    -config "$CERT_DIR/server.cnf" -extensions req_ext -out "$CERT_DIR/fullchain.pem"
fi

openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject -dates -ext subjectAltName || true

if [[ "$INSTALL" -eq 1 ]]; then
  log "Установка в ${INSTALL_DIR}"
  mkdir -p "$INSTALL_DIR"
  cp "$CERT_DIR/fullchain.pem" "$INSTALL_DIR/fullchain.pem"
  cp "$CERT_DIR/privkey.pem" "$INSTALL_DIR/privkey.pem"
  chmod 644 "$INSTALL_DIR/fullchain.pem"
  chmod 600 "$INSTALL_DIR/privkey.pem"
  ls -l "$INSTALL_DIR/fullchain.pem" "$INSTALL_DIR/privkey.pem"
fi

if [[ "$TRUST" -eq 1 ]]; then
  mkdir -p /etc/pki/ca-trust/source/anchors
  if [[ "$MODE" == "ca" ]]; then
    cp "$CERT_DIR/ca/ca.crt" /etc/pki/ca-trust/source/anchors/vaultwarden-ca.crt
  else
    cp "$CERT_DIR/fullchain.pem" /etc/pki/ca-trust/source/anchors/vaultwarden.crt
  fi
  command -v update-ca-trust >/dev/null && update-ca-trust extract || log "update-ca-trust нет"
fi

[[ -n "${SUDO_USER:-}" ]] && chown -R "${SUDO_USER}:${SUDO_USER}" "$CERT_DIR" || true

cat <<EOF

Готово.
  Рабочие файлы: ${CERT_DIR}
  fullchain:     ${INSTALL_DIR}/fullchain.pem
  privkey:       ${INSTALL_DIR}/privkey.pem
  FQDN/IP:       ${FQDN} / ${IP:-<нет>}
EOF
