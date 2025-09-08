#!/usr/bin/env bash
set -euo pipefail

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"
: "${VARS_FILE:?}"

#!/usr/bin/env bash
# Module: Fail2ban jails + postfix-sasl filter + адаптивный banaction (функции + entrypoint)
set -euo pipefail


f2b::_detect_banaction() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'active'; then
    echo "ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    echo "firewallcmd-rich-rules"
  elif command -v iptables >/dev/null 2>&1; then
    echo "iptables-multiport"
  elif command -v nft >/dev/null 2>&1; then
    echo "nftables"
  else
    echo "iptables-multiport"  # разумный дефолт
  fi
}

f2b::write_global_ipv6_off() {
  log_info "Fail2ban: выключаю IPv6 (allowipv6 = no)"
  run_cmd install -D -m 0644 /dev/stdin /etc/fail2ban/fail2ban.local <<'CONF'
[Definition]
allowipv6 = no
CONF
}

f2b::ensure_filter_postfix_sasl() {
  local f="/etc/fail2ban/filter.d/postfix-sasl.conf"
  if [[ ! -f "$f" ]]; then
    log_info "Fail2ban: создаю фильтр postfix-sasl.conf"
    run_cmd install -D -m 0644 /dev/stdin "$f" <<'CONF'
[Definition]
failregex = (?i)postfix/smtpd\[\d+\]:\s+warning:\s+[-\w\.:]+\[<HOST>\]:\s+SASL (?:LOGIN|PLAIN|AUTH) authentication failed: .*
            (?i)authentication failure;.*\bSASL\b.*user=<[^>]*>.*rip=<HOST>
ignoreregex =
CONF
  fi
}

f2b::write_jails() {
  local banaction; banaction="$(f2b::_detect_banaction)"
  log_info "Fail2ban: banaction=${banaction}"
  run_cmd install -D -m 0644 /dev/stdin /etc/fail2ban/jail.d/msa-mail.conf <<CONF
[DEFAULT]
backend = auto
banaction = ${banaction}
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
  log_info "Fail2ban: включаю сервис и перегружаю конфиг"
  run_cmd systemctl enable --now fail2ban
  run_cmd fail2ban-client reload
}

module::main() {
  f2b::write_global_ipv6_off
  f2b::ensure_filter_postfix_sasl
  f2b::write_jails
  f2b::reload
}
module::main "$@"
