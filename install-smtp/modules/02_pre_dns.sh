#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../lib/log.sh"   # log::info / log::warn / log::err
. "$(dirname "$0")/../lib/yaml.sh"  # yq v4 уже ставим в 01_prepare.sh

DOMAIN="$(yq -r '.domain' "${VARS_FILE}")"
HOSTNAME="$(yq -r '.hostname' "${VARS_FILE}")"
IPV4="$(yq -r '.ipv4' "${VARS_FILE}")"
BEGET_LOGIN="$(yq -r '.beget.login' "${VARS_FILE}")"
BEGET_PASSWORD="$(yq -r '.beget.password' "${VARS_FILE}")"

mail_host="$(printf '%s' "${HOSTNAME:-mail.${DOMAIN}}")"

log::info "Ранняя DNS-подготовка: приводим A(@) и A(${mail_host}) к ${IPV4}"

api() {
  # универсальный вызов API Бегета
  local method="$1"; shift
  curl -fsS -G "https://api.beget.com/api/dns/${method}" \
    --data-urlencode "login=${BEGET_LOGIN}" \
    --data-urlencode "passwd=${BEGET_PASSWORD}" \
    "$@"
}

ensure_a() {
  local name="$1"  # '@' или FQDN
  local value="$2" # IPv4
  local fqdn
  if [[ "$name" == "@" ]]; then
    fqdn="${DOMAIN}"
  else
    fqdn="$name"
  fi

  log::info "Ранняя DNS: проверяю A(${fqdn})"
  # пытаемся получить текущую запись из публичного DNS
  if dig +short A "${fqdn}" @8.8.8.8 | grep -qx "${value}"; then
    log::info "A(${fqdn}) = ${value} — ок"
    return 0
  fi

  # на стороне Бегета: если домен у Бегета, обновим/создадим
  # Бегет не даёт получить «одну» запись надёжно без getData; но это не критично
  # просто отправляем changeRecords — он сам заменит/создаст A
  # name: '@' для апекса, либо 'mail' для poddomain
  local relative
  if [[ "$name" == "@" ]]; then
    relative="@"
  else
    # вытаскиваем относительное имя к зоне
    relative="${fqdn%.$DOMAIN}"
  fi

  payload=$(cat <<JSON
{
  "input_data": {
    "fqdn": "${DOMAIN}",
    "records": [
      {
        "name": "${relative}",
        "ttl": 3600,
        "type": "A",
        "data": "${value}"
      }
    ]
  }
}
JSON
)
  # changeRecords
  if ! api "changeRecords" --data-urlencode "input_data=${payload}" >/dev/null; then
    log::warn "Beget changeRecords(${fqdn}) => error; всё равно двигаемся дальше"
  else
    log::info "A(${fqdn}) → ${value} отправлено через API Бегета"
  fi
}

# Порядок: @ потом mail
ensure_a "@" "${IPV4}"
ensure_a "${mail_host}" "${IPV4}"
