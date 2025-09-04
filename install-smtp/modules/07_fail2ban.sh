#!/usr/bin/env bash
# Module: Fail2ban jails + postfix-sasl filter + disable IPv6 warnings

set -euo pipefail

f2b::write_global_ipv6_off() {
  log INFO "Fail2ban: глобально выключаю IPv6 (allowipv6 = no)"
  run_cmd install -D -m 0644 /dev/stdin /etc/fail2ban/fail2ban.local <<'CONF'
[Definition]
allowipv6 = no
CONF
}

f2b::ensure_filter_postfix_sasl() {
  local f="/etc/fail2ban/filter.d/postfix-sasl.conf"
  if [[ ! -f "$f" ]]; then
    log INFO "Fail2ban: не найден фильтр postfix-sasl.conf — создаю"
    run_cmd install -D -m 0644 /dev/stdin "$f" <<'CONF'
[Definition]
failregex = (?i)postfix/smtpd\[\d+\]:\s+warning:\s+[-\w\.:]+\[<HOST>\]:\s+SASL (?:LOGIN|PLAIN|AUTH) authentication failed: .*
            (?i)authentication failure;.*\bSASL\b.*user=<[^>]*>.*rip=<HOST>
ignoreregex =
CONF
  fi
}

f2b::write_jails() {
  log INFO "Fail2ban: пишу конфиг jails в /etc/fail2ban/jail.d/msa-mail.conf"
  run_cmd install -D -m 0644 /dev/stdin /etc/fail2ban/jail.d/msa-mail.conf <<'CONF'
[DEFAULT]
backend = auto
banaction = ufw
findtime = 10m
maxretry = 5
bantime = 1h
ignoreip = 127.0.0.1/8

[postfix]
enabled = true
filter  = postfix
port    = smtp,submission,465
logpath = /var/log/mail.log

[postfix-sasl]
enabled = true
filter  = postfix-sasl
port    = smtp,submission,465
logpath = /var/log/mail.log

[dovecot]
enabled = true
filter  = dovecot
port    = imap,imaps,pop3,pop3s
logpath = /var/log/mail.log
CONF
}

f2b::reload() {
  log INFO "Fail2ban: включаю сервис и перезагружаю конфигурацию"
  run_cmd systemctl enable --now fail2ban
  run_cmd fail2ban-client reload
}

# --- run ---
f2b::write_global_ipv6_off
f2b::ensure_filter_postfix_sasl
f2b::write_jails
f2b::reload
