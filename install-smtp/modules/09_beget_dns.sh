#!/usr/bin/env bash
# 09_beget_dns.sh — авто-деплой DNS в Beget с нормализацией DKIM TXT
#
# Реальность API Beget:
# - getData работает по APEX (зоне), поддомены до первой записи не отдаются (METHOD_FAILED)
# - changeRecords принимает records={A|MX|TXT|...} с полями priority/value для ОДНОГО fqdn
# Подход:
# 1) один getData по APEX — формируем current_apex (A/MX/TXT)
# 2) строим desired для:
#    - mail.<domain> (A)
#    - <domain>      (MX + SPF TXT, A сохраняем как в current_apex — «бережно»)
#    - sX._domainkey.<domain> (TXT DKIM) — значение нормализуем (без кавычек/скобок/контролов)
#    - _dmarc.<domain> (TXT DMARC — по умолчанию добавляем, если отсутствует в DNS)
# 3) собираем payload {priority,value} и вызываем changeRecords для каждого FQDN по очереди
# Верификация: dig к public DNS (API не показывает поддомены до создания)

set -Eeuo pipefail

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"
: "${VARS_FILE:?}"

# ====== ПАРАМЕТРЫ ======
VARS_FILE="${VARS_FILE:-vars.yaml}"
MSA_STATE_DIR="${MSA_STATE_DIR:-/var/local/msa}"
MSA_MANIFEST="${MSA_MANIFEST:-$MSA_STATE_DIR/manifest.json}"
MSA_DKIM_TXT="${MSA_DKIM_TXT:-$MSA_STATE_DIR/dkim.txt}"

TTL_DEFAULT="${TTL_DEFAULT:-3600}"              # информативно для вывода
SPF_POLICY="${SPF_POLICY:-warn}"                # warn|append
DNS_DRY_RUN="${DNS_DRY_RUN:-false}"             # --dry-run
DMARC_MODE="${DMARC_MODE:-ifabsent}"            # ifabsent|force (бережно по умолчанию)

# ====== ЛОГИ/ТРАП ======
ts(){ date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log(){ echo "[$(ts)] [$1] $2"; }
INFO(){ log INFO "$*"; }
WARN(){ log WARN "$*"; }
ERR(){ log ERROR "$*"; }
trap 'ERR "Ошибка на линии $LINENO: \"$BASH_COMMAND\""; exit 1' ERR

# ====== ФЛАГИ ======
for a in "$@"; do
  case "$a" in
    --dry-run) DNS_DRY_RUN=true ;;
  esac
done

# ====== ЗАВИСИМОСТИ ======
need_bin(){ command -v "$1" >/dev/null 2>&1; }
APT_UPDATED=0
ensure_bin(){
  local b="$1" pkg="${2:-$1}"
  if ! need_bin "$b"; then
    if command -v apt-get >/dev/null 2>&1; then
      if [[ $APT_UPDATED -eq 0 ]]; then
        INFO "apt-get update…"
        apt-get -y update >/dev/null
        APT_UPDATED=1
      fi
      INFO "Устанавливаю пакет $pkg"
      DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends "$pkg" >/dev/null
    else
      ERR "Не найден пакетный менеджер для установки $pkg"; exit 1
    fi
  fi
}
ensure_bin curl curl
ensure_bin dig dnsutils
ensure_bin jq jq
ensure_bin yq yq

# ====== ХЕЛПЕРЫ ======
yq_get(){ local expr="$1"; yq -r "$expr // \"\"" "$VARS_FILE" 2>/dev/null; }
jq_safe_file(){ local file="$1" filter="$2"; [[ -f "$file" ]] || { echo ""; return 0; }; jq -r "$filter // empty" "$file" 2>/dev/null || true; }
manifest_get(){ jq_safe_file "$MSA_MANIFEST" "$1"; }
trimdot(){ local s="${1:-}"; echo "${s%.}"; }

# ВАЖНО: нормализация DKIM из «зонного» формата → в «плоский» printable TXT
sanitize_dkim_value() {
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


# ====== КОНФИГ ======
DOMAIN="$(yq_get '.domain')"
HOSTNAME="$(yq_get '.hostname')"
IPV4="$(yq_get '.ipv4')"
[[ -z "$HOSTNAME" && -n "$DOMAIN" ]] && HOSTNAME="mail.$DOMAIN"

BEGET_LOGIN="$(yq_get '.beget.login')"
BEGET_PASSWORD="$(yq_get '.beget.password')"

spfp_from_yaml="$(yq_get '.beget.spf_policy')"
ttl_from_yaml="$(yq_get '.beget.ttl_default')"
[[ -n "$spfp_from_yaml" ]] && SPF_POLICY="$spfp_from_yaml"
[[ -n "$ttl_from_yaml"  ]] && TTL_DEFAULT="$ttl_from_yaml"

[[ -n "$DOMAIN"   ]] || { ERR "domain не задан в $VARS_FILE"; exit 1; }
[[ -n "$HOSTNAME" ]] || { ERR "hostname не задан в $VARS_FILE"; exit 1; }
[[ -n "$IPV4"     ]] || { ERR "ipv4 не задан в $VARS_FILE"; exit 1; }

APEX_FQDN="$(trimdot "$DOMAIN")"
MAIL_FQDN="$(trimdot "$HOSTNAME")"

DKIM_SELECTOR="$(manifest_get '.dns.selector')"; [[ -z "$DKIM_SELECTOR" ]] && DKIM_SELECTOR="s1"
DKIM_FQDN="$(trimdot "${DKIM_SELECTOR}._domainkey.$DOMAIN")"
DMARC_FQDN="$(trimdot "_dmarc.$DOMAIN")"

DKIM_VALUE=""
if [[ -f "$MSA_DKIM_TXT" ]]; then
  DKIM_VALUE="$(sanitize_dkim_value <"$MSA_DKIM_TXT")"
  # Гарантируем корректные разделители:
  DKIM_VALUE="$(printf '%s' "$DKIM_VALUE" \
    | sed -E 's/^v=DKIM1[[:space:]]*/v=DKIM1; /; s/DKIM1;?[[:space:]]*p=/DKIM1; p=/')"
fi

DMARC_VALUE_DEFAULT="v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN%.}"
dm_yaml="$(manifest_get '.dns.DMARC')"
[[ -n "$dm_yaml" ]] && DMARC_VALUE_DEFAULT="$dm_yaml"

INFO "Конфиг: domain=$APEX_FQDN, hostname=$MAIL_FQDN, ipv4=$IPV4, SPF_POLICY=$SPF_POLICY, TTL=$TTL_DEFAULT"
[[ "$DNS_DRY_RUN" == "true" ]] && INFO "Режим: DRY-RUN"

# ====== NS ПРОВЕРКА ======
ns_list="$(dig NS +short "$APEX_FQDN" | sed 's/\.$//')"
if [[ -z "$ns_list" ]]; then
  WARN "NS для $APEX_FQDN не получены — пропускаю авто-DNS."
  exit 0
fi
if ! echo "$ns_list" | grep -qi 'beget'; then
  WARN "Домен $APEX_FQDN делегирован НЕ на Beget:"
  echo "$ns_list" | sed 's/^/  - /'
  INFO "Пропускаю авто-DNS. Добавьте записи вручную."
  exit 0
fi
INFO "NS у $APEX_FQDN — Beget:"
echo "$ns_list" | sed 's/^/  - /'

# ====== CREDs ======
BEGET_HAS_CREDS=true
if [[ -z "$BEGET_LOGIN" || -z "$BEGET_PASSWORD" ]]; then
  BEGET_HAS_CREDS=false
  if [[ "$DNS_DRY_RUN" == "true" ]]; then
    WARN "Beget API креды не заданы (vars.yaml: beget.login / beget.password). API-запросы пропущу."
  else
    ERR "Для применения изменений нужны beget.login / beget.password в $VARS_FILE"
    exit 1
  fi
fi

# ====== Beget API ======
beget_api_post(){
  local path="$1" json="$2"
  local curl_opts=(
    -fsS
    --connect-timeout 15
    --max-time 45
    --retry 1
    --retry-connrefused
    -X POST "https://api.beget.com/api/dns/$path"
    -d "login=$BEGET_LOGIN"
    -d "passwd=$BEGET_PASSWORD"
    -d "input_format=json"
    -d "output_format=json"
    --data-urlencode "input_data=$json"
  )
  if [[ "${BEGET_DEBUG:-0}" == "1" ]]; then
    >&2 echo "DEBUG beget $path input: $json"
  fi
  curl "${curl_opts[@]}"
}
api_ok(){ jq -e '.status=="success" and ((.answer.status//"success")=="success")' >/dev/null 2>&1; }
api_errmsg(){ jq -r '.answer.errors? // .error? // .answer.error_text? // .error_text? // .result.message? // "unknown error"' 2>/dev/null; }
dns_get_apex(){
  $BEGET_HAS_CREDS || { echo "{}"; return 0; }
  beget_api_post "getData" "$(jq -nc --arg f "$APEX_FQDN" '{fqdn:$f}')" || echo "{}"
}
dns_change(){
  local fqdn="$1" payload_json="$2"
  $BEGET_HAS_CREDS || { echo '{"skip":"no-creds"}'; return 0; }
  local wrapper; wrapper="$(jq -nc --arg f "$fqdn" --arg p "$payload_json" '{fqdn:$f,records:($p|fromjson)}' 2>/dev/null || echo '')"
  [[ -n "$wrapper" ]] || { echo '{"status":"error","error_text":"bad payload json"}'; return 0; }
  beget_api_post "changeRecords" "$wrapper" || { echo '{"status":"error","error_text":"curl failed"}'; return 0; }
}

# ====== ЧИТАЕМ ТЕКУЩИЙ APEX ======
INFO "Читаю всю зону (APEX) через getData…"
apex_raw="$(dns_get_apex)"
if [[ -z "$apex_raw" ]]; then
  ERR "Пустой ответ от API getData(Apex)"
  exit 1
fi
if ! echo "$apex_raw" | api_ok >/dev/null 2>&1; then
  ERR "Beget API error: $(echo "$apex_raw" | api_errmsg)"
  exit 1
fi

# Текущие apex A/MX/TXT (как массивы строк)
apex_A="$(echo "$apex_raw" | jq -r '.answer.result.records.A[]?   | (.value // .address)    ' 2>/dev/null || true)"
apex_MX="$(echo "$apex_raw" | jq -r '.answer.result.records.MX[]?  | if .value then .value else ((.priority // .preference // 10|tostring)+" "+(.exchange // "")) end ' 2>/dev/null || true)"
apex_TXT="$(echo "$apex_raw" | jq -r '.answer.result.records.TXT[]?| (.value // .txtdata)  ' 2>/dev/null || true)"

# Вытащим существующий SPF (если есть)
cur_spf="$(printf '%s\n' "$apex_TXT" | awk 'BEGIN{IGNORECASE=1} /^ *"?.*v=spf1/ {print; exit}')"
merge_spf() {
  local spf="$1" host="$2"
  if [[ -z "$spf" ]]; then echo "v=spf1 mx a:${host} ~all"; return; fi
  if grep -qiE "(^|[[:space:]])a:${host}([[:space:]]|$)" <<<"$spf"; then echo "$spf"; return; fi
  if grep -qiE '[[:space:]][~\-\?+]?all([[:space:]]|$)' <<<"$spf"; then
    sed -E "s/[[:space:]]([~\\-\\?\\+]?all)([[:space:]]|$)/ a:${host} \\1\\2/I" <<<"$spf"
  else
    echo "$spf a:${host}"
  fi
}

# Итоговый SPF
if [[ "$SPF_POLICY" == "warn" && -n "${cur_spf:-}" ]]; then
  want_spf="$cur_spf"
else
  want_spf="$(merge_spf "${cur_spf:-}" "$MAIL_FQDN")"
fi

# ====== УТИЛИТА: формирование payload {priority,value}
mk_payload(){
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

# ====== DESIRED ======
# mail.<domain>: только A
payload_mail="$(mk_payload "$IPV4" "" "")"

# apex: A — как есть (бережно), MX — на mail.<domain>, SPF — по policy
apex_A_lines="$(printf '%s\n' "$apex_A" | sed '/^$/d')"
apex_MX_want="10 $MAIL_FQDN"
payload_apex="$(mk_payload "$apex_A_lines" "$apex_MX_want" "$want_spf")"

# DKIM (если ключ сгенерен) — значение уже нормализовано
payload_dkim="{}"
if [[ -n "$DKIM_VALUE" ]]; then
  # sanity-check: должна быть v=DKIM1; и p=
  if ! grep -qi '^v=DKIM1;' <<<"$DKIM_VALUE"; then
    WARN "DKIM_VALUE не начинается с v=DKIM1; — проверьте $MSA_DKIM_TXT"
  fi
  if ! grep -qi 'p=' <<<"$DKIM_VALUE"; then
    WARN "В DKIM_VALUE отсутствует p= — проверьте $MSA_DKIM_TXT"
  fi
  payload_dkim="$(mk_payload "" "" "$DKIM_VALUE")"
else
  WARN "DKIM-файл не найден или пуст ($MSA_DKIM_TXT) — пропускаю DKIM."
fi

# DMARC: по умолчанию — если отсутствует в DNS (бережно), либо force
need_dmarc=true
if [[ "$DMARC_MODE" == "ifabsent" ]]; then
  if dig +short TXT "$DMARC_FQDN" | grep -qi 'v=DMARC1'; then
    need_dmarc=false
    INFO "DMARC уже существует в DNS — пропускаю (режим ifabsent)."
  fi
fi
payload_dmarc="{}"
$need_dmarc && payload_dmarc="$(mk_payload "" "" "$DMARC_VALUE_DEFAULT")"

# ====== APPLY ======
apply_one(){
  local fqdn="$1" payload="$2"
  if [[ -z "${payload//[[:space:]]/}" || "$payload" = "{}" ]]; then
    INFO "[$fqdn] изменений нет (payload пуст)"
    return 0
  fi
  if [[ "$DNS_DRY_RUN" == "true" ]]; then
    INFO "[$fqdn] DRY-RUN: payload →"
    echo "$payload" | jq -S .
    return 0
  fi
  [[ "${BEGET_DEBUG:-0}" == "1" ]] && { >&2 echo "DEBUG desired($fqdn):"; echo "$payload" | jq -S . >&2; }

  INFO "[$fqdn] changeRecords…"
  local resp; resp="$(dns_change "$fqdn" "$payload" || true)"
  if [[ -z "$resp" ]]; then
    ERR "[$fqdn] пустой ответ от API"
    exit 1
  fi
  if ! echo "$resp" | api_ok >/dev/null 2>&1; then
    [[ "${BEGET_DEBUG:-0}" == "1" ]] && { >&2 echo "DEBUG changeRecords($fqdn) resp:"; echo "$resp" | jq -S . >&2; }
    ERR "[$fqdn] ошибка changeRecords: $(echo "$resp" | api_errmsg)"
    exit 1
  fi
}

INFO "Готовлю изменения…"
apply_one "$MAIL_FQDN"  "$payload_mail"
apply_one "$APEX_FQDN"  "$payload_apex"
[[ -n "$DKIM_VALUE" ]] && apply_one "$DKIM_FQDN" "$payload_dkim"
$need_dmarc && apply_one "$DMARC_FQDN" "$payload_dmarc"

# ====== ВЕРИФИКАЦИЯ (через dig) ======
INFO "Верификация через публичный DNS… (может занять время из-за кешей)"
verify_a(){ local host="$1" ip="$2"; dig +short A "$host" | grep -Fxq "$ip" && echo ok || echo fail; }
verify_mx_spf(){
  local apex="$1" mailfq="$2"
  local mx_ok spf_ok
  mx_ok=fail
  if dig +short MX "$apex" | sed 's/\.$//' | grep -Eq "^[[:space:]]*10[[:space:]]+$mailfq$"; then mx_ok=ok; fi
  spf_ok=fail
  if dig +short TXT "$apex" | tr -d '"' | grep -qi '^v=spf1'; then spf_ok=ok; fi
  [[ "$mx_ok" == "ok" && "$spf_ok" == "ok" ]] && echo ok || echo fail
}
vA="$(verify_a "$MAIL_FQDN" "$IPV4" || true)"
vMXSPF="$(verify_mx_spf "$APEX_FQDN" "$MAIL_FQDN" || true)"
INFO "Итог: A(mail)=$vA, MX/SPF(@)=$vMXSPF"
INFO "Готово."
