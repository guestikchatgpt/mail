#!/usr/bin/env bash
# 09_beget_dns.sh — авто-деплой DNS в Beget из vars.yaml
# - только vars.yaml (никаких .env)
# - dry-run (--dry-run или dns_update.dry_run)
# - бережные изменения per-FQDN через changeRecords
# - пост-верификация A и MX
# Требует: curl, dig, jq, yq

set -Eeuo pipefail

# ====== ЛОГИ/ТРАП ======
ts(){ date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log(){ echo "[$(ts)] [$1] $2"; }
INFO(){ log INFO "$*"; }
WARN(){ log WARN "$*"; }
ERR(){ log ERROR "$*"; }
trap 'ERR "Ошибка на линии $LINENO: \"$BASH_COMMAND\""; exit 1' ERR

# ====== ПАРАМЕТРЫ И УТИЛИТЫ ======
VARS_FILE="${VARS_FILE:-vars.yaml}"

need_bin(){ command -v "$1" >/dev/null 2>&1; }
APT_UPDATED=0
ensure_bin(){
  local b="$1" pkg="${2:-$1}"
  if ! need_bin "$b"; then
    if command -v apt-get >/dev/null 2>&1; then
      if [[ $APT_UPDATED -eq 0 ]]; then
        INFO "apt-get update…"
        apt-get update -y >/dev/null
        APT_UPDATED=1
      fi
      INFO "Устанавливаю $b"
      apt-get install -y "$pkg" >/dev/null
    else
      ERR "Не найден пакетный менеджер для установки $b"; exit 1
    fi
  fi
  command -v "$b" >/dev/null 2>&1 || { ERR "Не удалось установить $b"; exit 1; }
}

ensure_bin curl curl
ensure_bin dig dnsutils
ensure_bin jq jq
ensure_bin yq yq

# ====== ФЛАГИ CLI ======
CLI_DRYRUN=false
for a in "$@"; do
  case "$a" in
    --dry-run) CLI_DRYRUN=true ;;
    *) ;;
  esac
done

normalize_bool() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)  echo true ;;
    0|false|FALSE|no|NO|off|OFF) echo false ;;
    *) echo "${1:-}" ;;
  esac
}

# ====== ЧТЕНИЕ vars.yaml ======
yq_get(){ yq -r "$1 // empty" "$VARS_FILE"; }

DOMAIN="$(yq_get '.domain')"
HOSTNAME="$(yq_get '.hostname')"
IPV4="$(yq_get '.ipv4')"

BEGET_LOGIN="$(yq_get '.beget.login')"
BEGET_TOKEN="$(yq_get '.beget.token')"

# блок dns_update (все опционально)
MSA_STATE_DIR="$(yq_get '.dns_update.msa_state_dir')"
MSA_MANIFEST="$(yq_get '.dns_update.msa_manifest')"
MSA_DKIM_TXT="$(yq_get '.dns_update.msa_dkim_txt')"
TTL_DEFAULT="$(yq_get '.dns_update.ttl_default')"
SPF_POLICY="$(yq_get '.dns_update.spf_policy')"
DNS_DRY_RUN_VAL="$(yq_get '.dns_update.dry_run')"

# значения по умолчанию
[[ -n "${MSA_STATE_DIR:-}" ]] || MSA_STATE_DIR="/var/local/msa"
[[ -n "${MSA_MANIFEST:-}"  ]] || MSA_MANIFEST="$MSA_STATE_DIR/manifest.json"
[[ -n "${MSA_DKIM_TXT:-}"  ]] || MSA_DKIM_TXT="$MSA_STATE_DIR/dkim.txt"
[[ -n "${TTL_DEFAULT:-}"   ]] || TTL_DEFAULT="3600"
[[ -n "${SPF_POLICY:-}"    ]] || SPF_POLICY="warn"

DNS_DRY_RUN="$(normalize_bool "${DNS_DRY_RUN_VAL:-false}")"
# CLI имеет приоритет над vars.yaml
[[ "$CLI_DRYRUN" == "true" ]] && DNS_DRY_RUN=true

# нормализация hostname
[[ -n "$HOSTNAME" ]] || HOSTNAME="mail.$DOMAIN"

# валидация
[[ -n "$DOMAIN"   ]] || { ERR "DOMAIN (domain) не задан в $VARS_FILE"; exit 1; }
[[ -n "$HOSTNAME" ]] || { ERR "HOSTNAME (hostname) не задан в $VARS_FILE"; exit 1; }
[[ -n "$IPV4"     ]] || { ERR "IPV4 (ipv4) не задан в $VARS_FILE"; exit 1; }
[[ -n "$BEGET_LOGIN" && -n "$BEGET_TOKEN" ]] || { ERR "beget.login / beget.token не заданы в $VARS_FILE"; exit 1; }

# ====== МАНИФЕСТ (DKIM/DMARC) ======
jq_safe(){ jq -r "$1 // empty" 2>/dev/null || true; }

DKIM_SELECTOR="$( [ -f "$MSA_MANIFEST" ] && jq_safe '.dns.selector' <"$MSA_MANIFEST" )"
[[ -n "$DKIM_SELECTOR" ]] || DKIM_SELECTOR="$(yq_get '.dkim_selector')"
[[ -n "$DKIM_SELECTOR" ]] || DKIM_SELECTOR="s1"

DKIM_VALUE=""
if [[ -f "$MSA_DKIM_TXT" ]]; then
  # убираем переводы строк
  DKIM_VALUE="$(tr -d '\n' <"$MSA_DKIM_TXT")"
fi

DMARC_VALUE_DEFAULT="v=DMARC1; p=none; rua=mailto:dmarc@$DOMAIN"
if [[ -f "$MSA_MANIFEST" ]]; then
  dm="$(jq_safe '.dns.DMARC' <"$MSA_MANIFEST")"
  [[ -n "$dm" ]] && DMARC_VALUE_DEFAULT="$dm"
fi

# ====== FQDNы и нормализация ======
trimdot(){ local s="${1:-}"; echo "${s%.}"; }
APEX_FQDN="$(trimdot "$DOMAIN")"
MAIL_FQDN="$(trimdot "$HOSTNAME")"
DKIM_FQDN="$(trimdot "${DKIM_SELECTOR}._domainkey.$DOMAIN")"
DMARC_FQDN="$(trimdot "_dmarc.$DOMAIN")"

INFO "Конфиг: domain=$APEX_FQDN, host=$MAIL_FQDN, ip=$IPV4, TTL=$TTL_DEFAULT, SPF_POLICY=$SPF_POLICY, dry-run=$DNS_DRY_RUN"

# ====== ПРОВЕРКА NS (Beget?) ======
ns_list="$(dig NS +short "$APEX_FQDN" | sed 's/\.$//')"
if [[ -z "$ns_list" ]]; then
  WARN "NS для $APEX_FQDN не получены — пропускаю авто-DNS."
  exit 0
fi
if ! echo "$ns_list" | grep -qi 'beget'; then
  WARN "Домен $APEX_FQDN делегирован НЕ на Beget: $(echo "$ns_list" | tr '\n' ' ' | sed 's/ $//')"
  INFO "Пропускаю авто-DNS. Добавьте записи вручную."
  exit 0
fi
INFO "NS у $APEX_FQDN — Beget:"
echo "$ns_list" | sed 's/^/  - /'

# ====== Beget API ======
beget_api_post(){
  local path="$1" json="$2"
  curl -fsS --connect-timeout 15 --max-time 45 \
    -X POST "https://api.beget.com/api/dns/$path" \
    -d "login=$BEGET_LOGIN" \
    -d "token=$BEGET_TOKEN" \
    -d "input_format=json" \
    -d "output_format=json" \
    --data-urlencode "input_data=$json"
}

api_ok(){ jq -e '.status=="success" and ((.answer.status//"success")=="success")' >/dev/null 2>&1; }
api_errmsg(){ jq -r '.answer.errors? // .error? // .answer.error_text? // .error_text? // .result.message? // "unknown error"' 2>/dev/null; }

dns_get(){
  local fqdn="$1"
  beget_api_post "getData" "$(jq -c --null-input --arg f "$fqdn" '{fqdn:$f}')" 
}

dns_change(){
  local fqdn="$1" records_json="$2"
  beget_api_post "changeRecords" "$(jq -c --arg f "$fqdn" --argjson r "$records_json" '{fqdn:$f,records:$r}')" 
}

sanitize_records(){
  jq -c 'if . == null then {} else
           with_entries(select(.key|IN("A","AAAA","CNAME","MX","TXT","SRV","CAA")))
         end'
}

read_recset(){
  local fqdn="$1" resp
  resp="$(dns_get "$fqdn")"
  if [[ -z "$resp" ]]; then
    ERR "[$fqdn] пустой ответ от Beget API"; exit 1
  fi
  if ! echo "$resp" | api_ok; then
    ERR "[$fqdn] Beget API error: $(echo "$resp" | api_errmsg)"; exit 1
  fi
  echo "$resp" | jq -c '.answer.result.records // {}' | sanitize_records
}

# ====== SPF ======
extract_spf(){
  jq -r '(.TXT // []) | map(.value // .txtdata) | map(sub("^\"|\"$";"")) | map(select(test("^\\s*v=spf1\\b"; "i"))) | .[0] // empty'
}

update_spf(){
  local recset="$1" policy="$2" host="$3" ttl="$4"
  local cur_spf new_spf
  cur_spf="$(echo "$recset" | extract_spf || true)"

  if [[ "$policy" == "warn" && -n "$cur_spf" ]]; then
    # не трогаем существующий SPF
    echo "$recset"
    return
  fi

  if [[ -z "$cur_spf" ]]; then
    new_spf="v=spf1 mx a:${host} ~all"
  else
    new_spf="$cur_spf"
    if ! grep -qiE "(^|[[:space:]])a:${host}([[:space:]]|$)" <<<"$new_spf"; then
      if grep -qiE '[[:space:]][~\-\?+]?all([[:space:]]|$)' <<<"$new_spf"; then
        new_spf="$(sed -E "s/[[:space:]]([~\\-\\?\\+]?all)([[:space:]]|$)/ a:${host} \\1\\2/I" <<<"$new_spf")"
      else
        new_spf="$new_spf a:${host}"
      fi
    fi
  fi

  jq -c --arg v "$new_spf" --argjson t "$ttl" '
    .TXT = ((.TXT // []) | map(select((.value // .txtdata) | test("^\\s*v=spf1\\b"; "i") | not)) + [{value:$v,ttl:$t}])
  ' <<<"$recset"
}

# ====== СБОРКА ЦЕЛЕВЫХ СЕТОВ ======
build_mail_recset(){
  local cur="$1" ip="$2" ttl="$3"
  jq -c --arg ip "$ip" --argjson t "$ttl" '
    .A = [{value:$ip, ttl:$t}] | del(.CNAME)
  ' <<<"$cur"
}

build_apex_recset(){
  local cur="$1" mailfq="$2" ttl="$3" spfpol="$4"
  local mxv="10 ${mailfq}."
  cur="$(jq -c --arg v "$mxv" --argjson t "$ttl" '.MX = [{value:$v, ttl:$t}]' <<<"$cur")"
  cur="$(update_spf "$cur" "$spfpol" "$mailfq" "$ttl")"
  echo "$cur"
}

build_dkim_recset(){
  local cur="$1" dkim="$2" ttl="$3"
  jq -c --arg v "$dkim" --argjson t "$ttl" '.TXT = [{value:$v, ttl:$t}]' <<<"$cur"
}

build_dmarc_recset(){
  local cur="$1" dmarc="$2" ttl="$3"
  # Добавляем TXT только если на _dmarc записи нет
  if [[ "$(jq -r '.TXT | length // 0' <<<"$cur")" -gt 0 ]]; then
    echo "$cur"
  else
    jq -c --arg v "$dmarc" --argjson t "$ttl" '.TXT = [{value:$v, ttl:$t}]' <<<"$cur"
  fi
}

# ====== ПРИМЕНЕНИЕ (per-FQDN changeRecords) ======
apply_recset(){
  local fqdn="$1" before="$2" after="$3"
  local b_norm a_norm
  b_norm="$(jq -S <<<"$before")"
  a_norm="$(jq -S <<<"$after")"

  if [[ "$b_norm" == "$a_norm" ]]; then
    INFO "[$fqdn] изменений нет"
    return 0
  fi

  if [[ "$DNS_DRY_RUN" == "true" ]]; then
    INFO "[$fqdn] DRY-RUN: изменения:"
    diff -u <(echo "$b_norm") <(echo "$a_norm") || true
    return 0
  fi

  INFO "[$fqdn] changeRecords…"
  local resp; resp="$(dns_change "$fqdn" "$after")"
  if [[ -z "$resp" ]] || ! echo "$resp" | api_ok; then
    ERR "[$fqdn] ошибка changeRecords: $(echo "$resp" | api_errmsg)"
    exit 1
  fi
}

# ====== ПЛАН/ПРИМЕНЕНИЕ ======
INFO "Читаю текущие записи…"
cur_mail="$(read_recset "$MAIL_FQDN")"
cur_apex="$(read_recset "$APEX_FQDN")"
cur_dkim="$(read_recset "$DKIM_FQDN")"
cur_dmarc="$(read_recset "$DMARC_FQDN")"

new_mail="$(build_mail_recset  "$cur_mail"  "$IPV4"                   "$TTL_DEFAULT")"
new_apex="$(build_apex_recset  "$cur_apex"  "$MAIL_FQDN"              "$TTL_DEFAULT" "$SPF_POLICY")"

if [[ -n "$DKIM_VALUE" ]]; then
  new_dkim="$(build_dkim_recset "$cur_dkim" "$DKIM_VALUE"             "$TTL_DEFAULT")"
else
  new_dkim="$cur_dkim"
  WARN "DKIM-файл не найден ($MSA_DKIM_TXT) — пропускаю DKIM."
fi

new_dmarc="$(build_dmarc_recset "$cur_dmarc" "$DMARC_VALUE_DEFAULT"   "$TTL_DEFAULT")"

apply_recset "$MAIL_FQDN"  "$cur_mail"  "$new_mail"
apply_recset "$APEX_FQDN"  "$cur_apex"  "$new_apex"
[[ -n "$DKIM_VALUE" ]] && apply_recset "$DKIM_FQDN" "$cur_dkim" "$new_dkim"
apply_recset "$DMARC_FQDN" "$cur_dmarc" "$new_dmarc"

# ====== ВЕРИФИКАЦИЯ ======
INFO "Верификация после применения…"
verify(){
  local fqdn="$1" filter="$2"
  local r; r="$(dns_get "$fqdn")"
  if ! echo "$r" | api_ok; then
    echo "fail"; return
  fi
  echo "$r" | jq -re "$filter" >/dev/null 2>&1 && echo "ok" || echo "fail"
}

vA="$(verify "$MAIL_FQDN"  --arg ip "$IPV4" '.answer.result.records.A[]?  | select((.value // .address) == $ip)')"
vMX="$(verify "$APEX_FQDN" --arg m "10 ${MAIL_FQDN}." '.answer.result.records.MX[]? | select((.value // (.preference|tostring+" "+.exchange)) == $m)')"

INFO "Итог: A($MAIL_FQDN)=$vA, MX($APEX_FQDN)=$vMX"
INFO "Готово."
exit 0
