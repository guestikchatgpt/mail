#!/usr/bin/env bash
# Module: OpenDKIM — keys, config, milter, clean TXT export + systemd override

set -euo pipefail
: "${SELECTOR:=s1}"

dkim::prepare_dirs() {
  log INFO "OpenDKIM: подготовка ключей (selector=${SELECTOR}, domain=${DOMAIN})"
  run_cmd install -d -m 0750 -o opendkim -g opendkim "/etc/opendkim/keys/${DOMAIN}"
  run_cmd install -d -m 0750 -o opendkim -g postfix "/var/spool/postfix/opendkim"
}

dkim::ensure_key() {
  local key_priv="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private"
  local key_txt="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt"
  if [[ ! -s "$key_priv" || ! -s "$key_txt" ]]; then
    log INFO "OpenDKIM: генерирую 2048-бит ключ (впервые)"
    run_cmd opendkim-genkey -b 2048 -s "${SELECTOR}" -d "${DOMAIN}" -D "/etc/opendkim/keys/${DOMAIN}"
  else
    log INFO "OpenDKIM: ключ уже существует (${SELECTOR} @ ${DOMAIN}) — пропускаю генерацию"
  fi
  run_cmd chown opendkim:opendkim "$key_priv" "$key_txt"
  run_cmd chmod 0600 "$key_priv"
}

dkim::write_tables() {
  log INFO "OpenDKIM: пишу KeyTable/SigningTable/TrustedHosts"
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/KeyTable <<EOF
${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private
EOF
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/SigningTable <<EOF
*@${DOMAIN} ${SELECTOR}._domainkey.${DOMAIN}
EOF
  run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
${HOSTNAME}
${IPV4}
EOF
}

dkim::write_config() {
  log INFO "OpenDKIM: пишу конфигурацию (socket=/var/spool/postfix/opendkim/opendkim.sock)"
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
SigningTable            /etc/opendkim/SigningTable
ExternalIgnoreList      /etc/opendkim/TrustedHosts
InternalHosts           /etc/opendkim/TrustedHosts
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
SignatureAlgorithm      rsa-sha256
MinimumKeyBits          1024
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
    log INFO "OpenDKIM: smtpd_milters уже содержит ${sock}"
  fi

  if [[ "${cur_non}" != *"${sock}"* ]]; then
    [[ -n "${cur_non}" ]] && run_cmd postconf -e "non_smtpd_milters=${cur_non},${sock}" \
                          || run_cmd postconf -e "non_smtpd_milters=${sock}"
  else
    log INFO "OpenDKIM: non_smtpd_milters уже содержит ${sock}"
  fi

  run_cmd postconf -e "milter_default_action=accept"
  run_cmd postconf -e "milter_protocol=6"
  run_cmd systemctl reload postfix
}

dkim::export_clean_txt() {
  local txt="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt"
  local out="/var/local/msa/dkim.txt"
  run_cmd install -d -m 0755 /var/local/msa

  local value
  value="$(sed -e 's/[[:space:]]\+/ /g' -e 's/\"//g' "$txt" | tr -d '\n' | sed -E 's/.*TXT \(([^)]*)\).*/\1/')" || value=""
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value" | run_cmd install -m 0644 /dev/stdin "$out"
    log INFO "OpenDKIM: чистое значение для DNS записано в $out"
  else
    log WARN "OpenDKIM: не удалось распарсить ${txt} — проверь файл"
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
