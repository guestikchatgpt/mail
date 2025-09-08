#!/usr/bin/env bash
# Module: SSL/Certbot + TLS для Postfix/Dovecot (функции + entrypoint)
set -euo pipefail

# используем общий логгер/раннер
. "$(dirname "$0")/../lib/common.sh"
: "${VARS_FILE:?}"

ssl::_yq() { yq -r "$1" "${VARS_FILE}"; }

ssl::vars() {
  DOMAIN="$(ssl::_yq '.domain')"
  HOSTNAME="$(ssl::_yq '.hostname // ("mail." + .domain)')"
  IPV4="$(ssl::_yq '.ipv4')"
  ACME_EMAIL="$(ssl::_yq '.acme_email // ("postmaster@" + .domain)')"
  : "${DOMAIN:?}"; : "${HOSTNAME:?}"; : "${IPV4:?}"; : "${ACME_EMAIL:?}"
}

ssl::wait_a() {
  local fqdn="$1" want="$2" timeout="${3:-300}"
  log_info "LE: жду A(${fqdn})=${want} (до ${timeout}s)"
  local t=0
  while (( t < timeout )); do
    if dig +short A "${fqdn}" @8.8.8.8 | grep -qx "${want}"; then
      log_info "A(${fqdn})=${want} — ок"
      return 0
    fi
    sleep 3; t=$((t+3))
  done
  log_warn "LE: таймаут ожидания A(${fqdn})=${want}"
  return 1
}

ssl::port80_busy() {
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -q '[:.]80$'
}

ssl::obtain_cert() {
  log_info "LE: запрашиваю сертификат для ${HOSTNAME}"
  if ssl::port80_busy; then
    if command -v nginx >/dev/null 2>&1; then
      run_cmd certbot --nginx --non-interactive --agree-tos --no-eff-email \
        -m "${ACME_EMAIL}" -d "${HOSTNAME}"
    elif command -v apache2 >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; then
      run_cmd certbot --apache --non-interactive --agree-tos --no-eff-email \
        -m "${ACME_EMAIL}" -d "${HOSTNAME}"
    else
      die 1 "Порт 80 занят неизвестным сервисом. Нужен nginx/apache для плагина certbot, либо освободить :80."
    fi
  else
    run_cmd certbot certonly --standalone --preferred-challenges http \
      --non-interactive --agree-tos --no-eff-email -m "${ACME_EMAIL}" -d "${HOSTNAME}"
  fi

  CRT="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
  KEY="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"
  [[ -s "$CRT" && -s "$KEY" ]] || die 1 "Сертификат не получен: ${CRT}/${KEY} отсутствуют"
}

ssl::install_deploy_hook() {
  run_cmd install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  run_cmd install -m 0755 /dev/stdin /etc/letsencrypt/renewal-hooks/deploy/99-reload-mail-services.sh <<'EOF'
#!/usr/bin/env bash
systemctl reload postfix || systemctl restart postfix
systemctl reload dovecot || systemctl restart dovecot
EOF
}

ssl::configure_dovecot() {
  run_cmd install -D -m 0644 /dev/stdin /etc/dovecot/conf.d/90-msa-tls.conf <<EOF
ssl = required
ssl_cert = </etc/letsencrypt/live/${HOSTNAME}/fullchain.pem
ssl_key  = </etc/letsencrypt/live/${HOSTNAME}/privkey.pem
EOF
  run_cmd systemctl enable --now dovecot
  run_cmd dovecot -n >/dev/null
  run_cmd systemctl reload dovecot || systemctl restart dovecot
}

ssl::configure_postfix() {
  # глобальные файлы
  run_cmd postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
  run_cmd postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"
  # per-service policy
  run_cmd postconf -P submission/inet/smtpd_tls_security_level=encrypt
  run_cmd postconf -P submission/inet/smtpd_sasl_auth_enable=yes
  run_cmd postconf -P submission/inet/smtpd_tls_cert_file="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
  run_cmd postconf -P submission/inet/smtpd_tls_key_file="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"

  run_cmd postconf -P smtps/inet/smtpd_tls_wrappermode=yes
  run_cmd postconf -P smtps/inet/smtpd_sasl_auth_enable=yes
  run_cmd postconf -P smtps/inet/smtpd_tls_cert_file="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
  run_cmd postconf -P smtps/inet/smtpd_tls_key_file="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"

  run_cmd postfix check
  run_cmd systemctl reload postfix || systemctl restart postfix
}

module::main() {
  ssl::vars
  # 02_pre_dns.sh уже должен был проставить A-записи
  ssl::wait_a "${DOMAIN}"  "${IPV4}" || true
  ssl::wait_a "${HOSTNAME}" "${IPV4}" || true
  ssl::obtain_cert
  ssl::install_deploy_hook
  ssl::configure_dovecot
  ssl::configure_postfix
  log_info "LE/TLS: завершено"
}

module::main "$@"
