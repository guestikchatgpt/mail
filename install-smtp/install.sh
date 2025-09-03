#!/usr/bin/env bash
set -euo pipefail

# --- раннее логирование во встроенный файл + на экран ---
LOG_DIR="/var/log/msa"
mkdir -p "${LOG_DIR}"
export LOG_FILE="${LOG_DIR}/install-$(date -u +%Y%m%d-%H%M%S).log"
# Дублируем stdout/stderr и в файл, и на экран
exec > >(tee -a "${LOG_FILE}") 2>&1

# --- bootstrap logger used до загрузки общих хелперов ---
if [[ "$(type -t log 2>/dev/null)" != "function" ]]; then
  log(){ printf '[%(%FT%TZ)T] [%s] %s\n' -1 "${1:-INFO}" "${*:2}"; }
fi
if [[ "$(type -t run 2>/dev/null)" != "function" ]]; then
  run(){ log INFO "RUN: $*"; "$@"; }
fi
# --- конец бутстрапа ---

# --- paths --------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"
LIB_DIR="${SCRIPT_DIR}/lib"

# --- libs ---------------------------------------------------------------------
# shellcheck disable=SC1090
source "${LIB_DIR}/common.sh"   # die, run_cmd, require_cmd, log_*

# --- globals ------------------------------------------------------------------
VARS_FILE=""
MODE="install"        # install | healthcheck | print-dns
DRY_RUN=false

# --- utils --------------------------------------------------------------------
require_yq_v4() {
  require_cmd yq
  local out major
  out="$(yq -V 2>&1 || true)"
  major="$(grep -oE '[0-9]+' <<<"$out" | head -n1 || true)"
  if [[ -z "${major:-}" || "${major}" -lt 4 ]]; then
    die "Нужен yq v4+, найдено: ${out:-unknown}"
  fi
}

ensure_root_if_needed() {
  if [[ "${DRY_RUN}" == "false" && "${EUID}" -ne 0 ]]; then
    die "Нужны root-привилегии (sudo) для режима установки"
  fi
}

# ===== ensure yq v4+ (автоустановка при необходимости) =====
ensure_yq_v4() {
  _log(){ printf '[%(%FT%TZ)T] [%s] %s\n' -1 "${1:-INFO}" "${*:2}"; }

  local need_major=4 cur="" major=""
  if command -v yq >/dev/null 2>&1; then
    cur="$(yq --version 2>/dev/null || true)"   # e.g. "yq (...) version v4.47.1"
    major="$(printf '%s\n' "$cur" | sed -n 's/.*version v\{0,1\}\([0-9]\+\).*/\1/p')"
    if [[ -n "$major" && "$major" -ge "$need_major" ]]; then
      _log INFO "yq найден: ${cur}"
      return 0
    fi
    _log WARN "нужен yq v4+, найдено: ${cur:-unknown} — обновляю бинарник"
  else
    _log INFO "yq не найден — ставлю свежий v4"
  fi

  if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    _log INFO "ставлю wget для загрузки yq…"
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get -y install wget ca-certificates >/dev/null 2>&1 || true
  fi

  local url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
  if command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O /usr/local/bin/yq
  else
    curl -fsSL "$url" -o /usr/local/bin/yq
  fi
  chmod +x /usr/local/bin/yq || true

  local newver; newver="$(yq --version 2>/dev/null || true)"
  if ! grep -q 'version v4' <<<"$newver"; then
    _log ERROR "не удалось установить yq v4 (текущее: ${newver})"
    exit 1
  fi
  _log INFO "yq установлен: ${newver}"
}

ensure_yq_v4

usage() {
  printf '%s\n' \
"usage: $0 --vars vars.yaml [--dry-run] [--healthcheck] [--print-dns]
  --vars FILE      путь к vars.yaml (обязателен для install/print-dns)
  --dry-run        не выполнять изменяющие команды
  --healthcheck    запустить только 99_healthcheck.sh
  --print-dns      вывести DNS-записи (A/MX/SPF/DKIM/DMARC)
  -h, --help       показать эту справку"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vars|-f)
        [[ $# -ge 2 ]] || die "--vars требует путь к файлу"
        VARS_FILE="$2"; shift 2;;
      --dry-run)
        DRY_RUN=true; shift;;
      --healthcheck|-m)
        # Совместимость: -m healthcheck
        if [[ "$1" == "-m" ]]; then
          [[ $# -ge 2 ]] || die "-m требует значение (install|healthcheck|print-dns)"
          MODE="$2"; shift 2
        else
          MODE="healthcheck"; shift
        fi
        ;;
      --print-dns)
        MODE="print-dns"; shift;;
      -h|--help)
        usage; exit 0;;
      *)
        die "Неизвестный аргумент: $1";;
    esac
  done
  if [[ -z "${VARS_FILE}" && "${MODE}" != "healthcheck" ]]; then
    die "Укажите --vars <file>"
  fi
}

load_and_validate_vars() {
  require_yq_v4
  [[ -r "${VARS_FILE}" ]] || die "vars.yaml не найден: ${VARS_FILE}"

  export DOMAIN HOSTNAME IPV4 ACCEPT_INBOUND ACME_EMAIL DKIM_SELECTOR

  DOMAIN="$(yq -r '.domain // ""' "${VARS_FILE}")"
  HOSTNAME="$(yq -r ".hostname // (\"mail.\" + .domain)" "${VARS_FILE}")"
  IPV4="$(yq -r '.ipv4 // ""' "${VARS_FILE}")"
  ACME_EMAIL="$(yq -r ".acme_email // (\"postmaster@\" + .domain)" "${VARS_FILE}")"
  DKIM_SELECTOR="$(yq -r ".dkim_selector // \"s1\"" "${VARS_FILE}")"

  # accept_inbound: явный флаг имеет приоритет; иначе — по mode (default full_mail)
  if yq -e '.accept_inbound' "${VARS_FILE}" >/dev/null 2>&1; then
    ACCEPT_INBOUND="$(yq -r '.accept_inbound' "${VARS_FILE}")"
  else
    MODE_MAIL="$(yq -r '.mode // "full_mail"' "${VARS_FILE}")"
    if [[ "${MODE_MAIL}" == "outbound_only" ]]; then
      ACCEPT_INBOUND="false"
    else
      ACCEPT_INBOUND="true"
    fi
  fi

  local users_count
  users_count="$(yq -r '.users // [] | length' "${VARS_FILE}")"

  [[ -n "${DOMAIN}"   ]] || die "В vars.yaml отсутствует domain"
  [[ -n "${HOSTNAME}" ]] || die "В vars.yaml отсутствует hostname/логика подстановки"
  [[ -n "${IPV4}"    ]] || die "В vars.yaml отсутствует ipv4"
  [[ "${users_count}" -ge 1 ]] || die "В vars.yaml нет пользователей (.users)"

  if ! grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<<"${IPV4}"; then
    die "Неверный формат IPv4: ${IPV4}"
  fi

  log_info "vars.yaml ок: domain=${DOMAIN}, hostname=${HOSTNAME}, ipv4=${IPV4}, users=${users_count}, mode=${MODE}, accept_inbound=${ACCEPT_INBOUND}, dry_run=${DRY_RUN}"
}

# --- module loader ------------------------------------------------------------
source_modules_install() {
  # Загрузим ВСЕ модули вида NN_name.sh (включая 100_report.sh и т.д.) по возрастанию
  while IFS= read -r -d '' mod; do
    log_info "Загружаю модуль: $(basename "$mod")"
    # shellcheck disable=SC1090
    source "$mod"
  done < <(find "${MODULES_DIR}" -maxdepth 1 -type f -name '[0-9]*_*.sh' -print0 | sort -z -V)
}

source_module_healthcheck_only() {
  local hc="${MODULES_DIR}/99_healthcheck.sh"
  [[ -f "${hc}" ]] || die "Не найден modules/99_healthcheck.sh"
  log_info "Загружаю модуль: 99_healthcheck.sh"
  # shellcheck disable=SC1090
  source "${hc}"
}

# --- manifest builder (встроенный) --------------------------------------------
json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_manifest() {
  local ports_json le_json dns_json auth_json hc_json

  # ports (собираем PORT_*)
  ports_json="{"
  local first=true
  while IFS='=' read -r k v; do
    local port="${k#PORT_}"
    $first || ports_json+=","
    first=false
    ports_json+="\"${port}\":\"$(json_escape "${v}")\""
  done < <(env | grep -E '^PORT_[0-9]+=' || true)
  ports_json+="}"

  # le
  le_json="{\"domain\":\"$(json_escape "${HOSTNAME}")\""
  if [[ -n "${LE_VALID_UNTIL:-}" ]]; then
    le_json+=",\"valid_until\":\"$(json_escape "${LE_VALID_UNTIL}")\""
  fi
  le_json+="}"

  # dns
  local dkim_selector="${DKIM_SELECTOR:-s1}"
  local dkim_txt="${DKIM_DNS_TXT:-}"
  local dmarc_txt="${DMARC_TXT:-v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}}"

  dns_json="{"
  dns_json+="\"selector\":\"$(json_escape "${dkim_selector}")\""
  if [[ -n "${dkim_txt}" ]]; then
    dns_json+=",\"txt\":\"$(json_escape "${dkim_txt}")\""
  fi
  dns_json+=",\"DMARC\":\"$(json_escape "${dmarc_txt}")\""
  if [[ -n "${dkim_txt}" ]]; then
    dns_json+=",\"DKIM\":{\"selector\":\"$(json_escape "${dkim_selector}")\",\"txt\":\"$(json_escape "${dkim_txt}")\"}"
  fi
  dns_json+="}"

  # auth (логины из vars.yaml)
  local logins
  mapfile -t logins < <(yq -r '.users[]?.login // empty' "${VARS_FILE}")
  auth_json="["
  for i in "${!logins[@]}"; do
    [[ $i -gt 0 ]] && auth_json+=","
    # нормализуем как user@DOMAIN
    if [[ "${logins[$i]}" == *"@"* ]]; then
      auth_json+="\"$(json_escape "${logins[$i]}")\""
    else
      auth_json+="\"$(json_escape "${logins[$i]}@${DOMAIN}")\""
    fi
  done
  auth_json+="]"

  # healthcheck (HC_* из env)
  hc_json="{"
  first=true
  while IFS='=' read -r k v; do
    $first || hc_json+=","
    first=false
    hc_json+="\"$(json_escape "${k#HC_}")\":\"$(json_escape "${v}")\""
  done < <(env | grep -E '^HC_' || true)
  hc_json+="}"

  local manifest
  manifest="{"
  manifest+="\"hostname\":\"$(json_escape "${HOSTNAME}")\","
  manifest+="\"ipv4\":\"$(json_escape "${IPV4}")\","
  manifest+="\"ports\":${ports_json},"
  manifest+="\"le\":${le_json},"
  manifest+="\"dns\":${dns_json},"
  manifest+="\"auth\":{\"users_created\":${auth_json}},"
  manifest+="\"healthcheck\":${hc_json}"
  manifest+="}"

  run_cmd "install -d -m 0755 /var/local/msa"
  local tmp; tmp="$(mktemp)"
  printf '%s\n' "${manifest}" > "${tmp}"
  run_cmd "install -m 0644 '${tmp}' /var/local/msa/manifest.json"
  rm -f "${tmp}"
  log_info "manifest.json записан в /var/local/msa/manifest.json"
  printf '%s\n' "${manifest}"
}
# (блок emit_manifest основан на твоём текущем инсталлере). :contentReference[oaicite:2]{index=2}

# --- extra modes --------------------------------------------------------------
run_print_dns() {
  echo "=== DNS records to add for ${DOMAIN} / ${HOSTNAME} ==="
  echo
  echo "A     ${HOSTNAME}.      ${IPV4}"
  echo "MX    ${DOMAIN}.        10 ${HOSTNAME}."
  echo "TXT   ${DOMAIN}.        v=spf1 mx -all"
  local dkim_selector="${DKIM_SELECTOR:-s1}"
  if [[ -n "${DKIM_DNS_TXT:-}" ]]; then
    echo "TXT   ${dkim_selector}._domainkey.${DOMAIN}.  ${DKIM_DNS_TXT}"
  else
    echo "TXT   ${dkim_selector}._domainkey.${DOMAIN}.  (после генерации ключа)"
  fi
  echo "TXT   _dmarc.${DOMAIN}.  ${DMARC_TXT:-v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}}"
  echo
}

# --- modes --------------------------------------------------------------------
run_install() {
  ensure_root_if_needed
  echo "Starting installation for domain ${DOMAIN} (hostname ${HOSTNAME}, ipv4 ${IPV4})..."
  source_modules_install
  emit_manifest
}

run_healthcheck() {
  source_module_healthcheck_only
  if declare -F healthcheck::run_all >/dev/null 2>&1; then
    healthcheck::run_all || true
  else
    die "В 99_healthcheck.sh нет функции healthcheck::run_all"
  fi
}

# --- main ---------------------------------------------------------------------
main() {
  parse_args "$@"

  if [[ "${MODE}" != "healthcheck" ]]; then
    load_and_validate_vars
  else
    log_info "mode=healthcheck"
  fi

  case "${MODE}" in
    install)      run_install ;;
    healthcheck)  run_healthcheck ;;
    print-dns)    run_print_dns ;;
    *)            die "Неизвестный режим: ${MODE}" ;;
  esac
}

main "$@"
