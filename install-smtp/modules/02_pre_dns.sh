#!/usr/bin/env bash
# Ранняя подготовка DNS: выкладываем A-записи для @ и mail.<domain> через Beget,
# затем ждём появления на авторитативных NS. Это ускорит получение LE-серта.
#
# Требует окружение/хелперы из install.sh: DOMAIN, HOSTNAME, IPV4, VARS_FILE,
# а также run_cmd, log_info/log_warn/log_error.

set -Eeuo pipefail
IFS=$'\n\t'

: "${DOMAIN:?}"
: "${HOSTNAME:?}"
: "${IPV4:?}"
: "${VARS_FILE:?}"

_pre_dns::auth_ns() { echo ns1.beget.com ns2.beget.com ns1.beget.ru ns2.beget.ru ns1.beget.pro ns2.beget.pro; }

_pre_dns::wait_a() { # fqdn ip [timeout_sec]
  local fqdn="$1" ip="$2" timeout="${3:-180}" t=0
  while (( t < timeout )); do
    for ns in $(_pre_dns::auth_ns); do
      if dig +short A "$fqdn" @"$ns" | grep -Fxq "$ip"; then
        log_info "DNS: $fqdn -> $ip найден на $ns"
        return 0
      fi
    done
    sleep 5; t=$((t+5))
  done
  return 1
}

_pre_dns::run_full_beget_module() {
  # Просто дергаем штатный модуль 09 — он уже умеет всё делать idempotent.
  # Ранний прогон — только плюс: записи начнут распространяться заранее.
  local moddir; moddir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "${moddir}/09_beget_dns.sh" ]]; then
    log_info "Beget: ранний прогон 09_beget_dns.sh (seed A-записей)"
    # Запуск в отдельном процессе: пусть он сам читает vars и применяет изменения
    run_cmd bash "${moddir}/09_beget_dns.sh"
  else
    log_warn "Beget: модуль 09_beget_dns.sh не найден — пропускаю раннюю выкладку"
  fi
}

_pre_dns::ensure_beget_creds() {
  # если не заданы логин/пароль — тихо выходим (ничего не ломаем)
  local login pass
  login="$(yq -r '.beget.login // ""' "${VARS_FILE}" 2>/dev/null || true)"
  pass="$(yq -r '.beget.password // ""' "${VARS_FILE}" 2>/dev/null || true)"
  if [[ -z "$login" || -z "$pass" ]]; then
    log_warn "Beget: креды не заданы в vars.yaml — пропускаю раннюю выкладку A"
    return 1
  fi
  return 0
}

# ---------- ENTRYPOINT ----------
log_info "Ранняя DNS-подготовка: A-записи для @ и ${HOSTNAME}"
if _pre_dns::ensure_beget_creds; then
  _pre_dns::run_full_beget_module

  # Ждём появления A-записей на авторитативах (лучше 1 раз подождать здесь,
  # чтобы 06_ssl не тормозил).
  if _pre_dns::wait_a "${HOSTNAME}" "${IPV4}" 180; then
    log_info "DNS: ${HOSTNAME} -> ${IPV4} подтверждён"
  else
    log_warn "DNS: ${HOSTNAME} -> ${IPV4} не дождались на авторитативах (продолжу установку)"
  fi

  # Apex A — опционально (если ты не хочешь A(@), просто проигнорируй результат)
  if _pre_dns::wait_a "${DOMAIN}" "${IPV4}" 60; then
    log_info "DNS: ${DOMAIN} -> ${IPV4} подтверждён"
  else
    log_warn "DNS: ${DOMAIN} -> ${IPV4} не подтверждён (не критично)"
  fi
fi
