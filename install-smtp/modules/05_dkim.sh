#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

dkim::vars() {
  DOMAIN="$(yq -r '.domain' "$VARS")"
  SELECTOR="$(yq -r '.dkim_selector // "s1"' "$VARS")"
  HOSTNAME="$(yq -r '.hostname' "$VARS")"
  IPV4="$(yq -r '.ipv4' "$VARS")"
}

dkim::prepare_dirs() {
  run install -d -m 0750 -o opendkim -g opendkim "/etc/opendkim/keys/${DOMAIN}"
  run install -d -m 0750 -o opendkim -g postfix   /var/spool/postfix/opendkim
}

dkim::ensure_key() {
  local priv="/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private"
  if [[ ! -f "$priv" ]]; then
    log "OpenDKIM: генерирую ключ 1024 (чтоб TXT не резался)"
    run opendkim-genkey -b 1024 -s "$SELECTOR" -d "$DOMAIN" -D "/etc/opendkim/keys/${DOMAIN}"
    run chown opendkim:opendkim "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private" "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt"
    run chmod 0600 "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private"
  fi
}

dkim::write_tables() {
  # ключевая фиксация: используем file:, а не refile:, и явные соответствия
  printf '%s\n' \
    "${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private" \
    | run install -D -m 0644 /dev/stdin /etc/opendkim/KeyTable

  printf '%s\n' \
    "*@${DOMAIN} ${SELECTOR}._domainkey.${DOMAIN}" \
    | run install -D -m 0644 /dev/stdin /etc/opendkim/SigningTable

  printf '%s\n' \
    "127.0.0.1" "localhost" "$HOSTNAME" "$IPV4" \
    | run install -D -m 0644 /dev/stdin /etc/opendkim/TrustedHosts

  run chown opendkim:opendkim /etc/opendkim/{KeyTable,SigningTable,TrustedHosts}
  run chmod 0644 /etc/opendkim/{KeyTable,SigningTable,TrustedHosts}
}

dkim::write_conf() {
  # не рушим чужие настройки: перезаписываем только ключевые строки, но конфиг отдаём целиком,
  # чтобы гарантировать Socket + file:таблицы
  cat <<'EOF' | run install -D -m 0644 /dev/stdin /etc/opendkim.conf
Syslog                  yes
UMask                   002
Mode                    sv
AutoRestart             yes
PidFile                 /run/opendkim/opendkim.pid

Socket                  local:/var/spool/postfix/opendkim/opendkim.sock

KeyTable                file:/etc/opendkim/KeyTable
SigningTable            file:/etc/opendkim/SigningTable
InternalHosts           /etc/opendkim/TrustedHosts

Canonicalization        relaxed/simple
MinimumKeyBits          1024
Selector                default
OversignHeaders         From
TrustAnchorFile         /usr/share/dns/root.key
EOF
}

dkim::systemd_override() {
  run install -d -m 0755 /etc/systemd/system/opendkim.service.d
  cat <<'EOF' | run install -m 0644 /dev/stdin /etc/systemd/system/opendkim.service.d/override.conf
[Service]
User=opendkim
Group=opendkim
ReadWritePaths=/var/spool/postfix/opendkim
EOF
  run systemctl daemon-reload
}

dkim::wire_postfix() {
  # вплетаем milter к существующим (idempotent)
  local have; have="$(postconf -h smtpd_milters || true)"
  if [[ -z "${have// }" ]]; then
    run postconf -e "smtpd_milters=unix:/var/spool/postfix/opendkim/opendkim.sock"
  elif ! grep -q 'opendkim\.sock' <<<"$have"; then
    run postconf -e "smtpd_milters=${have},unix:/var/spool/postfix/opendkim/opendkim.sock"
  fi
  run postconf -e "non_smtpd_milters=$(postconf -h smtpd_milters)"
  run postconf -e "milter_protocol=6"
  run postconf -e "milter_default_action=accept"

  # чтобы исходящие через submission/smtps шли как ORIGINATING
  run postconf -P submission/inet/milter_macro_daemon_name=ORIGINATING
  run postconf -P smtps/inet/milter_macro_daemon_name=ORIGINATING
  run systemctl reload postfix
}

dkim::restart_and_export_txt() {
  run systemctl enable --now opendkim
  run systemctl restart opendkim

  run install -d -m 0755 /var/local/msa
  run install -m 0644 "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" /var/local/msa/dkim.txt
  log "OpenDKIM: TXT экспортирован в /var/local/msa/dkim.txt"
}

module::main() {
  dkim::vars
  log "OpenDKIM: настройка (selector=${SELECTOR}, domain=${DOMAIN})"
  dkim::prepare_dirs
  dkim::ensure_key
  dkim::write_tables
  dkim::write_conf
  dkim::systemd_override
  dkim::wire_postfix
  dkim::restart_and_export_txt
}

module::main "$@"
