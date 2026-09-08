#!/usr/bin/env bash
# Полная установка HashiCorp Vault на РЕД ОС 8:
#   пакеты → каталоги/systemd → SSL → nginx → firewall → запуск → init/unseal
#
# Соответствует docs/vault-redos-web.md (боевой режим + вариант A или B).
#
# Пример (HTTPS + init/unseal сразу, рекомендуется):
#   sudo ./scripts/install-vault-redos.sh --fqdn vault.example.local --ip 192.168.1.50
#
# HTTP без TLS (только LAN):
#   sudo ./scripts/install-vault-redos.sh --fqdn vault.example.local --ip 192.168.1.50 --access http
#
# Без автоматического init:
#   sudo ./scripts/install-vault-redos.sh --fqdn vault.example.local --ip 192.168.1.50 --no-init

set -euo pipefail

FQDN=""
IP=""
ACCESS="https"          # https | http | direct-https
CERT_MODE="ca"          # ca | selfsigned
DO_INIT=1               # по умолчанию: init + unseal сразу
FORCE=0
ORG="MyOrg"
KEY_SHARES=5
KEY_THRESHOLD=3
INIT_FILE="/root/vault-init-KEYS.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_SCRIPT="${SCRIPT_DIR}/create-vault-ssl-cert.sh"
CERT_FILE=""
KEY_FILE=""
CHAIN_FILE=""

usage() {
  cat <<'EOF'
Использование:
  sudo ./scripts/install-vault-redos.sh --fqdn <имя> [--ip <IP>] [опции]

Обязательно:
  --fqdn NAME                 DNS-имя Vault (для UI и сертификата)

Рекомендуется:
  --ip ADDR                   IP сервера (SAN + /etc/hosts)

Опции:
  --access https|http|direct-https
                              https         = nginx :443 + TLS (по умолчанию, вариант B)
                              http          = nginx :80 без TLS (вариант A, только LAN)
                              direct-https  = Vault сам на :443 (вариант C)
  --cert-mode ca|selfsigned   самоподписанный cert (если нет своих файлов)
  --cert-file PATH            готовый сертификат/fullchain от УЦ
  --key-file PATH             готовый ключ от УЦ
  --chain-file PATH           CA-bundle (если cert без цепочки)
  --org NAME                  организация в DN сертификата
  --init                      init + unseal сразу (по умолчанию ВКЛЮЧЕНО)
  --no-init                   не делать vault operator init / unseal
  --init-file PATH            куда писать unseal/root (по умолчанию /root/vault-init-KEYS.txt)
  --force                     перезаписать конфиги и сертификаты
  -h, --help                  справка

Свои сертификаты от УЦ:
  sudo ./scripts/install-vault-redos.sh --fqdn vault.company.ru --ip 192.168.1.50 \
    --cert-file /path/server.crt --key-file /path/server.key \
    --chain-file /path/ca-bundle.crt

Только положить готовые cert для Vault:
  sudo ./scripts/install-vault-existing-ssl-cert.sh \
    --cert /path/server.crt --key /path/server.key --chain /path/ca-bundle.crt \
    --force --restart
EOF
}

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    OK: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "запустите через sudo"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fqdn) FQDN="${2:-}"; shift 2 ;;
    --ip) IP="${2:-}"; shift 2 ;;
    --access) ACCESS="${2:-}"; shift 2 ;;
    --cert-mode) CERT_MODE="${2:-}"; shift 2 ;;
    --cert-file) CERT_FILE="${2:-}"; shift 2 ;;
    --key-file) KEY_FILE="${2:-}"; shift 2 ;;
    --chain-file) CHAIN_FILE="${2:-}"; shift 2 ;;
    --org) ORG="${2:-}"; shift 2 ;;
    --init) DO_INIT=1; shift ;;
    --no-init) DO_INIT=0; shift ;;
    --init-file) INIT_FILE="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

[[ -n "$FQDN" ]] || die "укажите --fqdn"
case "$ACCESS" in https|http|direct-https) ;; *) die "--access: https|http|direct-https" ;; esac
case "$CERT_MODE" in ca|selfsigned) ;; *) die "--cert-mode: ca|selfsigned" ;; esac

pkg_install() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  else
    die "нужен dnf/yum (РЕД ОС / RHEL-подобные)"
  fi
}

ensure_packages() {
  log "1/8 Установка пакетов"
  local pkgs=(openssl)
  [[ "$ACCESS" != "direct-https" ]] && pkgs+=(nginx)
  command -v firewall-cmd >/dev/null 2>&1 || pkgs+=(firewalld)

  if ! command -v vault >/dev/null 2>&1; then
    pkgs+=(vault)
  fi

  pkg_install "${pkgs[@]}"

  if ! command -v vault >/dev/null 2>&1; then
    die "пакет vault не установился. На РЕД ОС: sudo dnf install -y vault (см. БЗ РЕД ОС)"
  fi
  vault --version
  ok "пакеты на месте"
}

ensure_user_dirs() {
  log "2/8 Пользователь и каталоги Vault"
  useradd --system --home /var/lib/vault --shell /sbin/nologin vault 2>/dev/null || true
  mkdir -p /etc/vault.d /var/lib/vault/data /var/log/vault
  chown -R vault:vault /etc/vault.d /var/lib/vault /var/log/vault
  chmod 750 /etc/vault.d /var/lib/vault /var/log/vault
  ok "/etc/vault.d, /var/lib/vault/data"
}

write_vault_hcl() {
  log "3/8 Конфиг /etc/vault.d/vault.hcl"
  local api_addr listener_block

  case "$ACCESS" in
    http)
      api_addr="http://${FQDN}"
      listener_block='listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}'
      ;;
    https)
      api_addr="https://${FQDN}"
      listener_block='listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}'
      ;;
    direct-https)
      api_addr="https://${FQDN}"
      listener_block='listener "tcp" {
  address       = "0.0.0.0:443"
  tls_cert_file = "/etc/ssl/certs/vault.crt"
  tls_key_file  = "/etc/ssl/private/vault.key"
}'
      ;;
  esac

  if [[ -f /etc/vault.d/vault.hcl && "$FORCE" -ne 1 ]]; then
    ok "vault.hcl уже есть (оставьте --force чтобы перезаписать)"
  else
    cat > /etc/vault.d/vault.hcl <<EOF
ui = true

storage "file" {
  path = "/var/lib/vault/data"
}

${listener_block}

api_addr      = "${api_addr}"
disable_mlock = false
EOF
    chown vault:vault /etc/vault.d/vault.hcl
    chmod 640 /etc/vault.d/vault.hcl
    ok "записан vault.hcl (api_addr=${api_addr})"
  fi
}

write_systemd_unit() {
  log "4/8 systemd unit vault.service"
  local caps="CAP_IPC_LOCK"
  local bound="CAP_SYSLOG CAP_IPC_LOCK"
  if [[ "$ACCESS" == "direct-https" ]]; then
    caps="CAP_IPC_LOCK CAP_NET_BIND_SERVICE"
    bound="CAP_SYSLOG CAP_IPC_LOCK CAP_NET_BIND_SERVICE"
  fi

  if [[ -f /etc/systemd/system/vault.service && "$FORCE" -ne 1 ]]; then
    # обновим capabilities при direct-https даже без --force, если unit наш
    if [[ "$ACCESS" == "direct-https" ]] && grep -q 'ExecStart=/usr/bin/vault' /etc/systemd/system/vault.service; then
      :
    else
      ok "unit уже есть"
      return
    fi
  fi

  cat > /etc/systemd/system/vault.service <<EOF
[Unit]
Description=HashiCorp Vault
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=${caps}
CapabilityBoundingSet=${bound}
NoNewPrivileges=yes
ExecStart=/usr/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "vault.service"
}

setup_certificates() {
  if [[ "$ACCESS" == "http" ]]; then
    log "5/8 Сертификаты пропущены (--access http)"
    return
  fi
  log "5/8 SSL-сертификаты"

  if [[ -n "$CERT_FILE" || -n "$KEY_FILE" ]]; then
    [[ -n "$CERT_FILE" && -n "$KEY_FILE" ]] || die "нужны оба: --cert-file и --key-file"
    local existing="${SCRIPT_DIR}/install-vault-existing-ssl-cert.sh"
    [[ -x "$existing" ]] || die "нет ${existing}"
    local args=(--cert "$CERT_FILE" --key "$KEY_FILE")
    [[ -n "$CHAIN_FILE" ]] && args+=(--chain "$CHAIN_FILE")
    [[ "$FORCE" -eq 1 ]] && args+=(--force)
    [[ "$ACCESS" == "direct-https" ]] && args+=(--for-vault-user)
    "$existing" "${args[@]}"
    ok "установлены ваши сертификаты от УЦ (HashiCorp Vault)"
    return
  fi

  [[ -x "$CERT_SCRIPT" ]] || die "не найден ${CERT_SCRIPT}"

  local args=(--fqdn "$FQDN" --mode "$CERT_MODE" --org "$ORG")
  [[ -n "$IP" ]] && args+=(--ip "$IP")
  [[ "$FORCE" -eq 1 ]] && args+=(--force)
  [[ "$ACCESS" == "direct-https" ]] && args+=(--for-vault-user)

  "$CERT_SCRIPT" "${args[@]}"
  ok "сертификаты установлены"
}

disable_nginx_default() {
  # убрать конфликт default_server на :80
  local f
  for f in /etc/nginx/conf.d/default.conf /etc/nginx/nginx.conf; do
    [[ -f "$f" ]] || continue
  done
  if [[ -f /etc/nginx/conf.d/default.conf ]]; then
    mv -f /etc/nginx/conf.d/default.conf "/etc/nginx/conf.d/default.conf.bak.$(date +%s)" || true
  fi
  # в основном nginx.conf на РЕД ОС иногда есть server { listen 80 default_server }
  if [[ -f /etc/nginx/nginx.conf ]] && grep -q 'default_server' /etc/nginx/nginx.conf; then
    cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%s)"
    # комментируем строки listen ... default_server внутри server-блоков — мягко отключаем default
    sed -i 's/^\([[:space:]]*listen[[:space:]].*\)default_server\(.*\);/\1\2;  # default_server removed by install-vault-redos.sh/' \
      /etc/nginx/nginx.conf || true
  fi
}

setup_nginx() {
  if [[ "$ACCESS" == "direct-https" ]]; then
    log "6/8 nginx не нужен (--access direct-https)"
    systemctl disable --now nginx 2>/dev/null || true
    return
  fi

  log "6/8 nginx reverse proxy"
  disable_nginx_default

  if [[ "$ACCESS" == "http" ]]; then
    cat > /etc/nginx/conf.d/vault.conf <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${FQDN};

    client_max_body_size 16m;

    location / {
        proxy_pass http://127.0.0.1:8200;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
    }
}
EOF
  else
    cat > /etc/nginx/conf.d/vault.conf <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${FQDN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${FQDN};

    ssl_certificate     /etc/ssl/certs/vault.crt;
    ssl_certificate_key /etc/ssl/private/vault.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    client_max_body_size 16m;

    location / {
        proxy_pass http://127.0.0.1:8200;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
    }
}
EOF
  fi

  if command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    setsebool -P httpd_read_user_content 1 2>/dev/null || true
  fi

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
  ok "nginx настроен"
}

setup_firewall() {
  log "7/8 Firewall"
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    ok "firewalld нет — пропуск"
    return
  fi
  systemctl enable --now firewalld 2>/dev/null || true
  case "$ACCESS" in
    http)
      firewall-cmd --permanent --add-service=http || true
      ;;
    https|direct-https)
      firewall-cmd --permanent --add-service=http || true
      firewall-cmd --permanent --add-service=https || true
      ;;
  esac
  firewall-cmd --reload || true
  firewall-cmd --list-all || true
  ok "правила firewall"
}

start_vault() {
  log "8/8 Запуск Vault"
  systemctl enable vault
  systemctl restart vault
  sleep 2
  systemctl --no-pager --full status vault || true

  export VAULT_ADDR='http://127.0.0.1:8200'
  if [[ "$ACCESS" == "direct-https" ]]; then
    export VAULT_ADDR="https://${FQDN}"
    export VAULT_SKIP_VERIFY=1
  fi

  # ждём listener
  local i st
  for i in $(seq 1 30); do
    st="$(vault status 2>&1 || true)"
    if echo "$st" | grep -qiE 'Sealed|Initialized'; then
      break
    fi
    sleep 1
  done
  vault status || true
  ok "служба vault запущена"
}

maybe_init() {
  if [[ "$DO_INIT" -ne 1 ]]; then
    log "Init/unseal пропущен (--no-init)"
    return
  fi
  log "9/9 Инициализация и unseal Vault"
  export VAULT_ADDR='http://127.0.0.1:8200'
  if [[ "$ACCESS" == "direct-https" ]]; then
    export VAULT_ADDR="https://127.0.0.1:443"
    export VAULT_SKIP_VERIFY=1
  fi

  local st
  st="$(vault status 2>&1 || true)"
  if echo "$st" | grep -qi 'Initialized.*true'; then
    ok "уже инициализирован — init пропущен"
    # если sealed — попробуем unseal из сохранённого файла
    if echo "$st" | grep -qi 'Sealed.*true' && [[ -f "$INIT_FILE" ]]; then
      log "Vault sealed — unseal из ${INIT_FILE}"
      mapfile -t keys < <(grep -E '^Unseal Key' "$INIT_FILE" | awk '{print $NF}' | head -n "$KEY_THRESHOLD")
      local k
      for k in "${keys[@]}"; do
        vault operator unseal "$k" >/dev/null || true
      done
      vault status || true
    fi
    return
  fi

  umask 077
  vault operator init -key-shares="$KEY_SHARES" -key-threshold="$KEY_THRESHOLD" \
    | tee "$INIT_FILE"
  chmod 600 "$INIT_FILE"
  chown root:root "$INIT_FILE"

  # unseal первыми threshold ключами из файла
  mapfile -t keys < <(grep -E '^Unseal Key' "$INIT_FILE" | awk '{print $NF}' | head -n "$KEY_THRESHOLD")
  [[ "${#keys[@]}" -ge "$KEY_THRESHOLD" ]] || die "не удалось прочитать Unseal Keys из ${INIT_FILE}"
  local k
  for k in "${keys[@]}"; do
    vault operator unseal "$k" >/dev/null
  done
  vault status || true

  local root
  root="$(grep -E '^Initial Root Token:' "$INIT_FILE" | awk '{print $NF}' || true)"
  if [[ -n "$root" ]]; then
    vault login "$root" >/dev/null || true
  fi

  ok "ключи сохранены в ${INIT_FILE}"
  ok "Vault инициализирован и распечатан (Sealed: false)"
  printf '\nВнимание: файл %s содержит Unseal Keys и Root Token.\n' "$INIT_FILE"
  printf 'Скопируйте в сейф, затем удалите с диска: shred -u %s\n' "$INIT_FILE"
}

print_summary() {
  local url root
  case "$ACCESS" in
    http) url="http://${FQDN}" ;;
    *) url="https://${FQDN}" ;;
  esac
  root=""
  if [[ -f "$INIT_FILE" ]]; then
    root="$(grep -E '^Initial Root Token:' "$INIT_FILE" | awk '{print $NF}' || true)"
  fi

  cat <<EOF

========================================
  Установка завершена
========================================
  FQDN:     ${FQDN}
  IP:       ${IP:-<не задан>}
  Доступ:   ${ACCESS}
  UI:       ${url}
            ${url}/ui/
  CLI:      export VAULT_ADDR='${url}'
            # при self-signed без trust: export VAULT_SKIP_VERIFY=1
            vault status

EOF

  if [[ "$DO_INIT" -eq 1 && -f "$INIT_FILE" ]]; then
    cat <<EOF
  Ключи:    ${INIT_FILE}
            (Unseal Keys + Root Token, chmod 600)

  Вход в UI:
    1) откройте ${url}/ui/
    2) Method: Token
    3) Token:  ${root:-см. файл ключей}
    4) Sign in

  После reboot снова нужен unseal (3 ключа из файла):
    export VAULT_ADDR='http://127.0.0.1:8200'
    vault operator unseal   # ×3

EOF
  else
    cat <<EOF
  Init не выполнялся (--no-init). Сделайте вручную:
    export VAULT_ADDR='http://127.0.0.1:8200'
    vault operator init -key-shares=5 -key-threshold=3
    vault operator unseal   # ×3
    vault login <Initial_Root_Token>

EOF
  fi

  cat <<EOF
  Документация: docs/vault-redos-web.md
========================================
EOF
}

main() {
  need_root
  ensure_packages
  ensure_user_dirs
  # сертификаты до vault.hcl/direct — нужны пути ключей; для https — до nginx
  setup_certificates
  write_vault_hcl
  write_systemd_unit
  setup_nginx
  setup_firewall
  start_vault
  maybe_init
  print_summary
}

main
