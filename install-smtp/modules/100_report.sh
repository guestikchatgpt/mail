#!/usr/bin/env bash
# Module: Final report & manifest (no yq; clean DKIM; no noise)

set -euo pipefail

# Ожидаем, что окружение уже загружено install.sh (DOMAIN, HOSTNAME, IPV4, SELECTOR?, log/run_cmd)
: "${SELECTOR:=s1}"

# --- helpers ---
port_state() {
  local p="$1"
  if ss -ltn "sport = :${p}" 2>/dev/null | grep -q LISTEN; then
    echo "open"
  else
    echo "closed"
  fi
}

# Состояния портов
P25="$(port_state 25)"
P465="$(port_state 465)"
P587="$(port_state 587)"
P993="$(port_state 993)"
P995="$(port_state 995)"

# DMARC по умолчанию (можешь переопределить переменной окружения DMARC_VALUE)
DMARC_VALUE="${DMARC_VALUE:-v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}}"

# Чистое значение DKIM
DKIM_VALUE=""
if [[ -f /var/local/msa/dkim.txt ]]; then
  DKIM_VALUE="$(tr -d '\n' </var/local/msa/dkim.txt || true)"
fi
if [[ -z "$DKIM_VALUE" && -f "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" ]]; then
  # Фоллбэк-парсер из s1.txt (удаляем кавычки/переносы и вытаскиваем содержимое скобок TXT (...))
  DKIM_VALUE="$(sed -e 's/[[:space:]]\+/ /g' -e 's/\"//g' "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" \
               | tr -d '\n' | sed -E 's/.*TXT \(([^)]*)\).*/\1/' || true)"
fi
[[ -z "$DKIM_VALUE" ]] && DKIM_VALUE="<см. ${SELECTOR}.txt в /etc/opendkim/keys/${DOMAIN}/>"

# --- report.txt ---
run_cmd install -d -m 0755 /var/local/msa
run_cmd install -m 0644 /dev/stdin /var/local/msa/report.txt <<EOF
==== DNS, которые нужно добавить сейчас ====
A     ${HOSTNAME}.                     ${IPV4}
MX    ${DOMAIN}.                       10 ${HOSTNAME}.
TXT   _dmarc.${DOMAIN}.                ${DMARC_VALUE}
TXT   ${SELECTOR}._domainkey.${DOMAIN}.  ${DKIM_VALUE}

[*] PTR/rDNS: у провайдера выставьте PTR для ${IPV4} → ${HOSTNAME}.
EOF
log INFO "Отчёт записан: /var/local/msa/report.txt"

# --- manifest.json (без yq; чистый JSON) ---
run_cmd install -m 0644 /dev/stdin /var/local/msa/manifest.json <<JSON
{
  "hostname": "${HOSTNAME}",
  "ipv4": "${IPV4}",
  "ports": {
    "25":  "${P25}",
    "465": "${P465}",
    "587": "${P587}",
    "993": "${P993}",
    "995": "${P995}"
  },
  "le": { "domain": "${HOSTNAME}" },
  "dns": { "selector": "${SELECTOR}", "DMARC": "${DMARC_VALUE}" },
  "auth": { "users_created": [] },
  "healthcheck": {}
}
JSON
log INFO "manifest.json записан в /var/local/msa/manifest.json"
