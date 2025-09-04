#!/usr/bin/env bash
# modules/06_ssl.sh — выпуск LE-сертификата + хуки обновления + финализация Dovecot и Postfix (587/465)
set -Eeuo pipefail
IFS=$'\n\t'

ssl::le_paths() {
  LE_DIR="/etc/letsencrypt/live/${HOSTNAME}"
  LE_FULL="${LE_DIR}/fullchain.pem"
  LE_KEY="${LE_DIR}/privkey.pem"
}

ssl::obtain_cert() {
  ssl::le_paths
  if [[ -r "${LE_FULL}" && -r "${LE_KEY}" ]]; then
    log_info "LE: сертификат для ${HOSTNAME} уже существует — пропускаю выпуск"
    return 0
  fi

  local email="${ACME_EMAIL:-postmaster@${DOMAIN}}"
  log_info "LE: запрашиваю сертификат для ${HOSTNAME}"
  run_cmd certbot certonly --standalone \
    --preferred-challenges http \
    --non-interactive --agree-tos --no-eff-email \
    -m "${email}" -d "${HOSTNAME}"
}

ssl::setup_renew_hooks() {
  ssl::le_paths
  local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
  local hook="${hook_dir}/99-reload-mail-services.sh"

  log_info "LE: настраиваю deploy-hook для перезагрузки Postfix/Dovecot"
  local tmp_hook; tmp_hook="$(mktemp)"
  cat > "${tmp_hook}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl reload postfix 2>/dev/null || systemctl restart postfix || true
systemctl reload dovecot  2>/dev/null || systemctl restart dovecot  || true
EOF
  run_cmd install -d -m 0755 "${hook_dir}"
  run_cmd install -m 0755 "${tmp_hook}" "${hook}"
  rm -f "${tmp_hook}"
}

ssl::finalize_dovecot() {
  ssl::le_paths
  if [[ ! ( -r "${LE_FULL}" && -r "${LE_KEY}" ) ]]; then
    log_warn "Dovecot: нет LE-сертификата — пропускаю финализацию"
    return 0
  fi

  log_info "Dovecot: обнаружен LE-сертификат — включаю TLS и запускаю сервисы"
  local conf="/etc/dovecot/conf.d/90-msa.conf" tmp; tmp="$(mktemp)"
  cat > "${tmp}" <<EOF
ssl = required
ssl_cert = <${LE_FULL}
ssl_key  = <${LE_KEY}
ssl_client_ca_dir = /etc/ssl/certs
ssl_prefer_server_ciphers = yes
# Минимальная версия TLS
ssl_min_protocol = TLSv1.2

protocols = imap pop3 lmtp
mail_location = maildir:/var/vmail/%d/%n/Maildir
first_valid_uid = 100
first_valid_gid = 100
mail_privileged_group = mail

passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/passdb/users
}
userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/vmail/%d/%n
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
EOF
  run_cmd install -D -m 0644 "${tmp}" "${conf}"
  rm -f "${tmp}"

  run_cmd systemctl enable --now dovecot
  run_cmd bash -c 'dovecot -n'
  run_cmd bash -c 'systemctl reload dovecot || systemctl restart dovecot'
}

# NEW: после появления сертификата сразу включаем submission/smtps в Postfix
ssl::finalize_postfix_ports() {
  ssl::le_paths
  if [[ ! ( -r "${LE_FULL}" && -r "${LE_KEY}" ) ]]; then
    log_warn "Postfix: LE-сертификат отсутствует — пропускаю активацию 587/465"
    return 0
  fi

  log_info "Postfix: настраиваю сервисы submission (587) и smtps (465)"
  # submission (587) — STARTTLS обязателен, AUTH включён
  run_cmd postconf -M "submission/inet= submission inet n - y - - smtpd"
  run_cmd postconf -P "submission/inet/smtpd_tls_security_level=encrypt"
  run_cmd postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
  run_cmd postconf -P "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
  run_cmd postconf -P "submission/inet/smtpd_tls_cert_file=${LE_FULL}"
  run_cmd postconf -P "submission/inet/smtpd_tls_key_file=${LE_KEY}"

  # smtps (465) — wrapper TLS, AUTH включён
  run_cmd postconf -M "smtps/inet= smtps inet n - y - - smtpd"
  run_cmd postconf -P "smtps/inet/smtpd_tls_wrappermode=yes"
  run_cmd postconf -P "smtps/inet/smtpd_sasl_auth_enable=yes"
  run_cmd postconf -P "smtps/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
  run_cmd postconf -P "smtps/inet/smtpd_tls_cert_file=${LE_FULL}"
  run_cmd postconf -P "smtps/inet/smtpd_tls_key_file=${LE_KEY}"

  run_cmd postfix check
  run_cmd bash -c 'systemctl reload postfix || systemctl restart postfix'
}

ssl::print_cert_window() {
  ssl::le_paths
  if [[ -r "${LE_FULL}" ]]; then
    local not_before not_after
    not_before="$(openssl x509 -in "${LE_FULL}" -noout -startdate 2>/dev/null | sed 's/notBefore=//')"
    not_after="$(openssl x509 -in "${LE_FULL}" -noout -enddate   2>/dev/null | sed 's/notAfter=//')"
    log_info "LE: сертификат ${HOSTNAME} валиден с ${not_before} по ${not_after}"
  fi
}

# --- ENTRYPOINT ---
ssl::obtain_cert
ssl::setup_renew_hooks
ssl::print_cert_window
ssl::finalize_dovecot
ssl::finalize_postfix_ports
