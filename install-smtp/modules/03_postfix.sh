# modules/03_postfix.sh — базовая конфигурация Postfix с виртуальными ящиками
# Требует: DOMAIN, HOSTNAME, IPV4, VARS_FILE; функции: run_cmd, log_*, require_cmd
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

postfix::paths() {
  PF_MAIN="/etc/postfix/main.cf"
  PF_MAIN_BAK="/etc/postfix/main.cf.msa-bak"
  VMAP_PATH="/etc/postfix/virtual_mailbox_maps"
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

  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by msa-install — DO NOT EDIT
compatibility_level = 3.6

myhostname = ${HOSTNAME}
mydomain   = ${DOMAIN}
myorigin   = \$mydomain
smtp_helo_name = \$myhostname

# Не быть open relay
mynetworks = 127.0.0.0/8
mydestination = localhost
relay_domains =

# IPv4 only
inet_protocols = ipv4
smtp_address_preference = ipv4

# Виртуальные домены/ящики: доставка в Dovecot через LMTP
virtual_mailbox_domains = ${DOMAIN}
virtual_transport = lmtp:unix:private/dovecot-lmtp
virtual_mailbox_maps = hash:/etc/postfix/virtual_mailbox_maps

# SASL через Dovecot (AUTH на submission/SMTPS)
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain =
broken_sasl_auth_clients = yes

# TLS-политика
smtpd_tls_auth_only = yes
smtpd_tls_security_level = may
smtp_tls_security_level  = may
smtpd_tls_protocols = !SSLv2, !SSLv3
smtp_tls_protocols  = !SSLv2, !SSLv3
tls_preempt_cipherlist = yes
EOF

  if [[ -r "${LE_FULL}" && -r "${LE_KEY}" ]]; then
    cat >> "$tmp" <<EOF
smtpd_tls_cert_file = ${LE_FULL}
smtpd_tls_key_file  = ${LE_KEY}
EOF
  fi

  cat >> "$tmp" <<'EOF'
# Приёмная гигиена
smtpd_helo_required = yes
strict_rfc821_envelopes = yes
smtpd_sender_restrictions =
    reject_non_fqdn_sender,
    reject_unknown_sender_domain
smtpd_recipient_restrictions =
    reject_non_fqdn_recipient,
    reject_unknown_recipient_domain,
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination

disable_vrfy_command = yes
smtputf8_enable = no
EOF

  run_cmd "install -m 0644 '${tmp}' '${PF_MAIN}'"
  rm -f "$tmp"
}

postfix::virtual_maps_from_users() {
  postfix::paths
  local tmp; tmp="$(mktemp)"
  local count i login
  count="$(yq -r '(.users // []) | length' "${VARS_FILE}")"
  for (( i=0; i<count; i++ )); do
    login="$(yq -r ".users[${i}].login" "${VARS_FILE}")"
    [[ "$login" =~ @ ]] || continue
    printf '%s OK\n' "$login" >>"$tmp"
  done
  run_cmd "install -m 0644 '${tmp}' '${VMAP_PATH}'"
  run_cmd "postmap hash:'${VMAP_PATH}'"
  rm -f "$tmp"
}

postfix::enable_tls_services() {
  postfix::paths
  if [[ ! ( -r "${LE_FULL}" && -r "${LE_KEY}" ) ]]; then
    log_warn "Postfix: LE-сертификат отсутствует — пропускаю активацию 587/465"
    return 0
  fi

  log_info "Postfix: настраиваю сервисы submission (587) и smtps (465)"
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

postfix::ensure_tls_after_le() {
  postfix::enable_tls_services
  postfix::reload_enable
}

# --- ENTRYPOINT ---
postfix::write_main_cf
postfix::virtual_maps_from_users
postfix::enable_tls_services
postfix::reload_enable
