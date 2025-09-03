# modules/04_dovecot.sh — конфигурация Dovecot (IMAPS/POPS, LMTP, SASL)
# Требует: DOMAIN, HOSTNAME, VARS_FILE, DRY_RUN; функции: run_cmd, log_*, die, require_cmd
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

dovecot::paths() {
  DC_CONF_DIR="/etc/dovecot"
  DC_CONF_DROPIN="${DC_CONF_DIR}/conf.d/90-msa.conf"
  DC_PASSDB_DIR="${DC_CONF_DIR}/passdb"
  DC_PASSDB_FILE="${DC_PASSDB_DIR}/users"
  VMAIL_HOME="/var/vmail"
  LE_FULL="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
  LE_KEY="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"
}

dovecot::require_bins() {
  require_cmd doveadm
  require_cmd openssl
}

dovecot::write_passdb() {
  dovecot::paths
  run_cmd "install -d -m 0750 '${DC_PASSDB_DIR}'"
  local tmp; tmp="$(mktemp)"
  local count i login password hash
  count="$(yq -r '(.users // []) | length' "${VARS_FILE}")"
  for (( i=0; i<count; i++ )); do
    login="$(yq -r ".users[${i}].login" "${VARS_FILE}")"
    password="$(yq -r ".users[${i}].password" "${VARS_FILE}")"
    [[ -n "$login" && -n "$password" ]] || continue
    hash="$(doveadm pw -s SHA512-CRYPT -p "${password}")"
    printf '%s:%s\n' "$login" "$hash" >> "$tmp"
  done
  run_cmd "install -m 0640 -o root -g vmail '${tmp}' '${DC_PASSDB_FILE}'"
  rm -f "$tmp"
}

dovecot::ensure_maildirs() {
  dovecot::paths
  local count i login u_local u_domain mdir
  count="$(yq -r '(.users // []) | length' "${VARS_FILE}")"
  for (( i=0; i<count; i++ )); do
    login="$(yq -r ".users[${i}].login" "${VARS_FILE}")"
    [[ -n "$login" ]] || continue
    u_local="${login%@*}"
    u_domain="${login#*@}"
    mdir="${VMAIL_HOME}/${u_domain}/${u_local}/Maildir"
    run_cmd "install -d -m 0700 -o vmail -g vmail '${mdir}'"
  done
}

dovecot::write_conf() {
  dovecot::paths
  local tmp; tmp="$(mktemp)"
  {
    cat <<'EOF'
# Managed by msa-install — DO NOT EDIT
protocols = imap pop3 lmtp
listen = *

# Хранилище
mail_location = maildir:/var/vmail/%d/%n/Maildir
# Нижние границы, фактические uid/gid задаются userdb=static
first_valid_uid = 100
first_valid_gid = 100

namespace inbox {
  inbox = yes
}

# Аутентификация
auth_mechanisms = plain login
disable_plaintext_auth = yes
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/passdb/users
}
userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/vmail/%d/%n
}

# Сокеты для Postfix
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
    if [[ -r "${LE_FULL}" && -r "${LE_KEY}" ]]; then
      cat <<EOF
# TLS
ssl = required
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes
ssl_cert = <${LE_FULL}
ssl_key  = <${LE_KEY}
EOF
    else
      cat <<'EOF'
# TLS будет добавлен после получения LE-сертификата (см. 06_ssl.sh)
# ssl = required
EOF
    fi
  } > "$tmp"

  run_cmd "install -D -m 0644 '${tmp}' '${DC_CONF_DROPIN}'"
  rm -f "$tmp"
}

dovecot::reload_enable() {
  run_cmd "dovecot -n"
  run_cmd "systemctl enable --now dovecot"
  run_cmd "systemctl reload dovecot || systemctl restart dovecot"
}

dovecot::ensure_after_le() {
  dovecot::paths
  if [[ -r "${LE_FULL}" && -r "${LE_KEY}" ]]; then
    log_info "Dovecot: обнаружен LE-сертификат — включаю TLS и запускаю сервисы"
    dovecot::write_conf
    dovecot::reload_enable
  else
    log_warn "Dovecot: LE-сертификат всё ещё отсутствует — пропускаю включение TLS"
  fi
}

# --- ENTRYPOINT ---
dovecot::require_bins
dovecot::write_passdb
dovecot::ensure_maildirs
dovecot::write_conf
if [[ -r "/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem" && -r "/etc/letsencrypt/live/${HOSTNAME}/privkey.pem" ]]; then
  dovecot::reload_enable
else
  log_warn "Dovecot: LE-сертификата нет — сервис не запускаю до получения TLS (ожидаю 06_ssl.sh)"
fi
