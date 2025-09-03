# modules/06_ssl.sh — LE cert (standalone:80), deploy-hook, экспорт метаданных
# Требует: VARS_FILE, DOMAIN, HOSTNAME, DRY_RUN; функции: run_cmd, log_*, die, require_cmd
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

ssl::le_paths() {
  LE_DIR="/etc/letsencrypt/live/${HOSTNAME}"
  LE_FULLCHAIN="${LE_DIR}/fullchain.pem"
  LE_PRIVKEY="${LE_DIR}/privkey.pem"
}

ssl::get_acme_email() {
  local email
  email="$(yq -r ".acme_email // \"postmaster@${DOMAIN}\"" "${VARS_FILE}")"
  if ! grep -qiE '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' <<<"$email"; then
    die 3 "Некорректный acme_email: ${email}"
  fi
  printf '%s' "$email"
}

ssl::port80_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp | awk '($4 ~ /:80$/)' | grep -q .
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:80 -sTCP:LISTEN | grep -q .
  else
    log_warn "Не найдено ss/lsof — пропускаю проверку занятности порта 80"
    return 1
  fi
}

ssl::cert_valid_until_iso8601() {
  local pem="$1"; [[ -r "$pem" ]] || return 1
  local raw; raw="$(openssl x509 -enddate -noout -in "$pem" 2>/dev/null | sed -n 's/^notAfter=//p')" || return 1
  [[ -n "$raw" ]] || return 1
  date -u -d "$raw" +"%Y-%m-%dT%H:%M:%SZ"
}

ssl::cert_valid_from_iso8601() {
  local pem="$1"; [[ -r "$pem" ]] || return 1
  local raw; raw="$(openssl x509 -startdate -noout -in "$pem" 2>/dev/null | sed -n 's/^notBefore=//p')" || return 1
  [[ -n "$raw" ]] || return 1
  date -u -d "$raw" +"%Y-%m-%dT%H:%M:%SZ"
}

ssl::cert_valid_days_left() {
  local pem="$1"; [[ -r "$pem" ]] || { echo 0; return 0; }
  local raw exp now; raw="$(openssl x509 -enddate -noout -in "$pem" 2>/dev/null | sed -n 's/^notAfter=//p')"
  [[ -n "$raw" ]] || { echo 0; return 0; }
  exp="$(date -u -d "$raw" +%s)" || { echo 0; return 0; }
  now="$(date -u +%s)"; echo $(( (exp - now) / 86400 < 0 ? 0 : (exp - now) / 86400 ))
}

# проверка A-записи перед выпуском
if command -v dig >/dev/null 2>&1; then
  local arec
  arec="$(dig +short A "${HOSTNAME}" | head -n1)"
  if [[ -z "$arec" ]]; then
    die 3 "LE: A-запись для ${HOSTNAME} не найдена. Создайте 'A ${HOSTNAME} ${IPV4}' и дождитесь резолва."
  fi
  if [[ "$arec" != "${IPV4}" ]]; then
    die 3 "LE: ${HOSTNAME} A=${arec}, ожидается ${IPV4}. Исправьте DNS."
  fi
fi

ssl::request_le_cert() {
  ssl::le_paths
  require_cmd certbot; require_cmd openssl

  local email; email="$(ssl::get_acme_email)"
  local days_left; days_left="$(ssl::cert_valid_days_left "${LE_FULLCHAIN}")"

  if [[ -f "${LE_FULLCHAIN}" && -f "${LE_PRIVKEY}" && "$days_left" -gt 30 ]]; then
    log_info "LE: найден валидный сертификат для ${HOSTNAME} (ещё ${days_left} дн.) — выпуск не требуется"
    return 0
  fi

  if [[ "${DRY_RUN:-false}" != "true" ]] && ssl::port80_in_use; then
    die 3 "TCP/80 занят — останови веб-сервер на время выдачи сертификата (nginx/apache и т.п.)"
  fi

  log_info "LE: запрашиваю сертификат для ${HOSTNAME}"
  local em_q host_q
  em_q="$(printf '%q' "$email")"
  host_q="$(printf '%q' "$HOSTNAME")"

  run_cmd "certbot certonly --standalone \
    --preferred-challenges http \
    --non-interactive --agree-tos --no-eff-email \
    -m ${em_q} -d ${host_q}"

  run_cmd "systemctl enable --now certbot.timer" || true

  days_left="$(ssl::cert_valid_days_left "${LE_FULLCHAIN}")"
  if [[ "$days_left" -le 0 && "${DRY_RUN:-false}" != "true" ]]; then
    die 3 "LE: сертификат для ${HOSTNAME} не получен/невалиден"
  fi
}

ssl::setup_renew_hooks() {
  ssl::le_paths
  local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
  local hook="${hook_dir}/99-reload-mail-services.sh"

  log_info "LE: настраиваю deploy-hook для перезагрузки Postfix/Dovecot"
  local tmp_hook; tmp_hook="$(mktemp)"
  cat > "$tmp_hook" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active --quiet postfix && systemctl reload postfix || true
  systemctl is-active --quiet dovecot && systemctl reload dovecot || true
else
  service postfix reload 2>/dev/null || true
  service dovecot reload 2>/dev/null || true
fi
EOF
  run_cmd "install -d -m 0755 '${hook_dir}'"
  run_cmd "install -m 0755 '${tmp_hook}' '${hook}'"
  rm -f "$tmp_hook"
}

ssl::export_manifest_vars() {
  ssl::le_paths
  export LE_DOMAIN="${HOSTNAME}"
  if [[ -r "${LE_FULLCHAIN}" ]]; then
    if LE_VALID_UNTIL="$(ssl::cert_valid_until_iso8601 "${LE_FULLCHAIN}")"; then :; else LE_VALID_UNTIL=""; fi
    if LE_VALID_FROM="$(ssl::cert_valid_from_iso8601  "${LE_FULLCHAIN}")"; then :; else LE_VALID_FROM=""; fi
    export LE_VALID_UNTIL LE_VALID_FROM
    log_info "LE: сертификат ${HOSTNAME} валиден с ${LE_VALID_FROM:-?} по ${LE_VALID_UNTIL:-?}"
  else
    export LE_VALID_UNTIL=""; export LE_VALID_FROM=""
    log_warn "LE: сертификат для ${HOSTNAME} пока отсутствует"
  fi
}

# --- ENTRYPOINT ---
ssl::request_le_cert
ssl::setup_renew_hooks
ssl::export_manifest_vars

# Пост-хуки
if declare -F postfix::ensure_tls_after_le >/dev/null 2>&1; then
  log_info "LE: пост-хук — включаю TLS-сервисы Postfix (587/465)"
  postfix::ensure_tls_after_le
fi
if declare -F dovecot::ensure_after_le >/dev/null 2>&1; then
  log_info "LE: пост-хук — финализирую Dovecot (IMAPS/POPS/LMTP)"
  dovecot::ensure_after_le
fi
