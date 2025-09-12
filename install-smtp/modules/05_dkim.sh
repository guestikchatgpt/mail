#!/usr/bin/env bash
# Module 05_dkim.sh — OpenDKIM: ключи, таблицы, конфиг, systemd-override, интеграция с Postfix
set -Eeuo pipefail
IFS=$'\n\t'

# ----- SAFE DEFAULTS (чтобы set -u не падал до инициализации путей) -----
: "${DKIM_SOCK_POSTFIX_INBOUND:=unix:/opendkim/opendkim.sock}"                 # для chroot=y (порт 25)
: "${DKIM_SOCK_POSTFIX_MSA:=unix:/var/spool/postfix/opendkim/opendkim.sock}"   # для chroot=n (587/465 и non_smtpd)

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"
: "${VARS_FILE:?}"

dkim::_yq() { yq -r "$1" "${VARS_FILE}"; }

dkim::vars() {
  DOMAIN="$(dkim::_yq '.domain')"
  SELECTOR="$(dkim::_yq '.dkim_selector // "s1"')"
  HOSTNAME="$(dkim::_yq '.hostname // ("mail." + .domain)')"
  IPV4="$(dkim::_yq '.ipv4')"

  # Демон слушает абсолютный путь (вне chroot Postfix):
  DKIM_SOCK_DAEMON="local:/var/spool/postfix/opendkim/opendkim.sock"
  # Пути, которыми Postfix будет обращаться к milter:
  DKIM_SOCK_POSTFIX_INBOUND="unix:/opendkim/opendkim.sock"                       # 25/tcp (chroot=y)
  DKIM_SOCK_POSTFIX_MSA="unix:/var/spool/postfix/opendkim/opendkim.sock"         # 587/465 + non_smtpd (chroot=n)

  : "${DOMAIN:?}"; : "${SELECTOR:?}"; : "${HOSTNAME:?}"; : "${IPV4:?}"
}

dkim::prepare_dirs() {
  run_cmd install -d -m 0750 -o opendkim -g opendkim "/etc/opendkim/keys/${DOMAIN}"
  run_cmd install -d -m 0750 -o opendkim -g postfix /var/spool/postfix/opendkim
}

dkim::ensure_key() {
  local dir="/etc/opendkim/keys/${DOMAIN}"
  local priv="${dir}/${SELECTOR}.private"
  if [[ ! -f "$priv" ]]; then
    log_info "OpenDKIM: генерирую ключ 1024 бит (совместимо с большинством DNS панелей)"
    run_cmd opendkim-genkey -b 1024 -s "${SELECTOR}" -d "${DOMAIN}" -D "${dir}"
    run_cmd chown opendkim:opendkim "${dir}/${SELECTOR}.private" "${dir}/${SELECTOR}.txt"
    run_cmd chmod 0600 "${dir}/${SELECTOR}.private"
  fi
}

dkim::write_tables() {
  # KeyTable
  printf '%s\n' \
    "${DOMAIN} ${DOMAIN}:${SELECTOR}:/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.private" \
    | run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/KeyTable

  # SigningTable
  {
    printf '%s\t%s\n' "info@${DOMAIN}" "${DOMAIN}"
    printf '%s\t%s\n' "@${DOMAIN}"      "${DOMAIN}"
    printf '%s\t%s\n' "${DOMAIN}"       "${DOMAIN}"
  } | run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/SigningTable

  # TrustedHosts
  printf '%s\n' "127.0.0.1" "::1" "localhost" "${HOSTNAME}" "${IPV4}" \
    | run_cmd install -D -m 0644 /dev/stdin /etc/opendkim/TrustedHosts

  run_cmd chown opendkim:opendkim /etc/opendkim/{KeyTable,SigningTable,TrustedHosts}
  run_cmd chmod 0644 /etc/opendkim/{KeyTable,SigningTable,TrustedHosts}
}

dkim::write_conf() {
  cat <<EOF | run_cmd install -D -m 0644 /dev/stdin /etc/opendkim.conf
Syslog                  yes
LogWhy                  yes
UMask                   007
Mode                    sv
AutoRestart             yes
PidFile                 /run/opendkim/opendkim.pid

Socket                  ${DKIM_SOCK_DAEMON}
UserID                  opendkim:postfix

KeyTable                file:/etc/opendkim/KeyTable
SigningTable            file:/etc/opendkim/SigningTable
InternalHosts           /etc/opendkim/TrustedHosts
ExternalIgnoreList      /etc/opendkim/TrustedHosts

Canonicalization        relaxed/relaxed
MinimumKeyBits          1024
OversignHeaders         From
TrustAnchorFile         /usr/share/dns/root.key
EOF
}

dkim::systemd_override() {
  run_cmd install -d -m 0755 /etc/systemd/system/opendkim.service.d
  cat <<'EOF' | run_cmd install -m 0644 /dev/stdin /etc/systemd/system/opendkim.service.d/override.conf
[Service]
User=opendkim
Group=postfix
UMask=007
ReadWritePaths=/var/spool/postfix/opendkim
ExecStart=
ExecStart=/usr/sbin/opendkim -x /etc/opendkim.conf -P /run/opendkim/opendkim.pid -u opendkim -l
EOF
  run_cmd systemctl daemon-reload
}

dkim::wire_postfix() {
  run_cmd postconf -e "milter_protocol=6"
  run_cmd postconf -e "milter_default_action=accept"

  # 25/tcp (входящий): добавить DKIM verify (chroot-путь)
  local cur
  cur="$(postconf -h smtpd_milters || true)"
  [[ "$cur" == *"/opendkim/opendkim.sock"* ]] || \
    run_cmd postconf -e "smtpd_milters=${cur:+$cur,}${DKIM_SOCK_POSTFIX_INBOUND}"

  # Локальная отправка (pickup/cleanup): ставим подпись DKIM (absolute, non-chroot)
  run_cmd postconf -e "non_smtpd_milters=${DKIM_SOCK_POSTFIX_MSA}"

  # MSA 587/465 (исходящая с AUTH): подпись DKIM (absolute, non-chroot)
  run_cmd postconf -P "submission/inet/milter_macro_daemon_name=ORIGINATING"
  run_cmd postconf -P "smtps/inet/milter_macro_daemon_name=ORIGINATING"
  run_cmd postconf -P "submission/inet/smtpd_milters=${DKIM_SOCK_POSTFIX_MSA}"
  run_cmd postconf -P "smtps/inet/smtpd_milters=${DKIM_SOCK_POSTFIX_MSA}"

  run_cmd systemctl reload postfix || run_cmd systemctl restart postfix
}

dkim::restart_and_export_txt() {
  run_cmd systemctl enable --now opendkim
  run_cmd systemctl restart opendkim

  run_cmd install -d -m 0755 /var/local/msa
  run_cmd install -m 0644 "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" /var/local/msa/dkim.txt
  log_info "OpenDKIM: TXT экспортирован в /var/local/msa/dkim.txt (публикуй как ${SELECTOR}._domainkey.${DOMAIN})"
}

dkim::sanity() {
  # доступ Postfix к сокету
  sudo -u postfix test -r /var/spool/postfix/opendkim/opendkim.sock || {
    log_error "postfix не имеет доступа к opendkim.sock"
    exit 1
  }
  # быстрый смок по логам
  if journalctl -u opendkim --since -5min 2>/dev/null | grep -qi 'no signing table match'; then
    log_error "OpenDKIM: обнаружен 'no signing table match' за последние 5 минут"
    exit 1
  fi
  log_info "OpenDKIM sanity ok"
}

module::main() {
  dkim::vars
  log_info "OpenDKIM: настройка (selector=${SELECTOR}, domain=${DOMAIN})"
  dkim::prepare_dirs
  dkim::ensure_key
  dkim::write_tables
  dkim::write_conf
  dkim::systemd_override
  dkim::wire_postfix
  dkim::restart_and_export_txt
  dkim::sanity
  log_info "OpenDKIM готов. Проверка: opendkim-testkey -d ${DOMAIN} -s ${SELECTOR} -vvv"
}
module::main "$@"
