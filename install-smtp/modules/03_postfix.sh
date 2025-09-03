# modules/03_postfix.sh — Postfix (вирт. домены, LMTP, TLS, policy: IPv4 bind)
# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

postfix::paths() {
  PF_MAIN="/etc/postfix/main.cf"
  PF_MAIN_BAK="/etc/postfix/main.cf.msa-bak"
  PF_MASTER="/etc/postfix/master.cf"
  VMAP_PATH="/etc/postfix/virtual_mailbox_maps"
  VMAIL_BASE="/var/vmail"
  LE_FULL="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
  LE_KEY="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"
}

postfix::write_main_cf() {
  postfix::paths
  require_cmd postconf

  if [[ ! -f "${PF_MAIN_BAK}" && -f "${PF_MAIN}" ]]; then
    run_cmd cp -a "${PF_MAIN}" "${PF_MAIN_BAK}"
  fi

  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by msa-install — DO NOT EDIT
compatibility_level = 3.6

# Идентичность
myhostname = ${HOSTNAME}
mydomain   = ${DOMAIN}
myorigin   = \$mydomain
smtp_helo_name = \$myhostname

# Приём только своего, без open relay
mynetworks   = 127.0.0.0/8
mydestination = localhost
relay_domains =

# IPv4-only и привязка исходящих к конкретному IP
inet_protocols           = ipv4
smtp_address_preference  = ipv4
smtp_bind_address        = ${IPV4}

# Виртуальные домены и доставка в Dovecot через LMTP
virtual_mailbox_domains = ${DOMAIN}
virtual_mailbox_base    = ${VMAIL_BASE}
virtual_mailbox_maps    = hash:/etc/postfix/virtual_mailbox_maps
virtual_transport       = lmtp:unix:private/dovecot-lmtp

# SASL через Dovecot, AUTH строго по TLS
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain =
broken_sasl_auth_clients = yes

# TLS: запрещаем TLS1.0/1.1, оставляем 1.2/1.3; только сильные шифры
smtpd_tls_auth_only      = yes
smtpd_tls_security_level = may
smtp_tls_security_level  = may
smtpd_tls_protocols      = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_protocols       = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
tls_preempt_cipherlist   = yes
smtpd_tls_ciphers        = high
smtp_tls_ciphers         = high
smtpd_tls_mandatory_ciphers = high
tls_high_cipherlist = ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:\
ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:\
ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:\
DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
EOF

  if [[ -r "${LE_FULL}" && -r "${LE_KEY}" ]]; then
    cat >> "$tmp" <<EOF
smtpd_tls_cert_file = ${LE_FULL}
smtpd_tls_key_file  = ${LE_KEY}
EOF
  fi

  cat >> "$tmp" <<'EOF'
# Гигиена приёма
smtpd_helo_required       = yes
strict_rfc821_envelopes   = yes
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
smtputf8_enable      = no
EOF

  run_cmd install -m 0644 "$tmp" "$PF_MAIN"
  rm -f "$tmp"
}

postfix::virtual_maps_from_users() {
  postfix::paths
  require_cmd yq
  local tmp; tmp="$(mktemp)"
  local count i login
  count="$(yq -r '(.users // []) | length' "${VARS_FILE}")"
  for (( i=0; i<count; i++ )); do
    login="$(yq -r ".users[${i}].login" "${VARS_FILE}")"
    [[ "$login" =~ @ ]] || continue
    printf '%s OK\n' "$login" >>"$tmp"
  done
  run_cmd install -m 0644 "$tmp" "$VMAP_PATH"
  run_cmd postmap "hash:${VMAP_PATH}"
  rm -f "$tmp"
}

# Включить submission/smtps (587/465) после получения LE
postfix::enable_tls_services() {
  postfix::paths
  if [[ ! ( -r "${LE_FULL}" && -r "${LE_KEY}" ) ]]; then
    log_warn "Postfix: LE-сертификат отсутствует — пропускаю активацию 587/465"
    return 0
  fi
  log_info "Postfix: настраиваю сервисы submission (587) и smtps (465)"
  run_cmd postconf -M "submission/inet= submission inet n - y - - smtpd"
  run_cmd postconf -P "submission/inet/smtpd_tls_security_level=encrypt"
  run_cmd postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
  run_cmd postconf -P "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
  run_cmd postconf -P "submission/inet/smtpd_tls_cert_file=${LE_FULL}"
  run_cmd postconf -P "submission/inet/smtpd_tls_key_file=${LE_KEY}"

  run_cmd postconf -M "smtps/inet= smtps inet n - y - - smtpd"
  run_cmd postconf -P "smtps/inet/smtpd_tls_wrappermode=yes"
  run_cmd postconf -P "smtps/inet/smtpd_sasl_auth_enable=yes"
  run_cmd postconf -P "smtps/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
  run_cmd postconf -P "smtps/inet/smtpd_tls_cert_file=${LE_FULL}"
  run_cmd postconf -P "smtps/inet/smtpd_tls_key_file=${LE_KEY}"
}

# Условно включать/выключать порт 25 по accept_inbound (как было)
postfix::toggle_inbound_25() {
  postfix::paths
  local tmp
  if [[ "${ACCEPT_INBOUND:-true}" == "true" ]]; then
    if ! postconf -M smtp/inet >/dev/null 2>&1; then
      run_cmd postconf -M "smtp/inet= smtp inet n - y - - smtpd"
      log_info "Postfix: добавил smtp/inet (25) в master.cf"
    fi
  else
    if grep -Eq '^[[:space:]]*smtp[[:space:]]+inet[[:space:]]+.*smtpd' "${PF_MASTER}" 2>/dev/null; then
      tmp="$(mktemp)"
      awk '{
        if ($0 ~ /^[[:space:]]*smtp[[:space:]]+inet[[:space:]]+.*smtpd/ && $0 !~ /^[[:space:]]*#/) {
          print "# " $0 " (disabled by msa)"
        } else { print }
      }' "${PF_MASTER}" > "${tmp}"
      run_cmd install -m 0644 "$tmp" "$PF_MASTER"
      rm -f "$tmp"
      log_info "Postfix: отключил smtp/inet (25) (accept_inbound=false)"
    else
      log_info "Postfix: smtp/inet (25) уже отключён или отсутствует"
    fi
  fi
}

postfix::reload_enable() {
  run_cmd postfix check
  run_cmd systemctl enable --now postfix
  run_cmd bash -c 'systemctl reload postfix || systemctl restart postfix'
}

# --- ENTRYPOINT ---
postfix::write_main_cf
postfix::virtual_maps_from_users
postfix::toggle_inbound_25
postfix::enable_tls_services
postfix::reload_enable
