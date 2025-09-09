#!/usr/bin/env bash
# 09_beget_dns.sh — авто-деплой DNS в Beget с нормализацией DKIM TXT
# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"
: "${VARS_FILE:=${MOD_DIR}/../vars.yaml}"
if [[ ! -r "$VARS_FILE" ]]; then
  log_error "VARS_FILE не найден: $VARS_FILE"; exit 1
fi
MSA_STATE_DIR="${MSA_STATE_DIR:-/var/local/msa}"
MSA_MANIFEST="${MSA_MANIFEST:-$MSA_STATE_DIR/manifest.json}"
MSA_DKIM_TXT="${MSA_DKIM_TXT:-$MSA_STATE_DIR/dkim.txt}"

# ---------- опции ----------
TTL_DEFAULT="${TTL_DEFAULT:-3600}"
SPF_POLICY="${SPF_POLICY:-warn}"       # warn|append
DNS_DRY_RUN="${DNS_DRY_RUN:-false}"
DMARC_MODE="${DMARC_MODE:-ifabsent}"  # ifabsent|force
CLEAN_BEGET_DEFAULTS="${CLEAN_BEGET_DEFAULTS:-true}"
BEGET_AUTOCONFIG_MODE="${BEGET_AUTOCONFIG_MODE:-cname}"  # delete|cname

# ---------- deps ----------
dns::need() {
  for b in curl jq yq dig; do
    if ! command -v "$b" >/dev/null 2>&1; then
      run_cmd apt-get update -y
      run_cmd DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dnsutils jq yq curl
      break
    fi
  done
}

# ---------- utils ----------
dns::_yq() { yq -r "$1 // \"\"" "$VARS_FILE" 2>/dev/null; }
dns::manifest_get() { [[ -f "$MSA_MANIFEST" ]] || { echo ""; return 0; }; jq -r "$1 // empty" "$MSA_MANIFEST" 2>/dev/null || true; }
dns::trimdot(){ local s="${1:-}"; s="${s%.}"; printf '%s' "$s"; }

dns::sanitize_dkim_value() {
  tr -d '\r' \
  | sed -e 's/;.*$//' \
        -e 's/^[[:space:]]*[^"]*"//' \
        -e 's/"[[:space:]]*"[[:space:]]*/ /g' \
        -e 's/"[[:space:]]*)[[:space:]]*$//' \
        -e 's/^[[:space:]]*(//; s/)[[:space:]]*$//' \
        -e 's/\\"/"/g' \
        -e 's/\\//g' \
  | tr -d '\n\t' \
  | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

dns::merge_spf() {
  local spf="$1" host="$2"
  if [[ -z "$spf" ]]; then echo "v=spf1 mx a:${host} ~all"; return; fi
  if grep -qiE "(^|[[:space:]])a:${host}([[:space:]]|$)" <<<"$spf"; then echo "$spf"; return; fi
  if grep -qiE '[[:space:]][~\-\?+]?all([[:space:]]|$)' <<<"$spf"; then
    sed -E "s/[[:space:]]([~\\-\\?\\+]?all)([[:space:]]|$)/ a:${host} \\1\\2/I" <<<"$spf"
  else
    echo "$spf a:${host}"
  fi
}

dns::mk_payload(){
  local a_lines="$1" mx_lines="$2" txt_lines="$3"
  local ja jmx jtxt
  ja="$(printf '%s\n' "$a_lines"  | jq -Rsc 'split("\n")|map(select(length>0))')"
  jmx="$(printf '%s\n' "$mx_lines" | jq -Rsc 'split("\n")|map(select(length>0))')"
  jtxt="$(printf '%s\n' "$txt_lines"| jq -Rsc 'split("\n")|map(select(length>0))')"
  jq -nc --argjson A "$ja" --argjson MX "$jmx" --argjson TXT "$jtxt" '
    {}
    | (if ($A|length)>0  then .A  = [ range(0; $A|length)  as $i | {priority:(($i+1)*10), value: $A[$i]} ]  else . end)
    | (if ($MX|length)>0 then .MX = [ range(0; $MX|length) as $i |
                                       ($MX[$i] | capture("^(?<p>[0-9]+)\\s+(?<h>.+)$")) as $m
                                       | {priority: ($m.p|tonumber), value: ($m.h|sub("\\.$";""))}
                                     ] else . end)
    | (if ($TXT|length)>0 then .TXT= [ range(0; $TXT|length)as $i | {priority:(($i+1)*10), value: $TXT[$i]} ] else . end)
  '
}

# ---------- vars ----------
dns::vars() {
  DOMAIN="$(dns::_yq '.domain')"
  HOSTNAME="$(dns::_yq '.hostname')"
  IPV4="$(dns::_yq '.ipv4')"
  [[ -z "$HOSTNAME" && -n "$DOMAIN" ]] && HOSTNAME="mail.$DOMAIN"

  BEGET_LOGIN="$(dns::_yq '.beget.login')"
  BEGET_PASSWORD="$(dns::_yq '.beget.password')"

  DKIM_SELECTOR="$(dns::manifest_get '.dns.selector')"; [[ -z "$DKIM_SELECTOR" ]] && DKIM_SELECTOR="s1"

  PRIMARY_USER_EMAIL="$(yq -r '(.users // [] | .[0] // {} | (.email // .login // ""))' "$VARS_FILE" 2>/dev/null || echo "")"
  [[ -z "$PRIMARY_USER_EMAIL" || "$PRIMARY_USER_EMAIL" == "null" ]] && PRIMARY_USER_EMAIL="$(yq -r '.acme_email // ""' "$VARS_FILE" 2>/dev/null || echo "")"
  [[ -z "$PRIMARY_USER_EMAIL" || "$PRIMARY_USER_EMAIL" == "null" ]] && PRIMARY_USER_EMAIL="hostmaster@${DOMAIN}"

  DMARC_VALUE="v=DMARC1; p=none; rua=mailto:${PRIMARY_USER_EMAIL}"

  APEX_FQDN="$(dns::trimdot "$DOMAIN")"
  MAIL_FQDN="$(dns::trimdot "$HOSTNAME")"
  DKIM_FQDN="$(dns::trimdot "${DKIM_SELECTOR}._domainkey.$DOMAIN")"
  DMARC_FQDN="$(dns::trimdot "_dmarc.$DOMAIN")"
  TRACK_FQDN="$(dns::trimdot "track.$DOMAIN")"

  [[ -n "$DOMAIN" && -n "$HOSTNAME" && -n "$IPV4" ]] || { log_error "domain/hostname/ipv4 не заданы"; exit 1; }
}

# ---------- Beget API ----------
dns::api_ok(){ jq -e '.status=="success" and ((.answer.status//"success")=="success")' >/dev/null 2>&1; }
dns::api_err(){ jq -r '.answer.errors? // .error? // .answer.error_text? // .error_text? // "unknown error"' 2>/dev/null; }

dns::beget_post(){
  local path="$1" json="$2"
  curl -fsS -X POST "https://api.beget.com/api/dns/$path" \
    -d "login=$BEGET_LOGIN" -d "passwd=$BEGET_PASSWORD" \
    -d "input_format=json" -d "output_format=json" \
    --data-urlencode "input_data=$json"
}

dns::get_apex(){ dns::beget_post "getData" "$(jq -nc --arg f "$APEX_FQDN" '{fqdn:$f}')" || echo "{}"; }
dns::change_records(){
  local fqdn="$1" payload_json="$2"
  local wrapper; wrapper="$(jq -nc --arg f "$fqdn" --arg p "$payload_json" '{fqdn:$f,records:($p|fromjson)}' 2>/dev/null || echo '')"
  [[ -n "$wrapper" ]] || { echo '{"status":"error","error_text":"bad payload json"}'; return; }
  dns::beget_post "changeRecords" "$wrapper" || echo '{"status":"error","error_text":"curl failed"}'
}

# ---------- cleanup defaults ----------
dns::cleanup_beget_defaults() {
  [[ "$CLEAN_BEGET_DEFAULTS" == "true" ]] || return 0

  for sub in autoconfig autodiscover www; do
    local fqdn="${sub}.${APEX_FQDN}"
    log_info "Чищу дефолт $fqdn"
    local resp; resp="$(dns::change_records "$fqdn" "{}" || true)"
    if dns::api_ok <<<"$resp"; then
      log_info "[$fqdn] удалён"
    else
      log_warn "[$fqdn] не удалось удалить: $(dns::api_err <<<"$resp")"
      if [[ "$sub" != "www" && "$BEGET_AUTOCONFIG_MODE" == "cname" ]]; then
        local payload; payload="$(jq -nc --arg v "$MAIL_FQDN" '{CNAME:[{priority:10,value:$v}]}')"
        dns::change_records "$fqdn" "$payload" >/dev/null 2>&1 || true
      fi
    fi
  done
}

# ---------- build desired ----------
dns::build_desired() {
  DKIM_VALUE=""; [[ -f "$MSA_DKIM_TXT" ]] && DKIM_VALUE="$(dns::sanitize_dkim_value <"$MSA_DKIM_TXT")"
  WANT_SPF="$(dns::merge_spf "${CUR_SPF:-}" "$MAIL_FQDN")"

  # apex = A + MX + SPF
  APEX_MX_WANT="10 $MAIL_FQDN"
  PAYLOAD_APEX="$(dns::mk_payload "" "$APEX_MX_WANT" "$WANT_SPF")"  # A(@) оставляем как есть
  # ВАЖНО: A(@) не меняем здесь — этим занимается 02_pre_dns.sh. Тут только MX/SPF/и пр.

  # mail.<domain> = A + MX + SPF
  MAIL_MX_WANT="10 $MAIL_FQDN"
  PAYLOAD_MAIL="$(dns::mk_payload "$IPV4" "$MAIL_MX_WANT" "$WANT_SPF")"

  PAYLOAD_DKIM="{}"; [[ -n "$DKIM_VALUE" ]] && PAYLOAD_DKIM="$(dns::mk_payload "" "" "$DKIM_VALUE")"
  PAYLOAD_DMARC="$(dns::mk_payload "" "" "$DMARC_VALUE")"
  PAYLOAD_TRACK="$(jq -nc --arg v "open.sleadtrack.com" '{CNAME:[{priority:10,value:$v}]}')"
}

# ---------- apply ----------
dns::apply_one(){
  local fqdn="$1" payload="$2"
  [[ -z "${payload// }" || "$payload" == "{}" ]] && { log_info "[$fqdn] изменений нет"; return; }
  [[ "$DNS_DRY_RUN" == "true" ]] && { log_info "[$fqdn] DRY-RUN:"; echo "$payload" | jq -S .; return; }
  local resp; resp="$(dns::change_records "$fqdn" "$payload" || true)"
  dns::api_ok <<<"$resp" || log_error "[$fqdn] ошибка: $(dns::api_err <<<"$resp")"
}

dns::apply_all(){
  dns::apply_one "$APEX_FQDN"  "$PAYLOAD_APEX"
  dns::apply_one "$MAIL_FQDN"  "$PAYLOAD_MAIL"
  [[ -n "$DKIM_VALUE" ]] && dns::apply_one "$DKIM_FQDN" "$PAYLOAD_DKIM"
  dns::apply_one "$DMARC_FQDN" "$PAYLOAD_DMARC"
  dns::apply_one "$TRACK_FQDN" "$PAYLOAD_TRACK"
}

# ---------- main ----------
module::main() {
  [[ "$*" == *"--dry-run"* ]] && DNS_DRY_RUN=true
  dns::need
  dns::vars
  dns::cleanup_beget_defaults
  APEX_RAW="$(dns::get_apex)"
  CUR_A="$(jq -r '.answer.result.records.A[]? | select(.value != null) | .value' <<<"$APEX_RAW" 2>/dev/null \
          | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)"
  CUR_SPF="$(jq -r '.answer.result.records.TXT[]? | select(test("^\\\"?v=spf1";"i"))' <<<"$APEX_RAW" 2>/dev/null || true)"
  dns::build_desired
  dns::apply_all
  log_info "DNS Beget: готово."
}
module::main "$@"
