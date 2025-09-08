#!/usr/bin/env bash
# Выпуск LE + подключение к Dovecot/Postfix без ломания master.cf
# Требует: DOMAIN, HOSTNAME; run_cmd, log_info/log_warn

set -Eeuo pipefail
: "${DOMAIN:?}" ; : "${HOSTNAME:?}"

ssl::paths() {
  LE_DIR="/etc/letsencrypt/live/${HOSTNAME}"
  LE_FULL="${LE_DIR}/fullchain.pem"
  LE_KEY="${LE_DIR}/privkey.pem"
}

ssl::obtain() {
  ssl::paths
  if [[ -r "${LE_FULL}" && -r "${LE_KEY}" ]]; then
    log_info "LE: сертификат для ${HOSTNAME} уже есть — пропуск выпуска"
    return 0
  fi
  log_info "LE: запрашиваю сертификат для ${HOSTNAME}"
  run_cmd certbot certonly --standalone --preferred-challenges http \
    --non-interactive --agree-tos --no-eff-email -m "info@${DOMAIN}" -d "${HOSTNAME}"

  run_cmd install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  run_cmd install -m 0755 /dev/stdin /etc/letsencrypt/renewal-hooks/deploy/99-reload-mail-services.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload postfix || systemctl restart postfix
systemctl reload dovecot || systemctl restart dovecot
EOF
}

ssl::enable_dovecot() {
  ssl::paths
  if [[ ! ( -r "${LE_FULL}" && -r "${LE_KEY}" ) ]]; then
    log_warn "Dovecot: LE-сертификата нет — запущу позже"
    return 0
  fi
  log_info "Dovecot: включаю TLS"
  run_cmd install -D -m 0644 /dev/stdin /etc/dovecot/conf.d/90-msa.conf <<EOF
ssl = required
ssl_cert = <${LE_FULL}
ssl_key  = <${LE_KEY}
ssl_client_ca_dir = /etc/ssl/certs
ssl_prefer_server_ciphers = yes
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
EOF
  run_cmd systemctl enable --now dovecot
  run_cmd bash -c "dovecot -n"
  run_cmd bash -c "systemctl reload dovecot || systemctl restart dovecot"
}

ssl::enable_postfix_tls() {
  ssl::paths
  if [[ ! ( -r "${LE_FULL}" && -r "${LE_KEY}" ) ]]; then
    log_warn "Postfix: LE-сертификата нет — пропускаю настройку TLS"
    return 0
  fi
  # глобальные ключи для smtpd
  run_cmd postconf -e \
    "smtpd_tls_cert_file=${LE_FULL}" \
    "smtpd_tls_key_file=${LE_KEY}"

  # убедимся, что 587/465 включены (без chroot) и знают путь к ключам
  run_cmd postconf -M "submission/inet=submission inet n - n - - smtpd"
  run_cmd postconf -P "submission/inet/smtpd_tls_security_level=encrypt"
  run_cmd postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
  run_cmd postconf -P "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
  run_cmd postconf -P "submission/inet/smtpd_tls_cert_file=${LE_FULL}"
  run_cmd postconf -P "submission/inet/smtpd_tls_key_file=${LE_KEY}"

  run_cmd postconf -M "smtps/inet=smtps inet n - n - - smtpd"
  run_cmd postconf -P "smtps/inet/smtpd_tls_wrappermode=yes"
  run_cmd postconf -P "smtps/inet/smtpd_sasl_auth_enable=yes"
  run_cmd postconf -P "smtps/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
  run_cmd postconf -P "smtps/inet/smtpd_tls_cert_file=${LE_FULL}"
  run_cmd postconf -P "smtps/inet/smtpd_tls_key_file=${LE_KEY}"

  run_cmd postfix check
  run_cmd bash -c "systemctl reload postfix || systemctl restart postfix"
}

# ---------- ENTRYPOINT ----------
ssl::obtain
ssl::enable_dovecot
ssl::enable_postfix_tls
