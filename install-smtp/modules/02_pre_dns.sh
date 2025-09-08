#!/usr/bin/env bash
# Ранняя подготовка DNS:
# - проверяем A(@) и A(mail.<domain>) на авторитативных NS Beget
# - если не наш IP — применяем 09_beget_dns.sh, чтобы выставить наш
# - ждём появления правильных A (авторитативы -> 8.8.8.8)
#
# Требует окружение: DOMAIN, HOSTNAME, IPV4, VARS_FILE
# Использует хелперы из install.sh: run_cmd, log_info/log_warn/log_error

set -Eeuo pipefail
IFS=$'\n\t'

: "${DOMAIN:?}"
: "${HOSTNAME:?}"
: "${IPV4:?}"
: "${VARS_FILE:?}"

_pre_dns::auth_ns() { echo ns1.beget.com ns2.beget.com ns1.beget.ru ns2.beget.ru ns1.beget.pro ns2.beget.pro; }

_pre_dns::a_on_ns() { # fqdn ns -> prints IPs (one per line)
  local fqdn="$1" ns="$2"
  dig +short A "$fqdn" @"$ns" 2>/dev/null | sed 's/\s\+$//'
}

_pre_dns::has_ip_on_auth() { # fqdn ip -> return 0 if ip present on ANY authoritative NS
  local fqdn="$1" ip="$2"
  local ns
  for ns in $(_pre_dns::auth_ns); do
    if _pre_dns::a_on_ns "$fqdn" "$ns" | grep -Fxq "$ip"; then
      return 0
    fi
  done
  return 1
}

_pre_dns::wait_a() { # fqdn ip [timeout_sec]
  local fqdn="$1" ip="$2" timeout="${3:-180}" t=0
  # 1) Ждём авторитативы
  while (( t < timeout )); do
    if _pre_dns::has_ip_on_auth "$fqdn" "$ip"; then
      log_info "DNS: $fqdn -> $ip подтвержден на авторитативных NS"
      break
    fi
    sleep 5; t=$((t+5))
  done
  # 2) Ждём 8.8.8.8 (кэш)
  t=0
  while (( t < timeout )); do
    if dig +short A "$fqdn" @8.8.8.8 2>/dev/null | grep -Fxq "$ip"; then
      log_info "DNS: $fqdn -> $ip подтвержден на 8.8.8.8"
      return 0
    fi
    sleep 5; t=$((t+5))
  done
  return 1
}

_pre_dns::have_beget_creds() {
  local login pass
  login="$(yq -r '.beget.login // ""' "${VARS_FILE}" 2>/dev/null || true)"
  pass="$(yq -r '.beget.password // ""' "${VARS_FILE}" 2>/dev/null || true)"
  [[ -n "$login" && -n "$pass" ]]
}

_pre_dns::apply_with_module09() {
  local moddir; moddir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "${moddir}/09_beget_dns.sh" ]]; then
    log_info "Beget: запускаю 09_beget_dns.sh для приведения A к ${IPV4}"
    run_cmd bash "${moddir}/09_beget_dns.sh"
  else
    log_warn "Beget: модуль 09_beget_dns.sh не найден — не могу изменить A"
  fi
}

# ---------- ENTRYPOINT ----------
log_info "Ранняя DNS-подготовка: проверяю A(@) и A(${HOSTNAME})"

# Beget гарантирует наличие A у apex — проверяем, что он «наш»
apex_ok=false
host_ok=false

if _pre_dns::has_ip_on_auth "${DOMAIN}" "${IPV4}"; then
  log_info "A(${DOMAIN}) уже указывает на ${IPV4} — ок"
  apex_ok=true
else
  log_warn "A(${DOMAIN}) указывает не на наш IP — потребуется обновление"
fi

if _pre_dns::has_ip_on_auth "${HOSTNAME}" "${IPV4}"; then
  log_info "A(${HOSTNAME}) уже указывает на ${IPV4} — ок"
  host_ok=true
else
  log_warn "A(${HOSTNAME}) указывает не на наш IP — потребуется обновление"
fi

# Если что-то не сходится — меняем IP через наш модуль 09 (идемпотентный)
if [[ "${apex_ok}" != true || "${host_ok}" != true ]]; then
  if _pre_dns::have_beget_creds; then
    _pre_dns::apply_with_module09
  else
    log_warn "Beget: креды не заданы в vars.yaml — не могу обновить A; продолжу установку"
  fi
fi

# Подождём, пока в зоне появятся нужные A — это ускорит выпуск LE в 06_ssl.sh
_pre_dns::wait_a "${HOSTNAME}" "${IPV4}" 180 || log_warn "DNS: ${HOSTNAME} -> ${IPV4} не дождались (продолжу)"
_pre_dns::wait_a "${DOMAIN}"   "${IPV4}"  60  || log_warn "DNS: ${DOMAIN} -> ${IPV4} не дождались (некритично)"
