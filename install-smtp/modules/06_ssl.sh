#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../lib/log.sh"
. "$(dirname "$0")/../lib/yaml.sh"

DOMAIN="$(yq -r '.domain' "${VARS_FILE}")"
HOSTNAME="$(yq -r '.hostname' "${VARS_FILE}")"
IPV4="$(yq -r '.ipv4' "${VARS_FILE}")"
ACME_EMAIL="$(yq -r '.acme_email' "${VARS_FILE}")"

wait_a() {
  local fqdn="$1" want="$2" timeout="${3:-300}"
  log::info "Жду, пока A(${fqdn}) станет ${want} (до ${timeout} сек)"
  local t=0
  while (( t < timeout )); do
    if dig +short A "${fqdn}" @8.8.8.8 | grep -qx "${want}"; then
      log::info "A(${fqdn}) = ${want} — ок"
      return 0
    fi
    sleep 3
    t=$((t+3))
  done
  return 1
}

# ждём A(@) и A(HOSTNAME)
wait_a "${DOMAIN}" "${IPV4}" || log::warn "LE: не дождался ${DOMAIN} -> ${IPV4}"
wait_a "${HOSTNAME}" "${IPV4}" || log::warn "LE: не дождался ${HOSTNAME} -> ${IPV4}"

log::info "LE: запрашиваю сертификат для ${HOSTNAME}"
certbot certonly --standalone --preferred-challenges http \
  --non-interactive --agree-tos --no-eff-email -m "${ACME_EMAIL}" -d "${HOSTNAME}"

# хук на обновление
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
install -m 0755 /dev/stdin /etc/letsencrypt/renewal-hooks/deploy/99-reload-mail-services.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload postfix || systemctl restart postfix
systemctl reload dovecot || systemctl restart dovecot
EOF

# Dovecot TLS
install -D -m 0644 /dev/stdin /etc/dovecot/conf.d/90-msa.conf <<EOF
ssl = required
ssl_cert = </etc/letsencrypt/live/${HOSTNAME}/fullchain.pem
ssl_key  = </etc/letsencrypt/live/${HOSTNAME}/privkey.pem
EOF
systemctl enable --now dovecot
dovecot -n >/dev/null
systemctl reload dovecot || systemctl restart dovecot

# Postfix TLS (submission/465 тоже)
postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"

postconf -M submission/inet='submission inet n - n - - smtpd'
postconf -P submission/inet/smtpd_tls_security_level=encrypt
postconf -P submission/inet/smtpd_sasl_auth_enable=yes
postconf -P submission/inet/smtpd_tls_cert_file="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
postconf -P submission/inet/smtpd_tls_key_file="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"

postconf -M smtps/inet='smtps inet n - n - - smtpd'
postconf -P smtps/inet/smtpd_tls_wrappermode=yes
postconf -P smtps/inet/smtpd_sasl_auth_enable=yes
postconf -P smtps/inet/smtpd_tls_cert_file="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
postconf -P smtps/inet/smtpd_tls_key_file="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"

postfix check
systemctl reload postfix || systemctl restart postfix
