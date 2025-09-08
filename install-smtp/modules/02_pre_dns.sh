#!/usr/bin/env bash
# 02_pre_dns.sh — ранняя DNS-подготовка: A(@) и A(mail) на нужный IP через Beget API.
# НИКАКИЕ MX/TXT и т.п. не трогаем. Никакой рекурсии в 09_* не делаем.
# Требуются переменные из install.sh: DOMAIN, HOSTNAME, IPV4, VARS_FILE. Нужны: curl, dig, yq v4.

set -Eeuo pipefail
IFS=$'\n\t'

_log() { printf '[%(%FT%TZ)T] [%s] %s\n' -1 "$1" "$2"; }
INFO(){ _log INFO "$*"; }
WARN(){ _log WARN "$*"; }
ERROR(){ _log ERROR "$*"; }

: "${DOMAIN:?DOMAIN is required}"
: "${HOSTNAME:?HOSTNAME is required}"
: "${IPV4:?IPV4 is required}"
: "${VARS_FILE:?VARS_FILE is required}"

# Читаем креды и TTL из vars.yaml (mikefarah/yq v4)
BEGET_LOGIN="${BEGET_LOGIN:-$(yq -r '.beget.login // ""'    "$VARS_FILE" 2>/dev/null || true)}"
BEGET_PASSWORD="${BEGET_PASSWORD:-$(yq -r '.beget.password // ""' "$VARS_FILE" 2>/dev/null || true)}"
TTL_DEFAULT="$(yq -r '.dns_update.ttl_default // ""' "$VARS_FILE" 2>/dev/null || true)"
[[ "$TTL_DEFAULT" == "null" ]] && TTL_DEFAULT=""

have_beget_creds() { [[ -n "$BEGET_LOGIN" && -n "$BEGET_PASSWORD" ]]; }

beget_api() {
  # $1 = endpoint (getData|changeRecords), $2 = compact JSON input_data
  local endpoint="$1" input_data_json="$2"
  if ! have_beget_creds; then
    WARN "Beget API: креды не заданы — пропускаю вызов ${endpoint}"
    return 2
  fi
  curl -fsS -X POST "https://api.beget.com/api/dns/${endpoint}" \
    -d "login=${BEGET_LOGIN}" \
    -d "passwd=${BEGET_PASSWORD}" \
    -d "input_format=json" \
    --data-urlencode "input_data=${input_data_json}"
}

get_records() {
  # payload строго как в 09_*: {"fqdn":"example.com"}
  local fqdn="$1"
  beget_api "getData" "{\"fqdn\":\"${fqdn}\"}" || true
}

change_a_records() {
  # payload строго как в 09_*: {"fqdn":"...","records":{"A":[{"value":"IP","ttl":N}]}}
  local fqdn="$1" ip="$2" ttl="$3"
  local rec
  if [[ -n "$ttl" ]]; then
    rec="{\"A\":[{\"value\":\"${ip}\",\"ttl\":${ttl}}]}"
  else
    rec="{\"A\":[{\"value\":\"${ip}\"}]}"
  fi
  beget_api "changeRecords" "{\"fqdn\":\"${fqdn}\",\"records\":${rec}}" || true
}

ensure_a_record() {
  local fqdn="$1" want_ip="$2" ttl="$3"

  INFO "Ранняя DNS: проверяю A(${fqdn})"
  local pub_ip
  pub_ip="$(dig +short A "${fqdn}" @8.8.8.8 | head -n1 || true)"

  if [[ "$pub_ip" == "$want_ip" ]]; then
    INFO "A(${fqdn}) уже указывает на ${want_ip} — ок"
    return 0
  fi

  if ! have_beget_creds; then
    WARN "A(${fqdn}) != ${want_ip}, но кред Бегета не заданы — оставляю как есть"
    return 0
  fi

  # Для логов — убедимся, что домен реально у Бегета
  local resp status
  resp="$(get_records "$fqdn")" || true
  status="$(printf '%s' "$resp" | yq -p=json -r '.answer.status // "error"' 2>/dev/null || echo error)"
  if [[ "$status" != "success" ]]; then
    WARN "Beget getData(${fqdn}) => error; всё равно попытаюсь сменить A"
  fi

  local ch ch_status err
  ch="$(change_a_records "$fqdn" "$want_ip" "$ttl")" || true
  ch_status="$(printf '%s' "$ch" | yq -p=json -r '.answer.status // "error"' 2>/dev/null || echo error)"

  if [[ "$ch_status" != "success" ]]; then
    err="$(printf '%s' "$ch" | yq -p=json -o=yaml '.answer.errors // .answer' 2>/dev/null || true)"
    ERROR "Не удалось применить A(${fqdn}) → ${want_ip}: ${err}"
    return 1
  fi

  INFO "A(${fqdn}) → ${want_ip} отправлено через API Бегета"
  return 0
}

main() {
  INFO "Ранняя DNS-подготовка: приводим A(@) и A(${HOSTNAME}) к ${IPV4}"
  ensure_a_record "${DOMAIN}"   "${IPV4}" "${TTL_DEFAULT}" || true
  ensure_a_record "${HOSTNAME}" "${IPV4}" "${TTL_DEFAULT}" || true
}

main "$@"
