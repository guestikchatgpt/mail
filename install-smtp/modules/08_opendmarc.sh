# modules/08_opendmarc.sh — DMARC verify для входящих писем
# Требует: run_cmd, log_*, require_cmd, HOSTNAME
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

opendmarc::paths() {
  ODM_CONF="/etc/opendmarc.conf"
  ODM_SOCKET_DIR="/var/spool/postfix/opendmarc"
  ODM_SOCKET="local:${ODM_SOCKET_DIR}/opendmarc.sock"
}

opendmarc::write_conf() {
  opendmarc::paths
  local tmp; tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Managed by msa-install — DO NOT EDIT
AuthservID                  ${HOSTNAME}
TrustedAuthservIDs          ${HOSTNAME}
Socket                      ${ODM_SOCKET}
UMask                       007
Syslog                      true
RejectFailures              false
IgnoreAuthenticatedClients  true
EOF
  run_cmd "install -m 0644 '${tmp}' '${ODM_CONF}'"
  rm -f "$tmp"
  run_cmd "install -d -m 0750 -o opendmarc -g postfix '${ODM_SOCKET_DIR}'"
}

opendmarc::configure_postfix() {
  opendmarc::paths
  require_cmd postconf
  local sock="unix:${ODM_SOCKET_DIR}/opendmarc.sock"
  local cur new

  cur="$(postconf -h smtpd_milters || true)"
  if [[ -z "${cur}" ]]; then new="${sock}"
  elif grep -q "${sock//\//\\/}" <<<"$cur"; then new="${cur}"
  else new="${cur},${sock}"; fi
  run_cmd "postconf -e 'smtpd_milters=${new}'"

  cur="$(postconf -h non_smtpd_milters || true)"
  if [[ -z "${cur}" ]]; then new="${sock}"
  elif grep -q "${sock//\//\\/}" <<<"$cur"; then new="${cur}"
  else new="${cur},${sock}"; fi
  run_cmd "postconf -e 'non_smtpd_milters=${new}'"

  run_cmd "postconf -e 'milter_default_action=accept'"
  run_cmd "postconf -e 'milter_protocol=6'"
}

opendmarc::reload_enable() {
  run_cmd "systemctl enable --now opendmarc"
  run_cmd "systemctl restart opendmarc"
  run_cmd "systemctl reload postfix || systemctl restart postfix"
}

# --- ENTRYPOINT ---
require_cmd opendmarc
opendmarc::write_conf
opendmarc::configure_postfix
opendmarc::reload_enable
