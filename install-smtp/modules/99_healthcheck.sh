#!/usr/bin/env bash
# 99_healthcheck.sh — проверки Dovecot/Maildir без изменений конфигурации (soft-fail по умолчанию)
set -Eeuo pipefail
IFS=$'\n\t'

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"
: "${VARS_FILE:?}"
HEALTHCHECK_STRICT="${HEALTHCHECK_STRICT:-false}"

hc::_yq() { yq -r "$1" "${VARS_FILE}"; }
hc::first_user_login()   { hc::_yq '.users[0].login'; }
hc::first_user_password(){ hc::_yq '.users[0].password'; }

hc::user_dir_for() { local login="$1"; printf '/var/vmail/%s/%s' "${login#*@}" "${login%@*}"; }

hc::fail() { log_error "$*"; return 1; }
hc::ok()   { log_info  "$*"; return 0;  }

hc::check_service_active() {
  if systemctl is-active --quiet dovecot; then
    hc::ok "dovecot: service active"
  else
    hc::fail "dovecot: service NOT active"
  fi
}

hc::check_mail_location() {
  local out; out="$(doveconf -n 2>/dev/null || true)"
  [[ -n "$out" ]] || { hc::fail "doveconf -n: empty/failed"; return 1; }

  # Принимаем:
  #  - maildir:/var/vmail/%d/%n/Maildir
  #  - maildir:/var/vmail/%d/%n
  #  - maildir:~/Maildir (если дальше есть home=/var/vmail/%d/%n)
  if grep -Eq '^mail_location = maildir:/var/vmail/%d/%n(/Maildir)?([[:space:]]*$|:)' <<<"$out"; then
    hc::ok "mail_location OK (maildir:/var/vmail/%d/%n[/Maildir])"
    return 0
  fi
  if grep -Eq '^mail_location = maildir:~/Maildir([[:space:]]*$|:)' <<<"$out" && \
     grep -Eq '(^|[[:space:]])home[[:space:]]*=[[:space:]]*/var/vmail/%d/%n([[:space:]]|$)' <<<"$out"; then
    hc::ok "mail_location OK (maildir:~/Maildir + home=/var/vmail/%d/%n)"
    return 0
  fi

  hc::fail "mail_location mismatch (ожидаю maildir:/var/vmail/%d/%n[/Maildir] либо maildir:~/Maildir+home=/var/vmail/%d/%n)"
}

hc::check_auth_config() {
  local out; out="$(doveconf -n 2>/dev/null || true)"
  [[ -n "$out" ]] || { hc::fail "doveconf -n: empty/failed"; return 1; }

  if grep -Eqi '^auth_mechanisms = .*plain.*login' <<<"$out"; then
    hc::ok "auth_mechanisms OK (plain, login)"
  else
    hc::fail "auth_mechanisms: нет plain/login"
  fi

  # passdb passwd-file
  if grep -Eqi '(^|[[:space:]])passdb([[:space:]]|\{).*passwd-file' <<<"$(tr -d '\n' <<<"$out")"; then
    hc::ok "passdb driver = passwd-file"
  else
    hc::fail "passdb: не найден driver=passwd-file"
  fi

  # userdb: достаточно увидеть home=/var/vmail/%d/%n (в любом блоке userdb/static)
  if grep -Eqi '(^|[[:space:]])home[[:space:]]*=[[:space:]]*/var/vmail/%d/%n([[:space:]]|$)' <<<"$out"; then
    hc::ok "userdb: home=/var/vmail/%d/%n обнаружен"
  else
    hc::fail "userdb: нет home=/var/vmail/%d/%n"
  fi
}

hc::check_postfix_auth_socket() {
  local s="/var/spool/postfix/private/auth"
  if [[ -S "$s" ]]; then
    local meta; meta="$(stat -Lc '%U:%G %a' "$s" 2>/dev/null || true)"
    if grep -q '^postfix:postfix 660$' <<<"$meta"; then
      hc::ok "auth socket OK ($meta)"
    else
      hc::fail "auth socket perms/owner: ожидаю postfix:postfix 660, имею: $meta"
    fi
  else
    hc::fail "auth socket отсутствует: $s"
  fi
}

hc::check_passdb_file() {
  local f="/etc/dovecot/passdb/users"
  if [[ -f "$f" ]]; then
    local meta; meta="$(stat -Lc '%U:%G %a' "$f" 2>/dev/null || true)"
    if grep -q '^root:dovecot 640$' <<<"$meta"; then
      hc::ok "passdb users OK ($meta)"
    else
      hc::fail "passdb users perms/owner: ожидаю root:dovecot 640, имею: $meta"
    fi
  else
    hc::fail "passdb users отсутствует: $f"
  fi
}

hc::check_maildirs() {
  local rc=0
  while IFS=$'\t' read -r LOGIN _; do
    [[ -n "${LOGIN:-}" ]] || continue
    local d; d="$(hc::user_dir_for "$LOGIN")"

    if [[ -d "$d" ]]; then
      local meta; meta="$(stat -Lc '%U:%G %a' "$d" 2>/dev/null || true)"
      [[ "$meta" == "vmail:vmail 750" ]] || { log_error "Maildir root perms/owner: ожидаю vmail:vmail 750 для $d, имею: $meta"; rc=1; }
    else
      log_error "Maildir root отсутствует: $d"; rc=1
    fi

    for sub in cur new tmp; do
      local sd="$d/Maildir/$sub"
      if [[ -d "$sd" ]]; then
        local sm; sm="$(stat -Lc '%U:%G %a' "$sd" 2>/dev/null || true)"
        [[ "$sm" == "vmail:vmail 750" ]] || { log_error "Maildir/$sub perms/owner: ожидаю vmail:vmail 750 для $sd, имею: $sm"; rc=1; }
      else
        log_error "Подкаталог отсутствует: $sd"; rc=1
      fi
    done

    if doveadm mailbox status -u "$LOGIN" messages INBOX >/dev/null 2>&1; then
      log_info "INBOX OK для $LOGIN"
    else
      log_warn "INBOX не доступен/не создан для $LOGIN"
    fi
  done < <(yq -r '.users[] | [.login, .password] | @tsv' "${VARS_FILE}")

  [[ $rc -eq 0 ]] && hc::ok "Maildir: структура и права выглядят корректно" || return 1
}

hc::selftest_auth() {
  local u p
  u="$(hc::first_user_login || true)"
  p="$(hc::first_user_password || true)"
  [[ -n "$u" && -n "$p" ]] || { hc::fail "users[0] не задан в vars"; return 1; }

  if doveadm auth test -x service=smtp "$u" "$p" >/dev/null 2>&1; then
    hc::ok "SMTP AUTH OK (${u})"
  else
    hc::fail "SMTP AUTH FAIL (${u}) — см. /var/log/mail.log"
  fi
}

module::main() {
  local rc=0
  hc::check_service_active      || rc=1
  hc::check_mail_location       || rc=1
  hc::check_auth_config         || rc=1
  hc::check_postfix_auth_socket || rc=1
  hc::check_passdb_file         || rc=1
  hc::check_maildirs            || rc=1
  hc::selftest_auth             || rc=1

  if [[ $rc -eq 0 ]]; then
    log_info "HEALTHCHECK: OK"
  else
    log_warn "HEALTHCHECK: есть проблемы (rc=$rc)"
  fi

  # По умолчанию не валим пайплайн, чтобы 100_report.sh отработал
  if [[ "$HEALTHCHECK_STRICT" == "true" ]]; then
    exit "$rc"
  else
    exit 0
  fi
}

module::main "$@"
