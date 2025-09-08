#!/usr/bin/env bash
# Выпуск LE + подключение к Dovecot/Postfix, с обязательной проверкой A-записей.
# Требует: DOMAIN, HOSTNAME; run_cmd, log_info/log_warn

set -Eeuo pipefail
IFS=$'\n\t'

: "${DOMAIN:?}"
: "${HOSTNAME:?}"
: "${IPV4:?}"

ssl::_auth_ns() { echo ns1.beget.com ns2.beget.com ns1.beget.ru ns2.beget.ru ns1.beget.pro ns2.beget.pro; }

ssl::wait_a() { # fqdn ip [timeout_sec]
  local fqdn="$1" ip="$2" timeout="${3:-180}" t=0 ok=0

  # сначала авторитативы Beget
  while (( t < timeout )); do
    for ns in $(ssl::_auth_ns); do
      if dig +short A "$fqdn" @"$ns" | grep -Fxq "$ip"; then ok=1; break; fi
    done
    (( ok )) && break
    sleep 5; t=$((t+5))
  done

  # затем публичный резолвер (8.8.8.8) — чтобы удостовериться, что кэш догнался
  if (( ok )); then
    t=0; ok=0
    while (( t < timeout )); do
      if dig +short A "$fqdn" @8.8.8.8 | grep -Fxq "$ip"; then ok=1; break; fi
      sleep 5; t=$((t+5))
    done
  fi

  (( ok )) || return 1
  return 0
}

ssl::paths() {
  LE_DIR="/etc/letsencrypt/live/${HOSTNAME}"
  LE_FULL="${LE_DIR}/fullchain.pem"
  LE_KEY="${LE_DIR}/privkey.pem"
}

ssl::obtain() {
  ssl::paths

  # 1) Убедимся, что A(hostname) уже на месте — иначе standalone-challenge не пройдёт.
  log_info "LE: жду A ${HOSTNAME} -> ${IPV4} перед выпуском сертификата…"
  if ssl::wait_a "${HOSTNAME}" "${IPV4}" 300; then
    log_info "LE: подтверждено ${HOSTNAME} -> ${IPV4}"
  else
    log_warn "LE: не дождался ${HOSTNAME} -> ${IPV4}. Попробую всё равно (вдруг кэш локального резолвера уже знает)."
  fi

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

  # 587/465 без chroot, с теми же ключами (дублирую для наглядности)
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
