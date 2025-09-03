# modules/05_dkim.sh — OpenDKIM: ключ, конфиг, интеграция с Postfix, DNS-TXT для manifest
# Требует: DOMAIN, HOSTNAME, IPV4, VARS_FILE, DRY_RUN
# Функции: run_cmd, log_info, log_warn, log_error, die, require_cmd
# shellcheck shell=bash

dkim::paths() {
  DKIM_ETC="/etc/opendkim"
  DKIM_KEYS_DIR="${DKIM_ETC}/keys/${DOMAIN}"
  DKIM_KEYTABLE="${DKIM_ETC}/key.table"
  DKIM_SIGNING="${DKIM_ETC}/signing.table"
  DKIM_TRUSTED="${DKIM_ETC}/trusted.hosts"
  DKIM_CONF="${DKIM_ETC}/opendkim.conf"
  DKIM_DEFAULTS="/etc/default/opendkim"

  DKIM_SELECTOR="$(yq -r '.dkim_selector // "s1"' "${VARS_FILE}")"
  DKIM_PRIV="${DKIM_KEYS_DIR}/${DKIM_SELECTOR}.private"
  DKIM_PUBTXT="${DKIM_KEYS_DIR}/${DKIM_SELECTOR}.txt"

  DKIM_SOCKET_DIR="/var/spool/postfix/opendkim"
  DKIM_SOCKET="local:${DKIM_SOCKET_DIR}/opendkim.sock"
}

dkim::require_bins() {
  require_cmd opendkim-genkey
  require_cmd opendkim
  require_cmd postconf
}

dkim::ensure_dirs() {
  dkim::paths
  run_cmd "install -d -m 0750 -o opendkim -g opendkim '${DKIM_KEYS_DIR}'"
  run_cmd "install -d -m 0750 -o opendkim -g postfix  '${DKIM_SOCKET_DIR}'"
}

dkim::ensure_key() {
  dkim::paths
  if [[ -r "${DKIM_PRIV}" && -r "${DKIM_PUBTXT}" ]]; then
    log_info "OpenDKIM: ключ уже существует (${DKIM_SELECTOR} @ ${DOMAIN}) — пропускаю генерацию"
    run_cmd "chown opendkim:opendkim '${DKIM_PRIV}' '${DKIM_PUBTXT}' || true"
    run_cmd "chmod 0600 '${DKIM_PRIV}' || true"
    return 0
  fi

  log_info "OpenDKIM: генерирую 2048-бит ключ (selector=${DKIM_SELECTOR}, domain=${DOMAIN})"
  run_cmd "opendkim-genkey -b 2048 -s '${DKIM_SELECTOR}' -d '${DOMAIN}' -D '${DKIM_KEYS_DIR}'"
  run_cmd "chown opendkim:opendkim '${DKIM_PRIV}' '${DKIM_PUBTXT}'"
  run_cmd "chmod 0600 '${DKIM_PRIV}'"
}

dkim::write_tables() {
  dkim::paths
  log_info "OpenDKIM: пишу KeyTable/SigningTable/TrustedHosts"

  local tmp kt st th
  kt="$(mktemp)"; st="$(mktemp)"; th="$(mktemp)"

  # KeyTable: selector._domainkey.domain domain:selector:/path/to/private
  printf '%s._domainkey.%s %s:%s:%s\n' "${DKIM_SELECTOR}" "${DOMAIN}" "${DOMAIN}" "${DKIM_SELECTOR}" "${DKIM_PRIV}" > "${kt}"

  # SigningTable: *@domain selector._domainkey.domain
  printf '*@%s %s._domainkey.%s\n' "${DOMAIN}" "${DKIM_SELECTOR}" "${DOMAIN}" > "${st}"

  # TrustedHosts: локалхосты + наш hostname и IPv4
  {
    echo '127.0.0.1'
    echo '::1'
    echo 'localhost'
    echo "${HOSTNAME}"
    [[ -n "${IPV4:-}" ]] && echo "${IPV4}"
  } > "${th}"

  run_cmd "install -m 0640 -o root -g opendkim '${kt}' '${DKIM_KEYTABLE}'"
  run_cmd "install -m 0640 -o root -g opendkim '${st}' '${DKIM_SIGNING}'"
  run_cmd "install -m 0640 -o root -g opendkim '${th}' '${DKIM_TRUSTED}'"
  rm -f "${kt}" "${st}" "${th}"
}

dkim::write_conf() {
  dkim::paths
  log_info "OpenDKIM: пишу конфигурацию и defaults (socket=${DKIM_SOCKET})"

  local tmpc tmpd
  tmpc="$(mktemp)"
  cat > "${tmpc}" <<EOF
# Managed by msa-install — DO NOT EDIT
Syslog                  yes
UMask                   002
UserID                  opendkim:opendkim

Mode                    sv
Canonicalization        relaxed/simple
Selector                ${DKIM_SELECTOR}

KeyTable                ${DKIM_KEYTABLE}
SigningTable            refile:${DKIM_SIGNING}
ExternalIgnoreList      refile:${DKIM_TRUSTED}
InternalHosts           refile:${DKIM_TRUSTED}

Socket                  ${DKIM_SOCKET}
PidFile                 /var/run/opendkim/opendkim.pid

# Безопасные протоколы/ключи по умолчанию у OpenSSL
EOF
  run_cmd "install -m 0644 '${tmpc}' '${DKIM_CONF}'"
  rm -f "${tmpc}"

  # /etc/default/opendkim — зафиксируем SOCKET (у некоторых сборок важнее конфиг)
  tmpd="$(mktemp)"
  cat > "${tmpd}" <<EOF
# Managed by msa-install — DO NOT EDIT
SOCKET="${DKIM_SOCKET}"
RUNDIR=/var/run/opendkim
USER=opendkim
GROUP=opendkim
EOF
  run_cmd "install -m 0644 '${tmpd}' '${DKIM_DEFAULTS}'"
  rm -f "${tmpd}"
}

# Аккуратно добавить наш milter в Postfix (не ломая уже заданные)
dkim::configure_postfix_milter() {
  dkim::paths
  local sock="unix:${DKIM_SOCKET_DIR}/opendkim.sock"

  # smtpd_milters
  local cur; cur="$(postconf -h smtpd_milters || true)"
  if [[ -z "${cur}" ]]; then
    new="${sock}"
  else
    if grep -q "${sock//\//\\/}" <<<"${cur}"; then
      new="${cur}"
    else
      new="${cur},${sock}"
    fi
  fi
  run_cmd "postconf -e 'smtpd_milters=${new}'"

  # non_smtpd_milters
  cur="$(postconf -h non_smtpd_milters || true)"
  if [[ -z "${cur}" ]]; then
    new="${sock}"
  else
    if grep -q "${sock//\//\\/}" <<<"${cur}"; then
      new="${cur}"
    else
      new="${cur},${sock}"
    fi
  fi
  run_cmd "postconf -e 'non_smtpd_milters=${new}'"

  # Базовые параметры milter’ов
  run_cmd "postconf -e 'milter_default_action=accept'"
  run_cmd "postconf -e 'milter_protocol=6'"
}

dkim::reload_enable() {
  # Проверим единицы, поднимем сервис, перезагрузим Postfix
  run_cmd "systemctl enable --now opendkim"
  run_cmd "systemctl restart opendkim"
  run_cmd "systemctl reload postfix || systemctl restart postfix"
}

dkim::export_manifest_vars() {
  dkim::paths
  export DKIM_SELECTOR="${DKIM_SELECTOR}"

  # Достаём TXT-значение, склеивая строки и убирая кавычки/скобки
  local txt=""
  if [[ -r "${DKIM_PUBTXT}" ]]; then
    # opendkim-genkey кладёт файл вроде: s1._domainkey IN TXT ( "v=DKIM1; k=rsa; p=ABCD..." ) ; склеим в одну строку
    txt="$(sed -E 's/^\s+|\s+$//g; s/\(//; s/\)//; s/\"//g' "${DKIM_PUBTXT}" | tr -d '\n' | sed -E 's/.*TXT[[:space:]]*//; s/^[[:space:]]+//')"
    # На выходе должно быть: v=DKIM1; k=rsa; p=...
  fi
  export DKIM_TXT="${txt}"
  if [[ -z "${DKIM_TXT}" ]]; then
    log_warn "OpenDKIM: не удалось извлечь TXT из ${DKIM_PUBTXT}; DNS-запись будет пустой"
  else
    log_info "OpenDKIM: подготовлена DNS TXT для ${DKIM_SELECTOR}._domainkey.${DOMAIN} (длина=$(printf '%s' "${DKIM_TXT}" | wc -c))"
  fi
}

# --- ENTRYPOINT ---
dkim::paths
dkim::require_bins
dkim::ensure_dirs
dkim::ensure_key
dkim::write_tables
dkim::write_conf
dkim::configure_postfix_milter
dkim::reload_enable
dkim::export_manifest_vars
