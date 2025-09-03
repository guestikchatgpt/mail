# modules/99_healthcheck.sh — интеграционные проверки сервисов
# Требует функции: log_info, log_warn, log_error, require_cmd
# Требует переменные: DOMAIN, HOSTNAME, IPV4, VARS_FILE
# Ничего не изменяет, только читает.
# shellcheck shell=bash

healthcheck::require_bins() {
  require_cmd openssl
  # ss предпочтительней; если нет — попробуем lsof; иначе /dev/tcp
  command -v ss >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1 || true
  # dig или host для PTR
  command -v dig >/dev/null 2>&1 || command -v host >/dev/null 2>&1 || true
}

healthcheck::_is_port_listening() {
  # usage: healthcheck::_is_port_listening 587  -> 0/1
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | sed -n 's/.*:\([0-9]\+\)$/\1/p' | grep -qx "$port"
    return $?
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  else
    # Последний шанс: попытка TCP connect (может зависнуть). Дадим короткий таймаут через bash read.
    # Откроем /dev/tcp и тут же закроем.
    ( exec 3<>"/dev/tcp/127.0.0.1/${port}" ) >/dev/null 2>&1
    return $?
  fi
}

healthcheck::check_ports() {
  log_info "HC: проверяю, что почтовые порты слушаются (25,465,587,993,995)"
  local p
  for p in 25 465 587 993 995; do
    if healthcheck::_is_port_listening "$p"; then
      eval "export PORT_${p}=open"
      log_info "HC: порт ${p} — LISTEN"
    else
      eval "export PORT_${p}=closed"
      log_warn "HC: порт ${p} — НЕ слушается"
    fi
  done
}

# Вспомогательная: выполнить s_client с таймаутом
healthcheck::_s_client() {
  # usage: healthcheck::_s_client args...
  # пытаемся ограничить выполнение; timeout может отсутствовать — тогда без него
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 3 10 openssl s_client "$@"
  else
    openssl s_client "$@"
  fi
}

# Вставь вместо старой функции healthcheck::check_tls
healthcheck::check_tls() {
  log_info "HC: TLS проверки SMTPS(465), IMAPS(993) и STARTTLS на 587"

  _tls_ok() { # host port [starttls_proto]
    local host="$1" port="$2" starttls="${3:-}"
    local out rc
    if [[ -n "$starttls" ]]; then
      out="$(timeout 10s openssl s_client -brief -verify_hostname "$host" -starttls "$starttls" -connect "$host:$port" </dev/null 2>&1 || true)"
    else
      out="$(timeout 10s openssl s_client -brief -verify_hostname "$host" -connect "$host:$port" </dev/null 2>&1 || true)"
    fi
    rc=$?
    # Успех, если:
    # - команда вернулась с кодом 0 И
    # - в выводе есть "Verification: OK" или "Verify return code: 0" И
    # - peername совпал
    if [[ $rc -eq 0 ]] && \
       echo "$out" | grep -Eq 'Verification: OK|Verify return code: 0' && \
       echo "$out" | grep -Fq "Verified peername: $host"; then
      echo "ok"; return 0
    fi
    log_error "HC: ${port} $( [[ -n $starttls ]] && echo SMTP STARTTLS || echo TLS ) — ошибка TLS/hostname. Вывод: $out"
    echo "error"; return 1
  }

  local h="$HOSTNAME"
  export HC_SMTPS_465="$(_tls_ok "$h" 465 || true)"
  export HC_IMAPS_993="$(_tls_ok "$h" 993 || true)"
  export HC_SMTP_587_STARTTLS="$(_tls_ok "$h" 587 smtp || true)"
}


healthcheck::check_rdns_helo() {
  log_info "HC: проверка PTR(rDNS) и баннера Postfix (HELO)"

  # PTR
  local ptr=""
  if command -v dig >/dev/null 2>&1; then
    ptr="$(dig -x "${IPV4}" +short 2>/dev/null | sed -n '1s/\.$//p')"
  elif command -v host >/dev/null 2>&1; then
    ptr="$(host "${IPV4}" 2>/dev/null | awk '/domain name pointer/ {print $5}' | sed 's/\.$//')"
  fi

  if [[ -z "$ptr" ]]; then
    export HC_HELO_MATCHES_PTR="error"
    log_error "HC: PTR для ${IPV4} не найден"
    return
  fi

  if [[ "${ptr}" != "${HOSTNAME}" ]]; then
    export HC_HELO_MATCHES_PTR="error"
    log_error "HC: PTR (${ptr}) != HOSTNAME (${HOSTNAME})"
  else
    # Проверим баннер на 25
    local banner=""
    # /dev/tcp без зависимостей; таймаут чтения 5 сек
    exec 3<>"/dev/tcp/127.0.0.1/25" || {
      export HC_HELO_MATCHES_PTR="error"
      log_error "HC: не удалось подключиться к localhost:25 для чтения баннера"
      return
    }
    # читаем строку баннера
    IFS= read -r -t 5 banner <&3 || true
    printf 'QUIT\r\n' >&3 || true
    exec 3>&- || true
    if grep -q "${HOSTNAME}" <<<"$banner"; then
      export HC_HELO_MATCHES_PTR="ok"
      log_info "HC: SMTP баннер содержит ${HOSTNAME}, PTR совпадает"
    else
      export HC_HELO_MATCHES_PTR="error"
      log_error "HC: SMTP баннер не содержит ${HOSTNAME}. Баннер: ${banner}"
    fi
  fi
}

healthcheck::check_dkim() {
  log_info "HC: проверка DKIM (opendkim-testkey)"
  local selector privkey out rc
  selector="$(yq -r '.dkim_selector // "s1"' "${VARS_FILE}")"
  privkey="/etc/opendkim/keys/${DOMAIN}/${selector}.private"

  if ! command -v opendkim-testkey >/dev/null 2>&1; then
    export HC_DKIM_SIGN="error"
    log_error "HC: отсутствует opendkim-testkey — пропускаю проверку"
    return
  fi
  if [[ ! -r "$privkey" ]]; then
    export HC_DKIM_SIGN="error"
    log_error "HC: приватный ключ DKIM не найден: ${privkey}"
    return
  fi

  # opendkim-testkey вернёт 0, если DNS-запись доступна и корректна
  out="$(opendkim-testkey -d "${DOMAIN}" -s "${selector}" -k "${privkey}" -vv 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    export HC_DKIM_SIGN="ok"
    log_info "HC: DKIM testkey ok (selector=${selector})"
  else
    export HC_DKIM_SIGN="error"
    log_error "HC: DKIM testkey FAIL (selector=${selector}). Вывод: ${out}"
  fi
}

healthcheck::run_all() {
  healthcheck::require_bins
  healthcheck::check_ports
  healthcheck::check_tls
  healthcheck::check_rdns_helo
  healthcheck::check_dkim
  log_info "HC: проверки завершены"
}

# --- ENTRYPOINT ---
healthcheck::run_all
