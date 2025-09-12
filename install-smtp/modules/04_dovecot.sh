#!/usr/bin/env bash
# 04_dovecot.sh — Dovecot: passwd-file, SMTP AUTH, Maildir, LMTP и первичная инициализация
set -Eeuo pipefail
IFS=$'\n\t'

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"
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
  log_info "Dovecot: задаю mail_location (Maildir) через 90-msa-maildir.conf"
  cat <<'EOF' | run_cmd install -D -m 0644 /dev/stdin /etc/dovecot/conf.d/90-msa-maildir.conf
mail_location = maildir:/var/vmail/%d/%n/Maildir
protocols = imap lmtp sieve pop3
EOF
}

dovecot::enable_lmtp_listener() {
  # LMTP-сокет для Postfix в его chroot (/var/spool/postfix)
  cat <<'EOF' | run_cmd install -D -m 0644 /dev/stdin /etc/dovecot/conf.d/90-msa-lmtp.conf
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
EOF
  run_cmd install -d -m 0750 -o postfix -g postfix /var/spool/postfix/private
}

dovecot::ensure_namespace() {
  # Автопапки со special-use, чтобы клиенты их видели сразу
  cat <<'EOF' | run_cmd install -D -m 0644 /dev/stdin /etc/dovecot/conf.d/90-msa-namespace.conf
namespace inbox {
  inbox = yes

  mailbox Sent {
    auto = subscribe
    special_use = \Sent
  }
  mailbox Drafts {
    auto = subscribe
    special_use = \Drafts
  }
  mailbox Junk {
    auto = subscribe
    special_use = \Junk
  }
  mailbox Trash {
    auto = subscribe
    special_use = \Trash
  }
}
EOF
}

dovecot::ensure_vmail_root() {
  # Нормализуем корень, если уже существовал как root:root
  run_cmd mkdir -p /var/vmail
  run_cmd chown vmail:vmail /var/vmail
  run_cmd chmod 0750 /var/vmail
}

dovecot::init_maildirs_and_inbox() {
  # создаём корень ящика и Maildir для всех пользователей (до первого логина)
  while IFS=$'\t' read -r LOGIN _; do
    [[ -n "${LOGIN:-}" ]] || continue

    local domain="${LOGIN#*@}"
    local user="${LOGIN%@*}"
    local domain_dir="/var/vmail/${domain}"
    local user_dir="${domain_dir}/${user}"
    local maildir="${user_dir}/Maildir"

    # слой 1: доменная папка
    run_cmd install -d -m 0750 "${domain_dir}"
    run_cmd chown vmail:vmail "${domain_dir}"
    run_cmd chmod 0750 "${domain_dir}"

    # слой 2: пользовательская папка
    run_cmd install -d -m 0750 "${user_dir}"
    run_cmd chown vmail:vmail "${user_dir}"
    run_cmd chmod 0750 "${user_dir}"

    # слой 3: Maildir + subdirs (cur/new/tmp)
    run_cmd install -d -m 0750 "${maildir}"
    run_cmd chown vmail:vmail "${maildir}"
    run_cmd chmod 0750 "${maildir}"

    run_cmd install -d -m 0750 "${maildir}/cur" "${maildir}/new" "${maildir}/tmp"
    run_cmd chown -R vmail:vmail "${maildir}/cur" "${maildir}/new" "${maildir}/tmp"
    run_cmd chmod 0750 "${maildir}/cur" "${maildir}/new" "${maildir}/tmp"

    # финальная зачистка прав на уровне user_dir (на случай гонок и старых папок)
    run_cmd chown -R vmail:vmail "${user_dir}"
    run_cmd find "${user_dir}" -type d -print0 | xargs -0 chmod 0750

    # создаём INBOX (после прав!)
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

  # мини-проверка INBOX
  if doveadm mailbox list -u "$u" 2>/dev/null | grep -q '^INBOX$'; then
    log_info "Dovecot: INBOX присутствует (${u})"
  else
    log_warn "Dovecot: INBOX не найден (${u})"
  fi
}

module::main() {
  dovecot::ensure_passdb_dir
  dovecot::render_passdb_from_vars
  dovecot::enable_passwdfile_auth
  dovecot::postfix_auth_socket
  dovecot::ensure_mail_location
  dovecot::enable_lmtp_listener
  dovecot::ensure_namespace
  dovecot::ensure_vmail_root
  dovecot::init_maildirs_and_inbox
  dovecot::restart_and_selftest
}

module::main "$@"
