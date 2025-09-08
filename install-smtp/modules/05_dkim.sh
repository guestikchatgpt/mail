#!/usr/bin/env bash
# OpenDKIM — ключ 1024, конфиги, milter, экспорт TXT (склеенный p=)
# Требует окружение: DOMAIN, HOSTNAME, IPV4, (опц.) SELECTOR
# Использует хелперы из install.sh: run_cmd, log_info/log_warn/log_error

set -Eeuo pipefail
IFS=$'\n\t'
: "${DOMAIN:?}" ; : "${HOSTNAME:?}" ; : "${IPV4:?}"
: "${SELECTOR:=s1}"

KEYDIR="/etc/opendkim/keys/${DOMAIN}"
PRIV="${KEYDIR}/${SELECTOR}.private"
TXT="${KEYDIR}/${SELECTOR}.txt"
SOCK="/var/spool/postfix/opendkim/opendkim.sock"

dkim::prepare() {
  log_info "OpenDKIM: подготовка (selector=${SELECTOR}, domain=${DOMAIN})"
  run_cmd install -d -m 0750 -o opendkim -g opendkim "${KEYDIR}"
  run_cmd install -d -m 0750 -o opendkim -g postfix  "/var/spool/postfix/opendkim"
}

dkim::ensure_key() {
  if [[ ! -s "${PRIV}" || ! -s "${TXT}" ]]; then
    log_info "OpenDKIM: генерирую ключ 1024 (чтоб TXT не резался)"
    run_cmd opendkim-genkey -b 1024 -s "${SELECTOR}" -d "${DOMAIN}" -D "${KEYDIR}"
  else
    log_info "OpenDKIM: ключ уже существует — пропускаю генерацию"
  fi
  run_cmd chown opendkim:opendkim "${PRIV}" "${TXT}"
  run_cmd chmod 0600 "${PRIV}"
}

dkim::write_tables() {
  # KeyTable — file: (строгая карта)
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/KeyTable <<EOF
s1._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:${PRIV}
EOF

  # SigningTable — refile: (regex-файл), матчим всех отправителей домена
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/SigningTable <<'EOF'
^.*@heavymail\.ru$ s1._domainkey.heavymail.ru
EOF

  # TrustedHosts — считаем исходящие внутренними
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
${HOSTNAME}
${IPV4}
EOF

  run_cmd chown opendkim:opendkim /etc/opendkim/KeyTable /etc/opendkim/SigningTable /etc/opendkim/TrustedHosts
  run_cmd chmod 0644 /etc/opendkim/KeyTable /etc/opendkim/SigningTable /etc/opendkim/TrustedHosts
}

dkim::write_config() {
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim.conf <<'CONF'
Syslog                  yes
UMask                   007
UserID                  opendkim
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
Canonicalization        relaxed/simple
Mode                    sv
MinimumKeyBits          1024
KeyTable                /etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      /etc/opendkim/TrustedHosts
InternalHosts           /etc/opendkim/TrustedHosts
OversignHeaders         From
LogWhy                  yes
CONF
}

dkim::service_override() {
  run_cmd install -d -m 0755 /etc/systemd/system/opendkim.service.d
  run_cmd install -m 0644 /dev/stdin /etc/systemd/system/opendkim.service.d/override.conf <<'EOF'
[Service]
ExecStartPre=/usr/bin/install -d -m0750 -o opendkim -g postfix /var/spool/postfix/opendkim
ExecStartPre=/usr/bin/rm -f /var/spool/postfix/opendkim/opendkim.sock
ExecStart=
ExecStart=/usr/sbin/opendkim -f -x /etc/opendkim.conf -p local:/var/spool/postfix/opendkim/opendkim.sock
Type=simple
EOF
  run_cmd systemctl daemon-reload
}

dkim::enable_restart() {
  run_cmd systemctl enable --now opendkim || true
  run_cmd systemctl restart opendkim
}

dkim::attach_postfix() {
  local sock="unix:${SOCK}"
  local cur_smtpd cur_non
  cur_smtpd="$(postconf -h smtpd_milters || true)"
  cur_non="$(postconf -h non_smtpd_milters || true)"
  [[ "$cur_smtpd" != *"$sock"* ]] && run_cmd postconf -e "smtpd_milters=${cur_smtpd:+$cur_smtpd,}${sock}"
  [[ "$cur_non"  != *"$sock"* ]] && run_cmd postconf -e "non_smtpd_milters=${cur_non:+$cur_non,}${sock}"
  run_cmd postconf -e "milter_default_action=accept"
  run_cmd postconf -e "milter_protocol=6"
  run_cmd postconf -P "submission/inet/milter_macro_daemon_name=ORIGINATING"
  run_cmd postconf -P "smtps/inet/milter_macro_daemon_name=ORIGINATING"
  run_cmd systemctl reload postfix
}

dkim::export_dns_txt() {
  # Склеиваем p= из .txt: убираем кавычки/переносы/пробелы внутри base64
  run_cmd install -d -m 0755 /var/local/msa
  local pval
  pval="$(
    tr -d '\n\r\"' < "${TXT}" \
      | sed -nE 's/.*p=([A-Za-z0-9+\/= ]*).*/\1/p' \
      | tr -d ' '
  )"
  if [[ -n "${pval}" ]]; then
    printf 'v=DKIM1; k=rsa; p=%s\n' "${pval}" | run_cmd install -m 0644 /dev/stdin /var/local/msa/dkim.txt
    log_info "OpenDKIM: TXT экспортирован в /var/local/msa/dkim.txt"
  else
    log_warn "OpenDKIM: не удалось извлечь p= из ${TXT}"
  fi
}

# ---------- ENTRYPOINT ----------
dkim::prepare
dkim::ensure_key
dkim::write_tables
dkim::write_config
dkim::service_override
dkim::enable_restart
dkim::attach_postfix
dkim::export_dns_txt
