#!/usr/bin/env bash
# Module: Финальный отчёт (ТОЛЬКО report.txt; manifest.json не трогаем)
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"
: "${VARS_FILE:?}"

report::_yq(){ yq -r "$1" "${VARS_FILE}"; }

report::vars() {
  DOMAIN="$(report::_yq '.domain')"
  HOSTNAME="$(report::_yq '.hostname // ("mail." + .domain)')"
  IPV4="$(report::_yq '.ipv4')"
  SELECTOR="$(report::_yq '.dkim_selector // "s1"')"
}

report::port_state() {
  local p="$1"
  if ss -ltn 2>/dev/null | grep -q "[:.]${p}[[:space:]]"; then
    echo "open"; else echo "closed"; fi
}

report::dkim_value() {
  local v=""
  if [[ -f /var/local/msa/dkim.txt ]]; then
    v="$(tr -d '\n' </var/local/msa/dkim.txt || true)"
  fi
  if [[ -z "$v" && -f "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" ]]; then
    v="$(sed -e 's/[[:space:]]\+/ /g' -e 's/\"//g' "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" \
       | tr -d '\n' | sed -E 's/.*TXT \(([^)]*)\).*/\1/' || true)"
  fi
  [[ -n "$v" ]] && printf '%s' "$v" || printf '<см. %s.txt в /etc/opendkim/keys/%s/>' "$SELECTOR" "$DOMAIN"
}

report::write() {
  local P25 P465 P587 P993 P995 DKIM_VALUE DMARC_VALUE
  P25="$(report::port_state 25)"
  P465="$(report::port_state 465)"
  P587="$(report::port_state 587)"
  P993="$(report::port_state 993)"
  P995="$(report::port_state 995)"
  DKIM_VALUE="$(report::dkim_value)"
  DMARC_VALUE="${DMARC_VALUE:-v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}}"

  run_cmd install -d -m 0755 /var/local/msa
  run_cmd install -m 0644 /dev/stdin /var/local/msa/report.txt <<EOF
==== DNS, которые нужно добавить ====
A     ${HOSTNAME}.                     ${IPV4}
MX    ${DOMAIN}.                       10 ${HOSTNAME}.
TXT   _dmarc.${DOMAIN}.                ${DMARC_VALUE}
TXT   ${SELECTOR}._domainkey.${DOMAIN}.  ${DKIM_VALUE}

[*] PTR/rDNS: у провайдера выставьте PTR для ${IPV4} → ${HOSTNAME}.

==== Порты (локальный LISTEN) ====
25=${P25}, 465=${P465}, 587=${P587}, 993=${P993}, 995=${P995}
EOF
  log_info "Отчёт записан: /var/local/msa/report.txt"
}

module::main() { report::vars; report::write; }
module::main "$@"
