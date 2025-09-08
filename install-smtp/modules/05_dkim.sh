#!/usr/bin/env bash
# OpenDKIM — ключ, конфиг, milter, чистый TXT экспорт (без пробелов в p=)
# Требует: DOMAIN, HOSTNAME, IPV4, DKIM_SELECTOR, run_cmd, log_*

set -Eeuo pipefail
IFS=$'\n\t'
: "${DKIM_SELECTOR:=s1}"

dkim::prepare_dirs() {
  log_info "OpenDKIM: подготовка (selector=${DKIM_SELECTOR}, domain=${DOMAIN})"
  run_cmd install -d -m 0750 -o opendkim -g opendkim "/etc/opendkim/keys/${DOMAIN}"
  run_cmd install -d -m 0750 -o opendkim -g postfix  "/var/spool/postfix/opendkim"
}

dkim::ensure_key() {
  local dir="/etc/opendkim/keys/${DOMAIN}"
  local key_priv="${dir}/${DKIM_SELECTOR}.private"
  local key_txt="${dir}/${DKIM_SELECTOR}.txt"
  if [[ ! -s "$key_priv" || ! -s "$key_txt" ]]; then
    log_info "OpenDKIM: генерирую ключ 2048"
    run_cmd opendkim-genkey -b 1024 -s "${DKIM_SELECTOR}" -d "${DOMAIN}" -D "${dir}"
  else
    log_info "OpenDKIM: ключ уже существует — пропуск"
  fi
  run_cmd chown opendkim:opendkim "$key_priv" "$key_txt"
  run_cmd chmod 0600 "$key_priv"
}

dkim::write_tables() {
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/KeyTable <<EOF
${DKIM_SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private
EOF
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/SigningTable <<EOF
*@${DOMAIN} ${DKIM_SELECTOR}._domainkey.${DOMAIN}
EOF
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
${HOSTNAME}
${IPV4}
EOF
}

dkim::write_config() {
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim.conf <<'CONF'
Syslog                  yes
UMask                   002
Mode                    sv
Canonicalization        relaxed/simple
AutoRestart             Yes
AutoRestartRate         10/1h
OversignHeaders         From
SubDomains              yes
UserID                  opendkim:opendkim
KeyTable                /etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
SignatureAlgorithm      rsa-sha256
MinimumKeyBits          1024
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

dkim::enable_service() {
  run_cmd systemctl enable --now opendkim || true
  run_cmd systemctl restart opendkim
}

dkim::attach_milter() {
  local sock="unix:/var/spool/postfix/opendkim/opendkim.sock"
  local cur_smtpd; cur_smtpd="$(postconf -h smtpd_milters || true)"
  local cur_non;   cur_non="$(postconf -h non_smtpd_milters || true)"

  if [[ "${cur_smtpd}" != *"${sock}"* ]]; then
    [[ -n "${cur_smtpd}" ]] && run_cmd postconf -e "smtpd_milters=${cur_smtpd},${sock}" \
                           || run_cmd postconf -e "smtpd_milters=${sock}"
  else
    log_info "OpenDKIM: smtpd_milters уже содержит ${sock}"
  fi
  if [[ "${cur_non}" != *"${sock}"* ]]; then
    [[ -n "${cur_non}" ]] && run_cmd postconf -e "non_smtpd_milters=${cur_non},${sock}" \
                          || run_cmd postconf -e "non_smtpd_milters=${sock}"
  else
    log_info "OpenDKIM: non_smtpd_milters уже содержит ${sock}"
  fi

  run_cmd postconf -e "milter_default_action=accept"
  run_cmd postconf -e "milter_protocol=6"

  # КРИТИЧНО: корректные кавычки у postconf -P
  run_cmd postconf -P "submission/inet/milter_macro_daemon_name=ORIGINATING"
  run_cmd postconf -P "smtps/inet/milter_macro_daemon_name=ORIGINATING"

  run_cmd systemctl reload postfix
}

# Экспорт аккуратного TXT: "v=DKIM1; k=rsa; p=<BASE64>" без пробелов внутри p=
dkim::export_clean_txt() {
  local txt_file="/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.txt"
  local out_file="/var/local/msa/dkim.txt"
  run_cmd install -d -m 0755 /var/local/msa

  if [[ ! -f "$txt_file" ]]; then
    log_warn "OpenDKIM: не найден исходный TXT-файл ключа: ${txt_file}"
    return 1
  fi

  # Надёжный парсинг p=... из файла.
  # 1. Находим строку с p=
  # 2. Удаляем всё до p=
  # 3. Удаляем весь мусор: кавычки, скобки, пробелы, переносы строк.
  # 4. Склеиваем в одну строку.
  local p_val
  p_val="$(grep -o 'p=[^)]*' "$txt_file" | sed 's/p=//' | tr -d '"()[:space:]')"

  if [[ -n "${p_val}" ]]; then
    printf 'v=DKIM1; k=rsa; p=%s\n' "${p_val}" | run_cmd install -m 0644 /dev/stdin "${out_file}"
    log_info "OpenDKIM: TXT-запись для DNS экспортирована в ${out_file}"
    # Экспортируем переменную для использования в других модулях (например, 100_report)
    export DKIM_DNS_TXT="v=DKIM1; k=rsa; p=${p_val}"
  else
    log_warn "OpenDKIM: не удалось извлечь p=... из ${txt_file}"
  fi
}

# --- run ---
dkim::prepare_dirs
dkim::ensure_key
dkim::write_tables
dkim::write_config
dkim::service_override
dkim::enable_service
dkim::attach_milter
dkim::export_clean_txt
