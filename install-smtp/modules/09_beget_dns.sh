#!/usr/bin/env bash
# 09_beget_dns.sh — авто-деплой DNS в Beget:
# - единственный источник конфигурации: vars.yaml
# - dry-run (--dry-run)
# - бережные изменения (per-FQDN changeRecords)
# - пост-верификация базовых записей
# Требует: curl, dig, jq, yq

set -Eeuo pipefail

# ========= ЛОГИ =========
ts(){ date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log(){ echo "[$(ts)] [$1] $2"; }
INFO(){ log INFO "$*"; }
WARN(){ log WARN "$*"; }
ERR(){ log ERROR "$*"; }

trap 'ERR "Ошибка на линии $LINENO: \"$BASH_COMMAND\""; exit 1' ERR

# ========= ФЛАГИ =========
DNS_DRY_RUN=false
for a in "$@"; do
  case "$a" in
    --dry-run) DNS_DRY_RUN=true ;;
  esac
done

# ========= УТИЛИТЫ =========
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
      INFO "Устанавливаю пакет $pkg (для $b)…"
      apt-get -y install --no-install-recommends "$pkg" >/dev/null
    else
      ERR "Не найден пакетный менеджер для установки $b"; exit 1
    fi
  fi
  command -v "$b" >/dev/null 2>&1 || { ERR "Не удалось установить $b"; exit 1; }
}

ensure_bin curl curl
ensure_bin dig  dnsutils
ensure_bin jq   jq
ensure_bin yq   yq

# ========= КОНФИГ =========
VARS_FILE="${VARS_FILE:-vars.yaml}"
[[ -f "$VARS_FILE" ]] || { ERR "vars.yaml не найден (ожидалось: $VARS_FILE)"; exit 1; }

# Чтение из vars.yaml с безопасным default=empty
yq_get(){ yq -r "${1} // empty" "$VARS_FILE"; }

DOMAIN="$(yq_get '.domain')"
HOSTNAME="$(yq_get '.hostname')"
IPV4="$(yq_get '.ipv4')"

# Блок Beget-кредов (поддержка login+token ИЛИ login+password)
BEGET_LOGIN="$(yq_get '.beget.login')"
BEGET_TOKEN="$(yq_get '.beget.token')"
BEGET_PASSWORD="$(yq_get '.beget.password')"   # опционально, на будущее

[[ -n "$DOMAIN" ]]   || { ERR "В vars.yaml не задан .domain"; exit 1; }
if [[ -z "${HOSTNAME}" || "${HOSTNAME}" == "null" ]]; then
  HOSTNAME="mail.${DOMAIN}"
fi
[[ -n "$IPV4" ]]     || { ERR "В vars.yaml не задан .ipv4"; exit 1; }

# Политики и дефолты
SPF_POLICY="${SPF_POLICY:-warn}"   # warn|append
TTL_DEFAULT="${TTL_DEFAULT:-3600}"

# Пути к state
MSA_STATE_DIR="${MSA_STATE_DIR:-/var/local/msa}"
MSA_MANIFEST="${MSA_MANIFEST:-$MSA_STATE_DIR/manifest.json}"
MSA_DKIM_TXT="${MSA_DKIM_TXT:-$MSA_STATE_DIR/dkim.txt}"

# ========= ВСПОМОГАТЕЛЬНЫЕ =========
trimdot(){ local s="${1:-}"; echo "${s%.}"; }

# Безопасное чтение из JSON-файла (если файла нет — пусто)
jq_safe_file(){ local file="$1" filter="$2"; [[ -f "$file" ]] || { echo ""; return 0; }; jq -r "${filter} // empty" "$file" 2>/dev/null || true; }
manifest_get(){ jq_safe_file "$MSA_MANIFEST" "$1"; }

# Нормализация имён
APEX_FQDN="$(trimdot "$DOMAIN")"
MAIL_FQDN="$(trimdot "$HOSTNAME")"

DKIM_SELECTOR="$(manifest_get '.dns.selector')"; [[ -z "$DKIM_SELECTOR" ]] && DKIM_SELECTOR="s1"
DKIM_FQDN="$(trimdot "${DKIM_SELECTOR}._domainkey.$DOMAIN")"
DMARC_FQDN="$(trimdot "_dmarc.$DOMAIN")"

# DKIM значение (если модуль 05 уже положил)
DKIM_VALUE=""
[[ -f "$MSA_DKIM_TXT" ]] && DKIM_VALUE="$(tr -d '\n' < "$MSA_DKIM_TXT")"

# DMARC дефолт + опциональный оверрайд из manifest.json
DMARC_VALUE_DEFAULT="v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN%.}"
dm="$(manifest_get '.dns.DMARC')"
[[ -n "$dm" ]] && DMARC_VALUE_DEFAULT="$dm"

INFO "Конфиг: domain=$APEX_FQDN, hostname=$MAIL_FQDN, ipv4=$IPV4, SPF_POLICY=$SPF_POLICY, TTL=$TTL_DEFAULT"
$DNS_DRY_RUN && INFO "Режим: DRY-RUN"

# ========= ПРОВЕРКА NS =========
ns_list="$(dig NS +short "$APEX_FQDN" | sed 's/\.$//')"
if [[ -z "$ns_list" ]]; then
  WARN "NS для $APEX_FQDN не получены — авто-DNS пропущен."
  exit 0
fi
if ! echo "$ns_list" | grep -qi 'beget'; then
  WARN "Домен $APEX_FQDN делегирован НЕ на Beget: $(echo "$ns_list" | tr '\n' ' ' | sed 's/ $//')"
  INFO "Пропускаю авто-DNS. Добавьте записи вручную."
  exit 0
fi
INFO "NS у $APEX_FQDN — Beget:"
echo "$ns_list" | sed 's/^/  - /'

# ========= Beget API =========
beget_auth_args(){
  [[ -n "$BEGET_LOGIN" ]] || { ERR "Для работы с Beget нужен .beget.login в vars.yaml"; exit 1; }
  if [[ -n "$BEGET_TOKEN" ]]; then
    printf "%s" \
      "-d" "login=$BEGET_LOGIN" \
      "-d" "token=$BEGET_TOKEN"
  elif [[ -n "$BEGET_PASSWORD" ]]; then
    printf "%s" \
      "-d" "login=$BEGET_LOGIN" \
      "-d" "passwd=$BEGET_PASSWORD"
  else
    ERR "В vars.yaml не задан ни .beget.token, ни .beget.password — не могу авторизоваться в Beget"
    exit 1
  fi
}

beget_api_post(){
  local path="$1" json="$2"
  curl -fsS --connect-timeout 15 --max-time 45 \
    -X POST "https://api.beget.com/api/dns/$path" \
    $(beget_auth_args) \
    -d "input_format=json" \
    -d "output_format=json" \
    --data-urlencode "input_data=$json"
}

api_ok(){
  jq -e '.status=="success" and ((.answer.status//"success")=="success")' >/dev/null 2>&1
}
api_errmsg(){
  jq -r '.answer.errors? // .error? // .answer.error_text? // .error_text? // .result.message? // "unknown error"' 2>/dev/null
}

dns_get(){
  local fqdn="$1"
  beget_api_post "getData" "$(jq -c --null-input --arg f "$fqdn" '{fqdn:$f}')"
}
dns_change(){
  local fqdn="$1" records_json="$2"
  beget_api_post "changeRecords" "$(jq -c --arg f "$fqdn" --argjson r "$records_json" '{fqdn:$f,records:$r}')"
}

# ========= РАБОТА С ЗАПИСЯМИ =========
sanitize_records(){
  jq -c 'if . == null then {} else
           with_entries(select(.key|IN("A","AAAA","CNAME","MX","TXT","SRV","CAA")))
         end'
}

# Вернуть первый SPF (чистый текст) либо пусто
extract_spf(){
  jq -r '(.TXT // []) | map(.value // .txtdata) | map(sub("^\"|\"$";"")) | map(select(test("^\\s*v=spf1\\b"; "i"))) | .[0] // empty'
}

# Добавить/обновить SPF с политикой warn|append
update_spf(){
  local recset="$1" policy="$2" host="$3" ttl="$4"
  local cur_spf new_spf
  cur_spf="$(echo "$recset" | extract_spf || true)"

  # policy=warn — если SPF уже есть, не трогаем
  if [[ "$policy" == "warn" && -n "$cur_spf" ]]; then
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
  # добавляем только если TXT нет вовсе
  if [[ "$(jq -r '.TXT | length // 0' <<<"$cur")" -gt 0 ]]; then
    echo "$cur"
  else
    jq -c --arg v "$dmarc" --argjson t "$ttl" '.TXT = [{value:$v, ttl:$t}]' <<<"$cur"
  fi
}

read_recset(){
  local fqdn="$1" resp recs
  resp="$(dns_get "$fqdn" || true)"
  if [[ -z "$resp" ]]; then echo "{}"; return; fi
  if echo "$resp" | api_ok; then
    recs="$(echo "$resp" | jq -c '.answer.result.records // {}' | sanitize_records)"
    [[ -z "$recs" ]] && echo "{}" || echo "$recs"
  else
    # FQDN может ещё не существовать — пусто ок
    echo "{}"
  fi
}

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
  local resp; resp="$(dns_change "$fqdn" "$after" || true)"
  if [[ -z "$resp" ]] || ! echo "$resp" | api_ok; then
    ERR "[$fqdn] ошибка changeRecords: $(echo "$resp" | api_errmsg)"
    exit 1
  fi
}

verify_api_has(){
  local fqdn="$1" jq_filter="$2"
  local r; r="$(dns_get "$fqdn" || true)"
  [[ -n "$r" ]] && echo "$r" | api_ok && echo "$r" | jq -e "$jq_filter" >/dev/null 2>&1
}

# ========= ПЛАН / ПРИМЕНЕНИЕ =========
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

# ========= ВЕРИФИКАЦИЯ =========
INFO "Верификация после применения…"
A_ok=false MX_ok=false
verify_api_has "$MAIL_FQDN"  --arg ip "$IPV4" '.answer.result.records.A[]?  | select((.value // .address) == $ip)' && A_ok=true
verify_api_has "$APEX_FQDN"  --arg m  "10 ${MAIL_FQDN}." '.answer.result.records.MX[]? | select((.value // (.preference|tostring+" "+.exchange)) == $m)' && MX_ok=true
INFO "Итог: A(mail)=$A_ok, MX(@)=$MX_ok"
INFO "Готово."
exit 0
