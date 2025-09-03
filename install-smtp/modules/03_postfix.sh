# modules/03_postfix.sh — базовая конфигурация Postfix
# Требует: DOMAIN, HOSTNAME, IPV4; функции: run_cmd, log_*, require_cmd
# Опирается на Dovecot (SASL/LMTP) в следующих модулях.
# shellcheck shell=bash

postfix::paths() {
  PF_MAIN="/etc/postfix/main.cf"
  PF_MAIN_BAK="/etc/postfix/main.cf.msa-bak"
  LE_FULL="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
  LE_KEY="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"
}

postfix::write_main_cf() {
  postfix::paths
  require_cmd postconf

  # Бэкап один раз
  if [[ ! -f "${PF_MAIN_BAK}" && -f "${PF_MAIN}" ]]; then
    run_cmd "cp -a '${PF_MAIN}' '${PF_MAIN_BAK}'"
  fi

  # Генерируем минимальный opinionated main.cf
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by msa-install — DO NOT EDIT
compatibility_level = 3.6

myhostname = ${HOSTNAME}
mydomain = ${DOMAIN}
smtp_helo_name = \$myhostname

# Не быть open relay
mynetworks = 127.0.0.0/8
mydestination = localhost
relay_domains =
smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination
smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination

# IPv4 only (исходящий и входящий)
inet_protocols = ipv4
smtp_address_preference = ipv4

# Доставка в Dovecot через LMTP; список ящиков проверит Dovecot
virtual_mailbox_domains = ${DOMAIN}
virtual_transport = lmtp:unix:private/dovecot-lmtp

# SASL через Dovecot (AUTH на submission/SMTPS)
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain =
broken_sasl_auth_clients = yes

# TLS политика
smtpd_tls_auth_only = yes
smtpd_tls_security_level = may
smtp_tls_security_level = may
smtpd_tls_protocols = !SSLv2, !SSLv3
smtp_tls_protocols = !SSLv2, !SSLv3
tls_preempt_cipherlist = yes

# Если есть сертификат — укажем глобально, иначе пропустим (submission/SMTPS включим только при наличии LE)
EOF

  if [[ -r "${LE_FULL}" && -r "${LE_KEY}" ]]; then
    cat >> "$tmp" <<EOF
smtpd_tls_cert_file = ${LE_FULL}
smtpd_tls_key_file  = ${LE_KEY}
EOF
  fi

  # Доп. гигиена
  cat >> "$tmp" <<'EOF'
disable_vrfy_command = yes
strict_rfc821_envelopes = yes
smtputf8_enable = no
EOF

  # Атомарная установка конфига
  run_cmd "install -m 0644 '${tmp}' '${PF_MAIN}'"
  rm -f "$tmp"
}

postfix::enable_tls_services() {
  postfix::paths
  # Включаем 587/465 только если есть сертификат
  if [[ ! ( -r "${LE_FULL}" && -r "${LE_KEY}" ) ]]; then
    log_warn "Postfix: LE-сертификат отсутствует — пропускаю активацию 587/465"
    return 0
  fi

  log_info "Postfix: настраиваю сервисы submission (587) и smtps (465)"
  # Создаём/обновляем сервисы через postconf -M / -P (идемпотентно, без правки master.cf руками)
  run_cmd "postconf -M submission/inet='submission inet n - y - - smtpd'"
  run_cmd "postconf -P 'submission/inet/smtpd_tls_security_level=encrypt'"
  run_cmd "postconf -P 'submission/inet/smtpd_sasl_auth_enable=yes'"
  run_cmd "postconf -P 'submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject'"
  run_cmd "postconf -P 'submission/inet/smtpd_tls_cert_file=${LE_FULL}'"
  run_cmd "postconf -P 'submission/inet/smtpd_tls_key_file=${LE_KEY}'"

  run_cmd "postconf -M smtps/inet='smtps inet n - y - - smtpd'"
  run_cmd "postconf -P 'smtps/inet/smtpd_tls_wrappermode=yes'"
  run_cmd "postconf -P 'smtps/inet/smtpd_sasl_auth_enable=yes'"
  run_cmd "postconf -P 'smtps/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject'"
  run_cmd "postconf -P 'smtps/inet/smtpd_tls_cert_file=${LE_FULL}'"
  run_cmd "postconf -P 'smtps/inet/smtpd_tls_key_file=${LE_KEY}'"
}

postfix::reload_enable() {
  run_cmd "postfix check"
  run_cmd "systemctl enable --now postfix"
  run_cmd "systemctl reload postfix || systemctl restart postfix"
}

# Хук для модуля SSL (можно вызвать после получения сертификата)
postfix::ensure_tls_after_le() {
  postfix::enable_tls_services
  postfix::reload_enable
}

# --- ENTRYPOINT ---
postfix::write_main_cf
postfix::enable_tls_services
postfix::reload_enable
