#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"
: "${VARS_FILE:?}"

#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

: "${VARS_FILE:?}"

#!/usr/bin/env bash
# Module: Dovecot passwd-file + SMTP AUTH + Maildir и первичная инициализация
set -euo pipefail

: "${VARS_FILE:?}"

dovecot::_yq() { yq -r "$1" "${VARS_FILE}"; }

dovecot::ensure_passdb_dir() {
  run_cmd install -d -m 0750 -o root -g dovecot /etc/dovecot/passdb
}

dovecot::render_passdb_from_vars() {
  local users_file=/etc/dovecot/passdb/users
  : >"$users_file"
  while IFS=$'\t' read -r LOGIN PASSWORD; do
    [[ -n "${LOGIN:-}" && -n "${PASSWORD:-}" ]] || continue
    local HASH; HASH="$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")"
    printf '%s:%s\n' "$LOGIN" "$HASH" >>"$users_file"
  done < <(yq -r '.users[] | [.login, .password] | @tsv' "${VARS_FILE}")
  run_cmd chown root:dovecot "$users_file"
  run_cmd chmod 0640 "$users_file"
}

dovecot::enable_passwdfile_auth() {
  run_cmd sed -i 's/^!include[[:space:]]\+auth-system\.conf\.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
  run_cmd sed -i 's/^#\s*!include[[:space:]]\+auth-passwdfile\.conf\.ext/!include auth-passwdfile.conf.ext/' /etc/dovecot/conf.d/10-auth.conf

  local cfg=/etc/dovecot/conf.d/auth-passwdfile.conf.ext
  local desired; desired="$(cat <<'EOF'
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/passdb/users
}
userdb {
  driver = static
  args = uid=vmail gid=vmail home=/var/vmail/%d/%n
}
EOF
)"
  if ! cmp -s <(printf '%s' "$desired") "$cfg" 2>/dev/null; then
    log_info "Dovecot: обновляю $cfg"
    printf '%s' "$desired" | run_cmd install -D -m 0644 /dev/stdin "$cfg"
  fi
}

dovecot::postfix_auth_socket() {
  local cfg=/etc/dovecot/conf.d/90-postfix-auth.conf
  local desired; desired="$(cat <<'EOF'
auth_mechanisms = plain login
disable_plaintext_auth = yes
service auth {
  unix_listener /var/spool/postfix/private/auth {
    user = postfix
    group = postfix
    mode = 0660
  }
}
EOF
)"
  if ! cmp -s <(printf '%s' "$desired") "$cfg" 2>/dev/null; then
    log_info "Dovecot: пишу $cfg"
    printf '%s' "$desired" | run_cmd install -D -m 0644 /dev/stdin "$cfg"
  fi
  run_cmd install -d -m 0750 -o postfix -g postfix /var/spool/postfix/private
}

dovecot::ensure_mail_location() {
  if ! dovecot -n 2>/dev/null | grep -q '^mail_location ='; then
    log_info "Dovecot: задаю mail_location (Maildir)"
    cat <<'EOF' | run_cmd install -D -m 0644 /dev/stdin /etc/dovecot/conf.d/90-msa-maildir.conf
mail_location = maildir:/var/vmail/%d/%n/Maildir
protocols = imap lmtp sieve pop3
EOF
  fi
}

dovecot::init_maildirs_and_inbox() {
  # создаём каталоги и INBOX для всех пользователей
  while IFS=$'\t' read -r LOGIN _; do
    [[ -n "${LOGIN:-}" ]] || continue
    local d="/var/vmail/${LOGIN#*@}/${LOGIN%@*}"
    run_cmd install -d -m 0750 -o vmail -g vmail "$d/Maildir"/{cur,new,tmp}
    # создаём INBOX через doveadm (не падаем, если уже есть)
    if ! doveadm mailbox list -u "$LOGIN" >/dev/null 2>&1; then
      :
    fi
    doveadm mailbox create -u "$LOGIN" INBOX >/dev/null 2>&1 || true
    log_info "Dovecot: подготовлен Maildir для ${LOGIN}"
  done < <(yq -r '.users[] | [.login, .password] | @tsv' "${VARS_FILE}")
}

dovecot::restart_and_selftest() {
  run_cmd systemctl enable --now dovecot
  run_cmd systemctl restart dovecot

  local u p
  u="$(dovecot::_yq '.users[0].login')"
  p="$(dovecot::_yq '.users[0].password')"
  if doveadm auth test -x service=smtp "$u" "$p" >/dev/null 2>&1; then
    log_info "Dovecot: SMTP AUTH OK (${u})"
  else
    log_warn "Dovecot: SMTP AUTH FAIL (${u}) — см. /var/log/mail.log"
  fi
}

module::main() {
  dovecot::ensure_passdb_dir
  dovecot::render_passdb_from_vars
  dovecot::enable_passwdfile_auth
  dovecot::postfix_auth_socket
  dovecot::ensure_mail_location
  dovecot::init_maildirs_and_inbox
  dovecot::restart_and_selftest
}

module::main "$@"
