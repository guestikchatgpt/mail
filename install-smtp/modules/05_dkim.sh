#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../lib/log.sh"
. "$(dirname "$0")/../lib/yaml.sh"

DOMAIN="$(yq -r '.domain' "${VARS_FILE}")"
HOSTNAME="$(yq -r '.hostname' "${VARS_FILE}")"
IPV4="$(yq -r '.ipv4' "${VARS_FILE}")"
SELECTOR="$(yq -r '.dkim_selector // "s1"' "${VARS_FILE}")"

log::info "OpenDKIM: подготовка (selector=${SELECTOR}, domain=${DOMAIN})"

install -d -m 0750 -o opendkim -g opendkim "/etc/opendkim/keys/${DOMAIN}"
install -d -m 0750 -o opendkim -g postfix /var/spool/postfix/opendkim

# 1024 чтобы TXT не резался
log::info "OpenDKIM: генерирую ключ 1024 (чтоб TXT не резался)"
opendkim-genkey -b 1024 -s "${SELECTOR}" -d "${DOMAIN}" -D "/etc/opendkim/keys/${DOMAIN}"
chown opendkim:opendkim "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private" "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt"
chmod 0600 "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private"

# Таблицы
install -D -m 0644 /dev/stdin /etc/opendkim/KeyTable <<EOF
${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private
EOF

# ВАЖНО: используем refile и нормальные regex-ы (.*@domain и @domain только доменный уровень)
install -D -m 0644 /dev/stdin /etc/opendkim/SigningTable <<'EOF'
# Любой локал-парт для домена:
^.*@heavymail\.ru$ s1._domainkey.heavymail.ru
# fallback (совпадение по доменной части):
^@heavymail\.ru$    s1._domainkey.heavymail.ru
EOF
# ↑ строка с конкретным доменом будет перезаписана ниже шаблоном под ваш DOMAIN

# Перегенерим файл под переменные (заменим heavymail.ru на реальный DOMAIN/SELECTOR)
sed -i "s/heavymail\.ru/${DOMAIN//./\\.}/g; s/s1\\./${SELECTOR}\\./g" /etc/opendkim/SigningTable

# TrustedHosts: localhost + FQDN + IP
install -D -m 0644 /dev/stdin /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
${HOSTNAME}
${IPV4}
EOF

chown opendkim:opendkim /etc/opendkim/KeyTable /etc/opendkim/SigningTable /etc/opendkim/TrustedHosts
chmod 0644 /etc/opendkim/KeyTable /etc/opendkim/SigningTable /etc/opendkim/TrustedHosts

# Конфиг OpenDKIM (главное — refile: для SigningTable)
install -D -m 0644 /dev/stdin /etc/opendkim.conf <<'EOF'
Syslog                  yes
UMask                   002
Mode                    sv
Canonicalization        relaxed/simple
Selector                default
AutoRestart             yes
AutoRestartRate         10/1h
Background              yes
DNSTimeout              5
SignatureAlgorithm      rsa-sha256

ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts

KeyTable                file:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable

Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
UserID                  opendkim:opendkim

OversignHeaders         From
EOF

# systemd override — чтобы сокет был доступен Postfix
install -d -m 0755 /etc/systemd/system/opendkim.service.d
install -m 0644 /dev/stdin /etc/systemd/system/opendkim.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/opendkim -x /etc/opendkim.conf -P /run/opendkim/opendkim.pid
EOF

systemctl daemon-reload
systemctl enable --now opendkim
systemctl restart opendkim

# Подключаем milter-ы в Postfix (оставим объединённую строку, чтобы не терять opendmarc, если он уже будет)
postconf -e "milter_default_action=accept"
postconf -e "milter_protocol=6"

# гарантируем наличие opendkim в списке (без задвоения)
current_sm="/var/tmp/.postfix.sm.$$"
postconf -h smtpd_milters >"${current_sm}" || true
if ! grep -q 'opendkim' "${current_sm}" 2>/dev/null; then
  if [[ -s "${current_sm}" ]]; then
    postconf -e "smtpd_milters=$(cat "${current_sm}"),unix:/var/spool/postfix/opendkim/opendkim.sock"
    postconf -e "non_smtpd_milters=$(postconf -h non_smtpd_milters),unix:/var/spool/postfix/opendkim/opendkim.sock"
  else
    postconf -e "smtpd_milters=unix:/var/spool/postfix/opendkim/opendkim.sock"
    postconf -e "non_smtpd_milters=unix:/var/spool/postfix/opendkim/opendkim.sock"
  fi
fi
rm -f "${current_sm}"

systemctl reload postfix || systemctl restart postfix

# Экспорт TXT для 09_beget_dns.sh
install -d -m 0755 /var/local/msa
cat "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" >/var/local/msa/dkim.txt
log::info "OpenDKIM: TXT экспортирован в /var/local/msa/dkim.txt"
