#!/usr/bin/env bash
# 09_beget_dns.sh — авто-деплой DNS в Beget с нормализацией DKIM TXT
# Логика:
# - читаем vars.yaml и /var/local/msa/dkim.txt
# - проверяем делегирование NS → Beget
# - формируем desired:
#     A:  mail.<domain> → ipv4
#     MX: @ → 10 mail.<domain>
#     SPF: @ → merge/append v=spf1 (вставляем a:mail.<domain> если нужно)
#     DKIM: sX._domainkey.<domain> → нормализованный TXT
#     DMARC: _dmarc.<domain> → v=DMARC1; p=none; rua=mailto:<ПЕРВЫЙ_USER_EMAIL|hostmaster@>
# - применяем через changeRecords
# - верифицируем через публичный DNS
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
TTL_DEFAULT="${TTL_DEFAULT:-3600}"               # информативно (Beget сам расставит)
SPF_POLICY="${SPF_POLICY:-warn}"                 # warn|append
DNS_DRY_RUN="${DNS_DRY_RUN:-false}"             # --dry-run активирует
DMARC_MODE="${DMARC_MODE:-ifabsent}"            # ifabsent|force
# чистка дефолтов Бегета
CLEAN_BEGET_DEFAULTS="${CLEAN_BEGET_DEFAULTS:-true}"   # true|false
# что делать с autoconfig/autodiscover, если удалить нельзя
BEGET_AUTOCONFIG_MODE="${BEGET_AUTOCONFIG_MODE:-cname}"  # delete|cname

# чистка дефолтов Бегета
CLEAN_BEGET_DEFAULTS="${CLEAN_BEGET_DEFAULTS:-true}"   # true|false
# что делать с autoconfig/autodiscover, если удалить нельзя
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

# склейка DKIM TXT из зонного формата в плоскую строку
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

# merge SPF: если уже есть v=spf1 — аккуратно вставим a:mail.<domain> перед all
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

# payload → JSON для Beget changeRecords
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

  # Selector: из manifest (если уже сгенерён), иначе s1
  DKIM_SELECTOR="$(dns::manifest_get '.dns.selector')"; [[ -z "$DKIM_SELECTOR" ]] && DKIM_SELECTOR="s1"

  # DMARC RUA: первый пользователь из vars, иначе hostmaster@
  # DMARC RUA: первый ящик из users, потом acme_email, потом hostmaster@
  PRIMARY_USER_EMAIL="$(yq -r '
    (.users // [])                                  # массив или []
    | (.[0] // {})                                  # первый объект или {}
    | (.email // .login // "")                      # email > login
  ' "$VARS_FILE" 2>/dev/null || echo "")"

  if [[ -z "$PRIMARY_USER_EMAIL" || "$PRIMARY_USER_EMAIL" == "null" ]]; then
    # пробуем acme_email
    PRIMARY_USER_EMAIL="$(yq -r '.acme_email // ""' "$VARS_FILE" 2>/dev/null || echo "")"
  fi
  if [[ -z "$PRIMARY_USER_EMAIL" || "$PRIMARY_USER_EMAIL" == "null" ]]; then
    PRIMARY_USER_EMAIL="hostmaster@${DOMAIN}"
    log_info "DMARC: users/acme_email не заданы → используем ${PRIMARY_USER_EMAIL}"
  else
    log_info "DMARC: RUA будет ${PRIMARY_USER_EMAIL}"
  fi

  DMARC_VALUE="v=DMARC1; p=none; rua=mailto:${PRIMARY_USER_EMAIL}"

  APEX_FQDN="$(dns::trimdot "$DOMAIN")"
  MAIL_FQDN="$(dns::trimdot "$HOSTNAME")"
  DKIM_FQDN="$(dns::trimdot "${DKIM_SELECTOR}._domainkey.$DOMAIN")"
  DMARC_FQDN="$(dns::trimdot "_dmarc.$DOMAIN")"

  [[ -n "$DOMAIN"   ]] || { log_error "domain не задан в $VARS_FILE"; exit 1; }
  [[ -n "$HOSTNAME" ]] || { log_error "hostname не задан в $VARS_FILE"; exit 1; }
  [[ -n "$IPV4"     ]] || { log_error "ipv4 не задан в $VARS_FILE"; exit 1; }
}

# ---------- Beget API ----------
dns::api_ok(){ jq -e '.status=="success" and ((.answer.status//"success")=="success")' >/dev/null 2>&1; }
dns::api_err(){ jq -r '.answer.errors? // .error? // .answer.error_text? // .error_text? // .result.message? // "unknown error"' 2>/dev/null; }

dns::beget_post(){
  local path="$1" json="$2"
  local url="https://api.beget.com/api/dns/$path"
  local data=(
    -fsS --connect-timeout 15 --max-time 45 --retry 1 --retry-connrefused
    -X POST "$url"
    -d "login=$BEGET_LOGIN"
    -d "passwd=$BEGET_PASSWORD"
    -d "input_format=json"
    -d "output_format=json"
    --data-urlencode "input_data=$json"
  )
  curl "${data[@]}"
}

dns::get_apex(){
  if [[ -z "$BEGET_LOGIN" || -z "$BEGET_PASSWORD" ]]; then
    log_error "Не заданы beget.login / beget.password в $VARS_FILE"
    exit 1
  fi
  dns::beget_post "getData" "$(jq -nc --arg f "$APEX_FQDN" '{fqdn:$f}')" || echo "{}"
}

dns::change_records(){
  local fqdn="$1" payload_json="$2"
  local wrapper; wrapper="$(jq -nc --arg f "$fqdn" --arg p "$payload_json" '{fqdn:$f,records:($p|fromjson)}' 2>/dev/null || echo '')"
  [[ -n "$wrapper" ]] || { echo '{"status":"error","error_text":"bad payload json"}'; return 0; }
  dns::beget_post "changeRecords" "$wrapper" || echo '{"status":"error","error_text":"curl failed"}'
}

# ---------- NS check ----------
dns::check_ns() {
  local ns_list; ns_list="$(dig NS +short "$APEX_FQDN" | sed 's/\.$//')"
  if [[ -z "$ns_list" ]]; then
    log_warn "NS для $APEX_FQDN не получены — пропускаю авто-DNS."
    exit 0
  fi
  if ! grep -qi 'beget' <<<"$ns_list"; then
    log_warn "Домен $APEX_FQDN делегирован НЕ на Beget:"
    while IFS= read -r n; do echo "  - $n"; done <<<"$ns_list"
    log_info "Пропускаю авто-DNS. Добавьте записи вручную."
    exit 0
  fi
  log_info "NS у $APEX_FQDN — Beget:"
  while IFS= read -r n; do echo "  - $n"; done <<<"$ns_list"
}

# ---------- read current apex ----------
dns::read_current() {
  dns::cleanup_beget_defaults
  dns::cleanup_beget_defaults
  log_info "Читаю APEX через Beget getData…"
  APEX_RAW="$(dns::get_apex)"
  [[ -n "$APEX_RAW" ]] || { log_error "Пустой ответ от getData"; exit 1; }
  dns::api_ok <<<"$APEX_RAW" || { log_error "Beget API error: $(dns::api_err <<<"$APEX_RAW")"; exit 1; }

  CUR_A="$(jq -r '.answer.result.records.A[]?    | (.value // .address)' <<<"$APEX_RAW" 2>/dev/null || true)"
  CUR_MX="$(jq -r '.answer.result.records.MX[]?   | if .value then .value else ((.priority // .preference // 10|tostring)+" "+(.exchange // "")) end ' <<<"$APEX_RAW" 2>/dev/null || true)"
  CUR_TXT="$(jq -r '.answer.result.records.TXT[]? | (.value // .txtdata)' <<<"$APEX_RAW" 2>/dev/null || true)"

  CUR_SPF="$(printf '%s\n' "$CUR_TXT" | awk 'BEGIN{IGNORECASE=1} /^ *"?.*v=spf1/ {print; exit}')"
}

# ---------- cleanup Beget defaults ----------
dns::cleanup_beget_defaults() {
  [[ "$CLEAN_BEGET_DEFAULTS" == "true" ]] || { log_info "Cleanup Beget defaults: выключено"; return; }

  # 1) autoconfig. и autodiscover.: сначала пробуем удалить все записи
  for sub in autoconfig autodiscover; do
    local fqdn="${sub}.${APEX_FQDN}"
    if [[ "$DNS_DRY_RUN" == "true" ]]; then
      log_info "[$fqdn] DRY-RUN cleanup (delete all records)"
    else
      local resp; resp="$(dns::change_records "$fqdn" "{}" || true)"
      if [[ -z "$resp" || "$(jq -r '.status // empty' <<<"$resp")" != "success" ]]; then
        log_warn "[$fqdn] delete не поддержан или ошибка API: $(dns::api_err <<<"$resp")"
        if [[ "$BEGET_AUTOCONFIG_MODE" == "cname" ]]; then
          # перезаписываем на CNAME → mail.<domain>
          local payload; payload="$( jq -nc --arg v "$MAIL_FQDN" '{CNAME:[{priority:10, value:$v}]}' )"
          resp="$(dns::change_records "$fqdn" "$payload" || true)"
          if dns::api_ok <<<"$resp"; then
            log_info "[$fqdn] переписан CNAME → ${MAIL_FQDN}"
          else
            log_warn "[$fqdn] не удалось перезаписать CNAME: $(dns::api_err <<<"$resp")"
          fi
        else
          log_warn "[$fqdn] оставлен без изменений (BEGET_AUTOCONFIG_MODE=delete)"
        fi
      else
        log_info "[$fqdn] удалён (records cleared)"
      fi
    fi
  done

  # 2) SPF redirect=beget.com → сбросим, дальше построим свой SPF
  if [[ -n "${CUR_SPF:-}" ]] && grep -qiE '^ *"?v=spf1[[:space:]]+redirect=beget\.com' <<<"$CUR_SPF"; then
    log_info "SPF: найден redirect=beget.com — будет заменён на наш SPF"
    CUR_SPF=""
  fi
}
# ---------- build desired ----------
dns::build_desired() {
  # DKIM value
  DKIM_VALUE=""
  if [[ -f "$MSA_DKIM_TXT" ]]; then
    DKIM_VALUE="$(dns::sanitize_dkim_value <"$MSA_DKIM_TXT")"
    DKIM_VALUE="$(printf '%s' "$DKIM_VALUE" | sed -E 's/^v=DKIM1[[:space:]]*/v=DKIM1; /; s/DKIM1;?[[:space:]]*p=/DKIM1; p=/')"
  else
    log_warn "DKIM-файл не найден или пуст: $MSA_DKIM_TXT — пропущу DKIM."
  fi

  # SPF итоговый
  if [[ "$SPF_POLICY" == "warn" && -n "${CUR_SPF:-}" ]]; then
    WANT_SPF="$CUR_SPF"
  else
    WANT_SPF="$(dns::merge_spf "${CUR_SPF:-}" "$MAIL_FQDN")"
  fi

  # payload’ы
  PAYLOAD_MAIL="$(dns::mk_payload "$IPV4" "" "")"
  APEX_A_LINES="$(printf '%s\n' "$CUR_A" | sed '/^$/d')"        # бережно сохраняем существующие A
  APEX_MX_WANT="10 $MAIL_FQDN"
  PAYLOAD_APEX="$(dns::mk_payload "$APEX_A_LINES" "$APEX_MX_WANT" "$WANT_SPF")"

  PAYLOAD_DKIM="{}"
  [[ -n "$DKIM_VALUE" ]] && PAYLOAD_DKIM="$(dns::mk_payload "" "" "$DKIM_VALUE")"

  # DMARC: ifabsent → только если нет в публичном DNS
  NEED_DMARC=true
  if [[ "$DMARC_MODE" == "ifabsent" ]]; then
    if dig +short TXT "$DMARC_FQDN" | grep -qi 'v=DMARC1'; then
      NEED_DMARC=false
      log_info "DMARC уже существует — пропускаю (ifabsent)."
    fi
  fi
  PAYLOAD_DMARC="{}"
  $NEED_DMARC && PAYLOAD_DMARC="$(dns::mk_payload "" "" "$DMARC_VALUE")"
}

# ---------- apply ----------
dns::apply_one(){
  local fqdn="$1" payload="$2"
  if [[ -z "${payload//[[:space:]]/}" || "$payload" = "{}" ]]; then
    log_info "[$fqdn] изменений нет"
    return 0
  fi
  if [[ "$DNS_DRY_RUN" == "true" ]]; then
    log_info "[$fqdn] DRY-RUN payload:"
    echo "$payload" | jq -S .
    return 0
  fi
  log_info "[$fqdn] changeRecords…"
  local resp; resp="$(dns::change_records "$fqdn" "$payload" || true)"
  [[ -n "$resp" ]] || { log_error "[$fqdn] пустой ответ от API"; exit 1; }
  dns::api_ok <<<"$resp" || { [[ "${BEGET_DEBUG:-0}" == "1" ]] && echo "$resp" | jq -S . >&2; log_error "[$fqdn] ошибка: $(dns::api_err <<<"$resp")"; exit 1; }
}

dns::apply_all(){
  dns::apply_one "$MAIL_FQDN"  "$PAYLOAD_MAIL"
  dns::apply_one "$APEX_FQDN"  "$PAYLOAD_APEX"
  [[ -n "$DKIM_VALUE" ]] && dns::apply_one "$DKIM_FQDN" "$PAYLOAD_DKIM"
  $NEED_DMARC && dns::apply_one "$DMARC_FQDN" "$PAYLOAD_DMARC"
}

# ---------- verify ----------
dns::verify() {
  log_info "Верификация публичным DNS… (кеши могут задерживать)"
  local a_ok="fail" mx_ok="fail" spf_ok="fail"
  dig +short A   "$MAIL_FQDN" | grep -Fxq "$IPV4" && a_ok="ok"
  dig +short MX  "$APEX_FQDN" | sed 's/\.$//' | grep -Eq "^[[:space:]]*10[[:space:]]+$MAIL_FQDN$" && mx_ok="ok"
  dig +short TXT "$APEX_FQDN" | tr -d '"' | grep -qi '^v=spf1' && spf_ok="ok"
  log_info "Итог проверки: A(mail)=$a_ok, MX(@)=${mx_ok}, SPF(@)=${spf_ok}"
}

# ---------- main ----------
module::main() {
  # флаги командной строки
  for a in "$@"; do [[ "$a" == "--dry-run" ]] && DNS_DRY_RUN=true; done

  dns::need
  dns::vars
  log_info "DNS Beget: domain=$DOMAIN, hostname=$HOSTNAME, ipv4=$IPV4, selector=$DKIM_SELECTOR, SPF_POLICY=$SPF_POLICY, TTL=$TTL_DEFAULT"
  [[ "$DNS_DRY_RUN" == "true" ]] && log_info "Режим DRY-RUN"

  dns::check_ns
  dns::read_current
  dns::cleanup_beget_defaults
  dns::cleanup_beget_defaults
  dns::build_desired
  dns::apply_all
  dns::verify
  log_info "DNS Beget: готово."
}

module::main "$@"
