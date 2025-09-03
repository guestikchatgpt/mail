#!/usr/bin/env bash
# Итоговый текстовый отчёт
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

# мини-лог/ран (на случай автономного запуска)
if [[ "$(type -t log 2>/dev/null)" != "function" ]]; then
  log(){ printf '[%(%FT%TZ)T] [%s] %s\n' -1 "${1:-INFO}" "${*:2}"; }
fi
if [[ "$(type -t run 2>/dev/null)" != "function" ]]; then
  run(){ log INFO "RUN: $*"; "$@"; }
fi

VARS_FILE="${VARS_FILE:-${1:-vars.yaml}}"

# yq (мягкая установка при отсутствии)
if ! command -v yq >/dev/null 2>&1; then
  log WARN "yq не найден — пытаюсь скачать бинарь в /usr/local/bin/yq"
  run bash -c 'curl -fsSL -o /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x /usr/local/bin/yq' || true
fi

DOMAIN="$(yq -r '.domain // ""' "$VARS_FILE" 2>/dev/null || echo '')"
HOSTNAME="$(yq -r '.hostname // ( .domain | select(.!=null) | "mail."+.)' "$VARS_FILE" 2>/dev/null || echo '')"
IPV4="$(yq -r '.ipv4 // ""' "$VARS_FILE" 2>/dev/null || echo '')"
SELECTOR="$(yq -r '.dkim_selector // "s1"' "$VARS_FILE" 2>/dev/null || echo 's1')"

OUT_DIR="/var/local/msa"
REPORT_TXT="${OUT_DIR}/report.txt"
REPORT_MD="${OUT_DIR}/report.md"
run install -d -m 0755 "$OUT_DIR"

# версии ПО, состояние портов, сроки TLS и т.д. — как у тебя было …
POSTFIX_VER="$(postconf -h mail_version 2>/dev/null || echo n/a)"
DOVECOT_VER="$(dovecot --version 2>/dev/null || echo n/a)"
OPENDKIM_VER="$(opendkim -V 2>&1 | awk 'NR==1{print $3}' 2>/dev/null || echo n/a)"
OPENDMARC_VER="$(opendmarc -V 2>&1 | awk 'NR==1{print $3}' 2>/dev/null || echo n/a)"
FAIL2BAN_VER="$(fail2ban-client -V 2>&1 | awk '{print $2; exit}' 2>/dev/null || echo n/a)"
CERTBOT_VER="$(certbot --version 2>/dev/null | awk '{print $2}' || echo n/a)"

pstate() { local port="$1"; if ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q LISTEN; then echo "open"; else echo "closed"; fi; }
PORT25="$(pstate 25)"; PORT465="$(pstate 465)"; PORT587="$(pstate 587)"; PORT993="$(pstate 993)"; PORT995="$(pstate 995)"

LE_DIR="/etc/letsencrypt/live/${HOSTNAME}"
TLS_FROM="n/a"; TLS_TO="n/a"
if [[ -r "${LE_DIR}/fullchain.pem" ]]; then
  TLS_FROM="$(openssl x509 -in "${LE_DIR}/fullchain.pem" -noout -startdate 2>/dev/null | sed 's/notBefore=//')"
  TLS_TO="$(openssl x509 -in "${LE_DIR}/fullchain.pem" -noout -enddate   2>/dev/null | sed 's/notAfter=//')"
fi

declare -a _users_raw=(); declare -a _users_norm=()
if [[ -r /etc/dovecot/passdb/users ]]; then
  mapfile -t _users_raw < <(cut -d: -f1 /etc/dovecot/passdb/users | sed '/^$/d' | sort -u)
fi
if ((${#_users_raw[@]})); then
  for u in "${_users_raw[@]}"; do
    if [[ "$u" == *"@"* ]]; then _users_norm+=( "$u" ); else _users_norm+=( "$u@$DOMAIN" ); fi
  done
fi
USERS_SECTION="нет данных"
if ((${#_users_norm[@]})); then USERS_SECTION=$(for e in "${/_users_norm[@]}"; do echo "  - $e"; done); fi

DMARC_RUA_ADDR="postmaster@${DOMAIN}"
if ((${#_users_norm[@]})); then DMARC_RUA_ADDR="${_users_norm[0]}"; fi

A_CURRENT="$(dig +short A "$HOSTNAME" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
have_A=no; if [[ -n "$IPV4" && -n "$A_CURRENT" ]] && grep -qw "$IPV4" <<<"$A_CURRENT"; then have_A=yes; fi
MX_TARGETS="$(dig +short MX "$DOMAIN" 2>/dev/null | awk '{print $2}' | sed 's/\.$//' | tr '\n' ' ')"
have_MX=no; if [[ -n "$MX_TARGETS" ]] && grep -qw "$HOSTNAME" <<<"$MX_TARGETS"; then have_MX=yes; fi
SPF_PRESENT="$(dig +short TXT "$DOMAIN" 2>/dev/null | grep -i 'v=spf1' || true)"
DMARC_PRESENT="$(dig +short TXT "_dmarc.${DOMAIN}" 2>/dev/null | grep -i 'v=DMARC1' || true)"
DKIM_PRESENT="$(dig +short TXT "${SELECTOR}._domainkey.${DOMAIN}" 2>/dev/null | grep -i 'v=DKIM1' || true)"
DKIM_UI_VALUE=""
if [[ -s "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" ]]; then
  pub="$(tr -d '\n\"' < "/etc/opendkim/keys/${DOMAIN}/${SELECTOR}.txt" | sed -E 's/^[^p]*p=([^; )]+).*/\1/' | tr -d '[:space:]')"
  [[ -n "$pub" ]] && DKIM_UI_VALUE="v=DKIM1; h=sha256; k=rsa; p=${pub}"
fi

PTR_HOST="$(dig +short -x "$IPV4" 2>/dev/null | sed 's/\.$//' | head -n1 || true)"
HELO_PTR_STATUS="ok"
if [[ -z "$PTR_HOST" || "$PTR_HOST" != "$HOSTNAME" ]]; then
  HELO_PTR_STATUS="mismatch (PTR: ${PTR_HOST:-<none>}, HELO: ${HOSTNAME})"
fi

DNS_LINES=()
if [[ "$have_A" != "yes" && -n "$IPV4" ]]; then DNS_LINES+=( "A     ${HOSTNAME}.           ${IPV4}" ); fi
if [[ "$have_MX" != "yes" ]]; then        DNS_LINES+=( "MX    ${DOMAIN}.          10 ${HOSTNAME}." ); fi
if [[ -n "$SPF_PRESENT" ]]; then          DNS_LINES+=( "SPF уже есть: ${SPF_PRESENT}" ); else DNS_LINES+=( "TXT   ${DOMAIN}.          v=spf1 mx -all" ); fi
if [[ -n "$DMARC_PRESENT" ]]; then        DNS_LINES+=( "DMARC уже есть: ${DMARC_PRESENT}" ); else DNS_LINES+=( "TXT   _dmarc.${DOMAIN}.   v=DMARC1; p=none; rua=mailto:${DMARC_RUA_ADDR}" ); fi
if [[ -n "$DKIM_PRESENT" ]]; then         DNS_LINES+=( "DKIM уже есть (${SELECTOR}): ${DKIM_PRESENT}" ); elif [[ -n "$DKIM_UI_VALUE" ]]; then DNS_LINES+=( "TXT   ${SELECTOR}._domainkey.${DOMAIN}.  ${DKIM_UI_VALUE}" ); fi

# --- отчёт plain-text (и копия в .md) ---
{
  echo "ОТЧЁТ ОБ УСТАНОВКЕ ПОЧТОВОГО СЕРВЕРА"
  echo
  echo "Узел:"
  echo "  Хостнейм: ${HOSTNAME}"
  echo "  Внешний IP: ${IPV4}"
  echo "  Домен: ${DOMAIN}"
  echo
  echo "Версии ПО:"
  echo "  Postfix:   ${POSTFIX_VER}"
  echo "  Dovecot:   ${DOVECOT_VER}"
  echo "  OpenDKIM:  ${OPENDKIM_VER}"
  echo "  OpenDMARC: ${OPENDMARC_VER}"
  echo "  Fail2ban:  ${FAIL2BAN_VER}"
  echo "  Certbot:   ${CERTBOT_VER}"
  echo
  echo "Службы и порты:"
  echo "  25  (SMTP):   ${PORT25}"
  echo "  465 (SMTPS):  ${PORT465}"
  echo "  587 (SUBM):   ${PORT587}"
  echo "  993 (IMAPS):  ${PORT993}"
  echo "  995 (POPS):   ${PORT995}"
  echo
  echo "Сертификат TLS (Let's Encrypt):"
  echo "  Действует с:  ${TLS_FROM}"
  echo "  Действует до: ${TLS_TO}"
  echo
  echo "Пользователи (созданы):"
  printf '%s\n' "${USERS_SECTION}"
  echo
  echo "Рекомендованные DNS записи:"
  for l in "${DNS_LINES[@]}"; do echo "  ${l}"; done
  echo
  echo "Дополнительно:"
  echo "  PTR/HELO: ${HELO_PTR_STATUS}"
  echo
  echo "Где искать файлы:"
  echo "  Манифест JSON: ${OUT_DIR}/manifest.json"
  echo "  Отчёт (txt):   ${REPORT_TXT}"
  echo "  Отчёт (md):    ${REPORT_MD}"
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "  Логи установки: ${LOG_FILE}"
  else
    echo "  Логи установки: /var/log/msa/"
  fi
  echo "  Логи почты:     /var/log/mail.log"
} > "$REPORT_TXT"

cp -f "$REPORT_TXT" "$REPORT_MD"
log INFO "Отчёт записан: $REPORT_TXT"

echo
echo "==== DNS, которые нужно добавить сейчас ===="
added_any=no
if [[ "$have_A" != "yes" && -n "$IPV4" ]]; then echo "A     ${HOSTNAME}.    ${IPV4}"; added_any=yes; fi
if [[ "$have_MX" != "yes" ]]; then echo "MX    ${DOMAIN}.      10 ${HOSTNAME}."; added_any=yes; fi
if [[ -z "$SPF_PRESENT" ]]; then echo "TXT   ${DOMAIN}.      v=spf1 mx -all"; added_any=yes; fi
if [[ -z "$DMARC_PRESENT" ]]; then echo "TXT   _dmarc.${DOMAIN}.  v=DMARC1; p=none; rua=mailto:${DMARC_RUA_ADDR}"; added_any=yes; fi
if [[ -z "$DKIM_PRESENT" && -n "$DKIM_UI_VALUE" ]]; then echo "TXT   ${SELECTOR}._domainkey.${DOMAIN}.  ${DKIM_UI_VALUE}"; added_any=yes; fi
[[ "$added_any" == "yes" ]] || echo "Ничего — базовые записи уже на месте."
echo "Полный отчёт: $REPORT_TXT"
