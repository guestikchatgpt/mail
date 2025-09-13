#!/usr/bin/env bash

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"

_log() { printf '[%(%FT%TZ)T] [%s] %s\n' -1 "$1" "$2"; }
INFO(){ _log INFO "$*"; }
WARN(){ _log WARN "$*"; }
ERROR(){ _log ERROR "$*"; }

module::main() {
  set -Eeuo pipefail
  IFS=$'\n\t'
  : "${VARS_FILE:?}"
  : "${DOMAIN:?}"
  : "${HOSTNAME:?}"
  : "${IPV4:?}"

  INFO "Пишу /etc/mailname = ${HOSTNAME}"
  printf '%s\n' "${HOSTNAME}" | tee /etc/mailname >/dev/null

  # UID/GID для vmail (без хардкода)
  VMAIL_UID="$(id -u vmail 2>/dev/null || true)"
  VMAIL_GID="$(id -g vmail 2>/dev/null || true)"
  [[ -n "${VMAIL_UID}" && -n "${VMAIL_GID}" ]] || { ERROR "Пользователь vmail не найден"; exit 1; }

  INFO "Устанавливаю системный hostname = ${HOSTNAME}"
  run_cmd hostnamectl set-hostname "${HOSTNAME}"
  echo "${HOSTNAME}" | run_cmd tee /etc/hostname >/dev/null

  INFO "Postfix: базовая конфигурация и TLS-жёсткость (TLS1.2+)"
  postconf -e myhostname="${HOSTNAME}"
  postconf -e myorigin="${DOMAIN}"
  postconf -e inet_interfaces=all
  postconf -e inet_protocols=ipv4
  postconf -e smtp_address_preference=ipv4
  postconf -e smtp_bind_address="${IPV4}"
  postconf -e mynetworks='127.0.0.0/8'
  postconf -e smtpd_banner='$myhostname ESMTP'

  # SASL (AUTH через Dovecot) + TLS
  postconf -e smtpd_sasl_type=dovecot
  postconf -e smtpd_sasl_path=private/auth
  postconf -e smtpd_sasl_auth_enable=yes
  postconf -e smtpd_tls_auth_only=yes
  postconf -e smtpd_tls_security_level=may
  postconf -e smtp_tls_security_level=may
  postconf -e smtpd_tls_protocols='!SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
  postconf -e smtp_tls_protocols='!SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
  postconf -e tls_preempt_cipherlist=yes
  postconf -e smtpd_tls_ciphers=high
  postconf -e smtp_tls_ciphers=high
  postconf -e smtpd_tls_mandatory_ciphers=high

  # ===== Санитария SMTP на входящем 25-м =====
  postconf -e \
    "smtpd_helo_required=yes" \
    "disable_vrfy_command=yes" \
    "smtpd_delay_reject=yes" \
    "smtpd_sender_restrictions=reject_non_fqdn_sender,reject_unknown_sender_domain" \
    "smtpd_client_restrictions=warn_if_reject reject_unknown_reverse_client_hostname" \
    "smtpd_relay_restrictions=permit_mynetworks,permit_sasl_authenticated,defer_unauth_destination" \
    "smtpd_recipient_restrictions=reject_unknown_recipient_domain,reject_unauth_destination,reject_unlisted_recipient"

  # Лёгкие rate-limits (anvil)
  postconf -e \
    "anvil_rate_time_unit=60s" \
    "smtpd_client_connection_rate_limit=30" \
    "smtpd_client_connection_count_limit=20" \
    "smtpd_client_message_rate_limit=100" \
    "smtpd_soft_error_limit=10" \
    "smtpd_hard_error_limit=20"

  # ===== Виртуальные домены/ящики + LMTP доставка в Dovecot =====
  postconf -e virtual_mailbox_base='/var/vmail'
  postconf -e virtual_mailbox_maps='hash:/etc/postfix/virtual_mailbox_maps'
  postconf -e virtual_mailbox_domains='hash:/etc/postfix/virtual_domains'
  postconf -e virtual_transport='lmtp:unix:private/dovecot-lmtp'
  postconf -e "virtual_uid_maps=static:${VMAIL_UID}"
  postconf -e "virtual_gid_maps=static:${VMAIL_GID}"

  # Карта доменов
  TMP_DOMAINS="$(mktemp)"
  {
    printf '%s %s\n' "${DOMAIN}" "OK"
  } | sed '/^$/d' | sort -u > "${TMP_DOMAINS}"
  install -m 0644 "${TMP_DOMАINS}" /etc/postfix/virtual_domains
  rm -f "${TMP_DOMАINS}"
  postmap hash:/etc/postfix/virtual_domains

  # Карта ящиков из vars.yaml: user@domain  domain/user/
  TMP_VMAPS="$(mktemp)"
  while IFS= read -r login; do
    [[ -n "${login}" ]] || continue
    if [[ "${login}" != *"@"* ]]; then
      login="${login}@${DOMAIN}"
    fi
    local_part="${login%@*}"
    domain_part="${login#*@}"
    printf '%s %s/%s/\n' "${login}" "${domain_part}" "${local_part}"
  done < <(yq -r '.users[]? | .login // ""' "${VARS_FILE}") \
    | sort -u > "${TMP_VMAPS}"
  install -m 0644 "${TMP_VMAPS}" /etc/postfix/virtual_mailbox_maps
  rm -f "${TMP_VMAPS}"
  postmap hash:/etc/postfix/virtual_mailbox_maps

  # ===== master.cf: включаем Postscreen на 25, smtpd как pass, и службы для DNSBL/TLS proxy =====
  postconf -X smtp/inet || true
  postconf -M 'smtp/inet=smtp inet n - y - 1 postscreen'
  postconf -M 'smtpd/pass=smtpd pass - - y - - smtpd'
  postconf -M 'dnsblog/unix=dnsblog unix - - y - 0 dnsblog'
  postconf -M 'tlsproxy/unix=tlsproxy unix - - y - - tlsproxy'

  # Postscreen/DNSBL (только на 25-м)
  postconf -e \
    "postscreen_greet_wait=5s" \
    "postscreen_greet_action=enforce" \
    "postscreen_non_smtp_command_action=drop" \
    "postscreen_pipelining_action=enforce" \
    "postscreen_bare_newline_action=drop" \
    "postscreen_blacklist_action=drop" \
    "postscreen_cache_map=btree:/var/lib/postfix/postscreen_cache" \
    "postscreen_dnsbl_ttl=1h" \
    "postscreen_cache_retention_time=7d" \
    "postscreen_dnsbl_action=enforce" \
    "postscreen_dnsbl_threshold=2" \
    "postscreen_dnsbl_sites=bl.spamcop.net*2 b.barracudacentral.org*2 list.dnswl.org*-1"

  # ===== submission/587: аутентифицированный исходящий, без DNSBL =====
  postconf -X submission/inet || true
  postconf -M 'submission/inet=submission inet n - n - - smtpd'
  postconf -P 'submission/inet/syslog_name=postfix/submission'
  postconf -P 'submission/inet/smtpd_tls_security_level=encrypt'
  postconf -P 'submission/inet/smtpd_sasl_auth_enable=yes'
  postconf -P 'submission/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject'
  postconf -P 'submission/inet/smtpd_recipient_restrictions=permit_sasl_authenticated,reject_unauth_destination'
  postconf -P 'submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject'
  postconf -P 'submission/inet/milter_macro_daemon_name=ORIGINATING'

  # ===== smtps/465: аналогично (если используешь) =====
  postconf -X smtps/inet || true
  postconf -M 'smtps/inet=smtps inet n - n - - smtpd'
  postconf -P 'smtps/inet/syslog_name=postfix/smtps'
  postconf -P 'smtps/inet/smtpd_tls_wrappermode=yes'
  postconf -P 'smtps/inet/smtpd_sasl_auth_enable=yes'
  postconf -P 'smtps/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject'
  postconf -P 'smtps/inet/smtpd_recipient_restrictions=permit_sasl_authenticated,reject_unauth_destination'
  postconf -P 'smtps/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject'
  postconf -P 'smtps/inet/milter_macro_daemon_name=ORIGINATING'

  # ===== DNS в chroot для postscreen/dnsblog =====
  install -d -m 0755 /var/spool/postfix/etc
  cat > /var/spool/postfix/etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
options timeout:2 attempts:2
EOF

  INFO "Postfix: включаю сервис и перезапускаю"
  run_cmd systemctl enable --now postfix
  run_cmd systemctl restart postfix

  INFO "Postfix: virtual_* (контроль)"
  postconf | egrep '^(virtual_mailbox_base|virtual_mailbox_maps|virtual_mailbox_domains|virtual_transport|virtual_uid_maps|virtual_gid_maps)'

  # ждём порты до 10 сек
  ok25=0 ok465=0 ok587=0
  for i in {1..10}; do
    ss -ltn 2>/dev/null | grep -qE '[:\\.]25[[:space:]]'  && ok25=1 || true
    ss -ltn 2>/dev/null | grep -qE '[:\\.]465[[:space:]]' && ok465=1 || true
    ss -ltn 2>/dev/null | grep -qE '[:\\.]587[[:space:]]' && ok587=1 || true
    (( ok25 && ok465 && ok587 )) && break
    sleep 1
  done

  if ! (( ok25 ));  then WARN "порт 25 — НЕ слушается";  fi
  if ! (( ok465 )); then WARN "порт 465 — НЕ слушается"; fi
  if ! (( ok587 )); then WARN "порт 587 — НЕ слушается"; fi

  if ! (( ok25 && ok465 && ok587 )); then
    ERROR "Postfix: после рестарта не поднялись все порты. Логи ниже:"
    journalctl -u postfix -n 200 --no-pager -o cat || true
    exit 1
  fi

  INFO "Postfix: ключевые параметры (контроль)"
  postconf -n | egrep -i '^(inet_protocols|smtp_address_preference|smtp_bind_address|mynetworks|smtpd_helo_required|disable_vrfy_command|smtpd_delay_reject|smtpd_(relay|recipient|sender|client)_restrictions|postscreen_|anvil_|smtpd_tls_security_level|smtp_tls_security_level)'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  module::main "$@"
fi

