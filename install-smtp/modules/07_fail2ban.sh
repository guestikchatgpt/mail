# modules/07_fail2ban.sh — Fail2ban jails для Postfix/Dovecot (+ postfix-sasl)
# Требует: run_cmd, log_info, log_warn, log_error, die, require_cmd
# Зависимости: fail2ban, rsyslog (для /var/log/mail.log)
# shellcheck shell=bash

fail2ban::paths() {
  F2B_DIR="/etc/fail2ban"
  F2B_JAILD="${F2B_DIR}/jail.d"
  F2B_CONF="${F2B_JAILD}/msa-mail.conf"
  F2B_FILTER_DIR="${F2B_DIR}/filter.d"
}

fail2ban::require_bins() {
  require_cmd fail2ban-client
  require_cmd systemctl
}

fail2ban::detect_banaction() {
  BANACTION=""
  BANACTION_ALLPORTS=""

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qEi '^Status:\s+active'; then
      BANACTION="ufw"
      BANACTION_ALLPORTS="ufw"
      log_info "Fail2ban: активен UFW — banaction=ufw"
    fi
  fi
}

fail2ban::warn_if_missing_filters() {
  fail2ban::paths
  for f in postfix.conf dovecot.conf postfix-sasl.conf; do
    [[ -r "${F2B_FILTER_DIR}/${f}" ]] || log_warn "Fail2ban: отсутствует фильтр ${f} — проверь установку пакета fail2ban"
  done
}

fail2ban::write_jail_conf() {
  fail2ban::paths
  fail2ban::detect_banaction

  log_info "Fail2ban: пишу конфиг jails в ${F2B_CONF}"

  local tmp; tmp="$(mktemp)"
  {
    echo '# Managed by msa-install — DO NOT EDIT'
    echo '[DEFAULT]'
    echo 'findtime = 10m'
    echo 'bantime  = 1h'
    echo 'maxretry = 5'
    echo 'backend  = auto'
    if [[ -n "${BANACTION}" ]]; then
      echo "banaction = ${BANACTION}"
      echo "banaction_allports = ${BANACTION_ALLPORTS}"
    fi
    echo
    echo '[postfix]'
    echo 'enabled = true'
    echo 'port    = smtp,submission,smtps'
    echo 'logpath = /var/log/mail.log'
    # filter = postfix
    echo
    echo '[postfix-sasl]'
    echo 'enabled = true'
    echo 'port    = smtp,submission,smtps'
    echo 'logpath = /var/log/mail.log'
    # filter = postfix-sasl
    echo
    echo '[dovecot]'
    echo 'enabled = true'
    echo 'port    = pop3,pop3s,imap,imaps'
    echo 'logpath = /var/log/mail.log'
    # filter = dovecot
  } > "${tmp}"

  run_cmd "install -D -m 0644 '${tmp}' '${F2B_CONF}'"
  rm -f "${tmp}"
}

fail2ban::reload_enable() {
  log_info "Fail2ban: включаю сервис и перезагружаю конфигурацию"
  run_cmd "systemctl enable --now fail2ban"
  if ! run_cmd "fail2ban-client reload"; then
    run_cmd "systemctl restart fail2ban"
  fi
  # Неболезненная проверка статуса jails
  run_cmd "fail2ban-client status" || true
  for j in postfix postfix-sasl dovecot; do
    run_cmd "fail2ban-client status ${j}" || true
  done
}

# --- ENTRYPOINT ---
fail2ban::paths
fail2ban::require_bins
fail2ban::warn_if_missing_filters
fail2ban::write_jail_conf
fail2ban::reload_enable
