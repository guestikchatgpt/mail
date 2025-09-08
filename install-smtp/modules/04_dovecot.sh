#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

# === Новый код: маленькие функции поверх существующей логики ===

dovecot::ensure_passdb_dir() {
  run install -d -m 0750 -o root -g dovecot /etc/dovecot/passdb
}

dovecot::render_passdb_from_vars() {
  local users_file=/etc/dovecot/passdb/users
  : >"$users_file"
  # читаем логины/пароли из vars.yaml (yq v4)
  while IFS=$'\t' read -r LOGIN PASSWORD; do
    [[ -n "$LOGIN" && -n "$PASSWORD" ]] || continue
    local HASH
    HASH="$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")"
    printf '%s:%s\n' "$LOGIN" "$HASH" >>"$users_file"
  done < <(yq -r '.users[] | [.login, .password] | @tsv' "$VARS")

  run chown root:dovecot "$users_file"
  run chmod 0640 "$users_file"
}

dovecot::enable_passwdfile_auth() {
  # отключаем system auth, включаем passwd-file (idempotent)
  run sed -i 's/^!include[[:space:]]\+auth-system\.conf\.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
  run sed -i 's/^#\s*!include[[:space:]]\+auth-passwdfile\.conf\.ext/!include auth-passwdfile.conf.ext/' /etc/dovecot/conf.d/10-auth.conf

  # auth-passwdfile.conf.ext — только если отличается/нет
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
    log "Dovecot: обновляю $cfg"
    printf '%s' "$desired" | run install -D -m 0644 /dev/stdin "$cfg"
  fi
}

dovecot::postfix_auth_socket() {
  # отдельный include, чтобы не гадать, какой файл переопределит сервис
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
    log "Dovecot: пишу $cfg"
    printf '%s' "$desired" | run install -D -m 0644 /dev/stdin "$cfg"
  fi

  run install -d -m 0750 -o postfix -g postfix /var/spool/postfix/private
}

dovecot::ensure_maildir_location() {
  # не трогаем, если уже задано явно
  if ! dovecot -n 2>/dev/null | grep -q '^mail_location ='; then
    log "Dovecot: задаю mail_location (Maildir)"
    cat <<'EOF' | run install -D -m 0644 /dev/stdin /etc/dovecot/conf.d/90-msa.conf
mail_location = maildir:/var/vmail/%d/%n/Maildir
protocols = imap lmtp sieve pop3
EOF
  fi
}

dovecot::restart_and_selftest() {
  run systemctl enable --now dovecot
  run systemctl restart dovecot

  # быстрый самотест на первом пользователе
  local u p
  u="$(yq -r '.users[0].login' "$VARS")"
  p="$(yq -r '.users[0].password' "$VARS")"
  if doveadm auth test -x service=smtp "$u" "$p" >/dev/null 2>&1; then
    log "Dovecot: SMTP AUTH OK ($u)"
  else
    warn "Dovecot: SMTP AUTH FAIL ($u) — проверь /var/log/mail.log"
  fi
}

# === Точка входа модуля (сохраняем стиль/структуру) ===
module::main() {
  log "Dovecot: настраиваю passwd-file и SMTP AUTH для Postfix"
  dovecot::ensure_passdb_dir
  dovecot::render_passdb_from_vars
  dovecot::enable_passwdfile_auth
  dovecot::postfix_auth_socket
  dovecot::ensure_maildir_location
  dovecot::restart_and_selftest
}

module::main "$@"
