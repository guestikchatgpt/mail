#!/usr/bin/env bash
# Module: Postfix base config + TLS hardening + services (25/465/587)
# Uses env: DOMAIN, HOSTNAME, IPV4, ACCEPT_INBOUND

set -Eeuo pipefail
IFS=$'\n\t'

postfix::write_mailname() {
  # В install.sh мы используем log_info, а здесь старый log INFO. Приводим к одному виду.
  if [[ -n "${HOSTNAME:-}" ]]; then
    log_info "Пишу /etc/mailname = ${HOSTNAME}"
    printf '%s\n' "$HOSTNAME" | run_cmd tee /etc/mailname >/dev/null
  fi
}

postfix::base_config() {
  log_info "Postfix: базовая конфигурация и TLS-жёсткость (TLS1.2+)"
  run_cmd postconf -e \
    "myhostname=${HOSTNAME}" \
    "myorigin=${DOMAIN}" \
    "inet_interfaces=all" \
    "inet_protocols=ipv4" \
    "smtp_address_preference=ipv4" \
    "smtp_bind_address=${IPV4}" \
    "smtpd_banner=\$myhostname ESMTP" \
    "smtpd_sasl_type=dovecot" \
    "smtpd_sasl_path=private/auth" \
    "smtpd_sasl_auth_enable=yes" \
    "smtpd_recipient_restrictions=permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination" \
    "mynetworks=127.0.0.0/8" \
    "smtpd_tls_auth_only=yes" \
    "smtpd_tls_security_level=may" \
    "smtp_tls_security_level=may" \
    "smtpd_tls_protocols=!SSLv2, !SSLv3, !TLSv1, !TLSv1.1" \
    "smtp_tls_protocols=!SSLv2, !SSLv3, !TLSv1, !TLSv1.1" \
    "tls_preempt_cipherlist=yes" \
    "smtpd_tls_ciphers=high" \
    "smtp_tls_ciphers=high" \
    "smtpd_tls_mandatory_ciphers=high"
}

postfix::virtual_maps() {
  # Карта алиасов для «почтовых ящиков» (минимальная заглушка — чтобы postmap не падал)
  local map=/etc/postfix/virtual_mailbox_maps
  [[ -f "$map" ]] || printf '# filled by installer\n' | run_cmd install -m 0644 /dev/stdin "$map"
  run_cmd postmap "hash:${map}"
  run_cmd postconf -e "virtual_mailbox_maps=hash:${map}"
}

postfix::services() {
  log_info "Postfix: настраиваю master.cf для smtp(25), submission(587), smtps(465) и отключаю chroot для milter'ов"

  # Основной SMTP (25)
  # Пятый параметр ('chroot') ставим в 'n' (no), чтобы Postfix видел сокеты milter'ов
  run_cmd postconf -M "smtp/inet=smtp inet n - n - - smtpd"

  # Submission (587) — STARTTLS обязателен
  # Пятый параметр ('chroot') также ставим в 'n'
  run_cmd postconf -M "submission/inet=submission inet n - n - - smtpd"
  run_cmd postconf -P "submission/inet/smtpd_tls_security_level=encrypt"
  run_cmd postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
  run_cmd postconf -P "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"

  # SMTPS (465) — TLS wrapper
  # Пятый параметр ('chroot') также ставим в 'n'
  run_cmd postconf -M "smtps/inet=smtps inet n - n - - smtpd"
  run_cmd postconf -P "smtps/inet/smtpd_tls_wrappermode=yes"
  run_cmd postconf -P "smtps/inet/smtpd_sasl_auth_enable=yes"
  run_cmd postconf -P "smtps/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"

  # LE-сертификаты (если уже есть — прописываем сразу; если нет, модуль 06_ssl повторно задаст)
  local cert="/etc/letsencrypt/live/${HOSTNAME}/fullchain.pem"
  local key="/etc/letsencrypt/live/${HOSTNAME}/privkey.pem"
  if [[ -s "$cert" && -s "$key" ]]; then
    run_cmd postconf -P "submission/inet/smtpd_tls_cert_file=${cert}"
    run_cmd postconf -P "submission/inet/smtpd_tls_key_file=${key}"
    run_cmd postconf -P "smtps/inet/smtpd_tls_cert_file=${cert}"
    run_cmd postconf -P "smtps/inet/smtpd_tls_key_file=${key}"
  else
    log_warn "Postfix: LE-сертификат отсутствует — активирую TLS позднее (модуль 06_ssl)"
  fi
}

postfix::reload() {
  run_cmd postfix check
  run_cmd systemctl enable --now postfix
  run_cmd bash -c "systemctl reload postfix || systemctl restart postfix"
  # Мини-проверка
  if ss -ltn '( sport = :25 or sport = :465 or sport = :587 )' | grep -q LISTEN; then
    log_info "Postfix: 25/465/587 — LISTEN"
  else
    # Добавим осмысленную ошибку, если Postfix так и не запустился
    log_error "Postfix: После перезапуска ни один из портов (25, 465, 587) не слушается. Проверяй `journalctl -u postfix`"
  fi
}

# --- run ---
postfix::write_mailname
postfix::base_config
postfix::virtual_maps
postfix::services
postfix::reload
