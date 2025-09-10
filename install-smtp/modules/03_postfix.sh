#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"
: "${VARS_FILE:?}"

_log() { printf '[%(%FT%TZ)T] [%s] %s\n' -1 "$1" "$2"; }
INFO(){ _log INFO "$*"; }
WARN(){ _log WARN "$*"; }
ERROR(){ _log ERROR "$*"; }

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
postconf -e smtpd_banner='$myhostname ESMTP'
postconf -e smtpd_sasl_type=dovecot
postconf -e smtpd_sasl_path=private/auth
postconf -e smtpd_sasl_auth_enable=yes
postconf -e smtpd_recipient_restrictions='permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination'
postconf -e mynetworks='127.0.0.0/8'
postconf -e smtpd_tls_auth_only=yes
postconf -e smtpd_tls_security_level=may
postconf -e smtp_tls_security_level=may
postconf -e smtpd_tls_protocols='!SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
postconf -e smtp_tls_protocols='!SSLv2, !SSLv3, !TLSv1, !TLSv1.1'
postconf -e tls_preempt_cipherlist=yes
postconf -e smtpd_tls_ciphers=high
postconf -e smtp_tls_ciphers=high
postconf -e smtpd_tls_mandatory_ciphers=high

# ===== Виртуальные домены/ящики + LMTP доставка в Dovecot =====
postconf -e virtual_mailbox_base='/var/vmail'
postconf -e virtual_mailbox_maps='hash:/etc/postfix/virtual_mailbox_maps'
postconf -e virtual_mailbox_domains='hash:/etc/postfix/virtual_domains'
postconf -e virtual_transport='lmtp:unix:private/dovecot-lmtp'
postconf -e "virtual_uid_maps=static:${VMAIL_UID}"
postconf -e "virtual_gid_maps=static:${VMAIL_GID}"

# Карта доменов
tmp_domains="$(mktemp)"
{
  printf '%s %s\n' "${DOMAIN}" "OK"
} | sed '/^$/d' | sort -u > "${tmp_domains}"
install -m 0644 "${tmp_domains}" /etc/postfix/virtual_domains
rm -f "${tmp_domains}"
postmap hash:/etc/postfix/virtual_domains

# Карта ящиков из vars.yaml: user@domain  domain/user/
tmp_vmaps="$(mktemp)"
while IFS= read -r login; do
  [[ -n "${login}" ]] || continue
  if [[ "${login}" != *"@"* ]]; then
    login="${login}@${DOMAIN}"
  fi
  local_part="${login%@*}"
  domain_part="${login#*@}"
  printf '%s %s/%s/\n' "${login}" "${domain_part}" "${local_part}"
done < <(yq -r '.users[]? | .login // ""' "${VARS_FILE}") \
  | sort -u > "${tmp_vmaps}"
install -m 0644 "${tmp_vmaps}" /etc/postfix/virtual_mailbox_maps
rm -f "${tmp_vmaps}"
postmap hash:/etc/postfix/virtual_mailbox_maps

# master.cf: явно включаем три сервиса. На некоторых образах по умолчанию postscreen — уберём.
postconf -X smtp/inet || true
postconf -M smtp/inet="smtp inet n - n - - smtpd"

postconf -X submission/inet || true
postconf -M submission/inet="submission inet n - n - - smtpd"
postconf -P submission/inet/smtpd_tls_security_level=encrypt
postconf -P submission/inet/smtpd_sasl_auth_enable=yes
postconf -P submission/inet/smtpd_client_restrictions="permit_sasl_authenticated,reject"

postconf -X smtps/inet || true
postconf -M smtps/inet="smtps inet n - n - - smtpd"
postconf -P smtps/inet/smtpd_tls_wrappermode=yes
postconf -P smtps/inet/smtpd_sasl_auth_enable=yes
postconf -P smtps/inet/smtpd_client_restrictions="permit_sasl_authenticated,reject"

INFO "Postfix: включаю сервис и перезапускаю"
systemctl enable --now postfix
systemctl restart postfix

INFO "Postfix: virtual_*:"
postconf | egrep '^(virtual_mailbox_base|virtual_mailbox_maps|virtual_mailbox_domains|virtual_transport|virtual_uid_maps|virtual_gid_maps)'

# ждём порты до 10 сек
ok25=0 ok465=0 ok587=0
for i in {1..10}; do
  ss -ltn 2>/dev/null | grep -qE '[:.]25[[:space:]]'  && ok25=1 || true
  ss -ltn 2>/dev/null | grep -qE '[:.]465[[:space:]]' && ok465=1 || true
  ss -ltn 2>/dev/null | grep -qE '[:.]587[[:space:]]' && ok587=1 || true
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
