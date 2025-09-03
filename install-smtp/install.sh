#!/usr/bin/env bash
# install.sh — оркестратор: режимы install/print-dns/healthcheck и сборка manifest.json
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$( cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd )"
readonly MODULES_DIR="${SCRIPT_DIR}/modules"

# libs
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/json_builder.sh
source "${SCRIPT_DIR}/lib/json_builder.sh"

VARS_FILE=""
DRY_RUN="false"
MODE="install"  # install | print-dns | healthcheck

usage() {
  cat >&2 <<'USAGE'
Usage:
  ./install.sh --vars <path/to/vars.yaml> [--dry-run] [--print-dns|--healthcheck]

Options:
  --vars PATH       Путь к YAML (обязательно)
  --dry-run         Сухой прогон без изменений
  --print-dns       Вывести готовые DNS-записи (JSON) и выйти
  --healthcheck     Выполнить только проверки (JSON) и выйти
  -h, --help        Показать помощь
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vars|-v) [[ $# -ge 2 ]] || { log_error "Флаг $1 требует аргумент"; usage; exit 1; }
                 VARS_FILE="$2"; shift 2;;
      --dry-run) DRY_RUN="true"; shift;;
      --print-dns) MODE="print-dns"; shift;;
      --healthcheck) MODE="healthcheck"; shift;;
      -h|--help) usage; exit 0;;
      *) log_error "Неизвестный аргумент: $1"; usage; exit 1;;
    esac
  done
  [[ -n "${VARS_FILE}" ]] || { log_error "Не указан --vars <file>"; usage; exit 1; }
  [[ -r "${VARS_FILE}" ]] || die 1 "Файл vars.yaml не читается: ${VARS_FILE}"
}

require_yq_v4() {
  command -v yq >/dev/null 2>&1 || die 1 "Нужен yq v4: https://github.com/mikefarah/yq"
  local raw v major
  raw="$(yq --version 2>&1 || true)"
  v="$(grep -oE 'version[[:space:]]+[0-9]+\.[0-9]+' <<<"$raw" | awk '{print $2}' || true)"
  major="${v%%.*}"
  [[ -n "$major" && "$major" -ge 4 ]] || die 1 "Нужен yq v4+, найдено: ${raw}"
}

# Экспорт базовых переменных среды из vars.yaml
load_and_validate_vars() {
  DOMAIN="$(yq -r '.domain // ""' "${VARS_FILE}")"
  HOSTNAME="$(yq -r '.hostname // ""' "${VARS_FILE}")"
  IPV4="$(yq -r '.ipv4 // ""' "${VARS_FILE}")"
  ACCEPT_INBOUND="$(yq -r '.accept_inbound // true' "${VARS_FILE}")"
  BEGET_TOKEN="$(yq -r '.beget_token // ""' "${VARS_FILE}")"
  USERS_JSON="$(yq -o=json '.users // []' "${VARS_FILE}")"
  USERS_COUNT="$(yq -r '(.users // []) | length' "${VARS_FILE}")"

  if [[ -z "$HOSTNAME" && -n "$DOMAIN" ]]; then HOSTNAME="mail.${DOMAIN}"; fi
  [[ -n "$DOMAIN"   ]] || die 1 "Отсутствует 'domain' в ${VARS_FILE}"
  [[ -n "$HOSTNAME" ]] || die 1 "Отсутствует 'hostname' и не удалось вывести из domain"
  [[ -n "$IPV4"     ]] || die 1 "Отсутствует 'ipv4' в ${VARS_FILE}"
  if ! [[ "$IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then die 1 "Некорректный ipv4: ${IPV4}"; fi
  IFS='.' read -r o1 o2 o3 o4 <<<"$IPV4"; for o in "$o1" "$o2" "$o3" "$o4"; do (( o>=0 && o<=255 )) || die 1 "Некорректный ipv4: ${IPV4}"; done
  if [[ "$USERS_COUNT" -lt 1 ]]; then die 1 "Секция 'users' пуста — нужен хотя бы один ящик"; fi
  local bad_cnt; bad_cnt="$(yq -r '((.users // []) | map(select((.login // "") == "" or (.password // "") == "")) | length)' "${VARS_FILE}")"
  [[ "$bad_cnt" == "0" ]] || die 1 "Некорректные пользователи в 'users' — пустой login/password"
}

source_modules_in_order() {
  shopt -s nullglob
  local mods=("${MODULES_DIR}"/[0-9][0-9]_*.sh)
  (( ${#mods[@]} > 0 )) || die 4 "Не найдено модулей в ${MODULES_DIR}"
  for m in "${mods[@]}"; do
    log_info "Загружаю модуль: $(basename "$m")"
    # shellcheck source=/dev/null
    source "$m"
  done
}

source_single_module() {
  local name="$1"
  local f="${MODULES_DIR}/${name}"
  [[ -r "$f" ]] || die 4 "Модуль не найден: ${f}"
  log_info "Загружаю модуль: $(basename "$f")"
  # shellcheck source=/dev/null
  source "$f"
}

# ---------- JSON helpers for manifest pieces ----------

build_ports_json() {
  json_begin
  json_add_string "25"  "${PORT_25:-$(health_default_port 25)}"
  json_add_string "465" "${PORT_465:-$(health_default_port 465)}"
  json_add_string "587" "${PORT_587:-$(health_default_port 587)}"
  json_add_string "993" "${PORT_993:-$(health_default_port 993)}"
  json_add_string "995" "${PORT_995:-$(health_default_port 995)}"
  json_end
}

health_default_port() { # fallback если 99_healthcheck не запускался
  case "$1" in
    25|465|587|993|995) echo "open";;
    *) echo "closed";;
  esac
}

build_le_json() {
  local le_domain="${LE_DOMAIN:-$HOSTNAME}"
  local le_until="${LE_VALID_UNTIL:-}"
  json_begin
  json_add_string "domain" "${le_domain}"
  json_add_string "valid_until" "${le_until}"
  json_end
}

build_dns_json() {
  local dkim_selector="${DKIM_SELECTOR:-$(yq -r '.dkim_selector // "s1"' "${VARS_FILE}")}"
  local dkim_txt="${DKIM_TXT:-}"
  json_begin
  json_add_string "A"  "${IPV4}"
  json_add_string "MX" "${HOSTNAME}"
  json_add_string "SPF" "v=spf1 ip4:${IPV4} a:${HOSTNAME} ~all"

  # DKIM object
  json_begin
  json_add_string "selector" "${dkim_selector}"
  json_add_string "txt" "${dkim_txt}"
  local dkim_obj; dkim_obj="$(json_end)"
  json_add_object "DKIM" "${dkim_obj}"

  # DMARC
  json_add_string "DMARC" "v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}"
  json_end
}

build_auth_json() {
  # users_created: массив логинов из vars.yaml
  mapfile -t __USERS < <(yq -r '(.users // [])[].login' "${VARS_FILE}")
  json_begin
  json_add_array_strings "users_created" "${__USERS[@]}"
  json_end
}

build_health_json() {
  json_begin
  json_add_string "smtps_465"          "${HC_SMTPS_465:-error}"
  json_add_string "smtp_587_starttls"  "${HC_SMTP_587_STARTTLS:-error}"
  json_add_string "imaps_993"          "${HC_IMAPS_993:-error}"
  json_add_string "dkim_sign"          "${HC_DKIM_SIGN:-error}"
  json_add_string "helo_matches_ptr"   "${HC_HELO_MATCHES_PTR:-error}"
  json_end
}

assemble_manifest() {
  local ports_json le_json dns_json auth_json health_json
  ports_json="$(build_ports_json)"
  le_json="$(build_le_json)"
  dns_json="$(build_dns_json)"
  auth_json="$(build_auth_json)"
  health_json="$(build_health_json)"

  json_begin
  json_add_string "hostname" "${HOSTNAME}"
  json_add_string "ipv4"     "${IPV4}"
  json_add_object "ports"    "${ports_json}"
  json_add_object "le"       "${le_json}"
  json_add_object "dns"      "${dns_json}"
  json_add_object "auth"     "${auth_json}"
  json_add_object "healthcheck" "${health_json}"
  json_end
}

# ---------- modes ----------

mode_print_dns() {
  # только DNS-блок — пригодно для --print-dns
  local dns_json; dns_json="$(build_dns_json)"
  printf '%s\n' "${dns_json}"
}

mode_healthcheck() {
  # Только модуль 99; печатаем {"healthcheck":{...}}
  source_single_module "99_healthcheck.sh"
  local health_json; health_json="$(build_health_json)"
  json_begin
  json_add_object "healthcheck" "${health_json}"
  json_end
  printf '\n'
}

mode_install() {
  if [[ "${DRY_RUN}" != "true" ]]; then ensure_root_or_die; fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "Dry run mode enabled for domain ${DOMAIN} (hostname ${HOSTNAME}, ipv4 ${IPV4})."
    # в dry-run загружаем модули, но они ничего не меняют; manifest не пишем на диск
  else
    echo "Starting installation for domain ${DOMAIN} (hostname ${HOSTNAME}, ipv4 ${IPV4})..."
  fi

  source_modules_in_order  # включает 99_healthcheck в конце

  # Сборка manifest
  local manifest; manifest="$(assemble_manifest)"

  # Вывод в stdout
  printf '%s\n' "${manifest}"

  # Запись на диск (кроме dry-run)
  if [[ "${DRY_RUN}" != "true" ]]; then
    run_cmd "install -d -m 0755 /var/local/msa"
    # запись файла не должна идти через run_cmd (безопаснее прямой вывод)
    tmp="$(mktemp)"; printf '%s\n' "${manifest}" > "${tmp}"
    run_cmd "install -m 0644 '${tmp}' /var/local/msa/manifest.json"
    rm -f "${tmp}"
    log_info "manifest.json записан в /var/local/msa/manifest.json"
  else
    log_info "DRY-RUN: manifest.json не записываю на диск"
  fi
}

main() {
  parse_args "$@"
  require_yq_v4
  load_and_validate_vars
  log_info "vars.yaml ок: domain=${DOMAIN}, hostname=${HOSTNAME}, ipv4=${IPV4}, users=${USERS_COUNT}, mode=${MODE}, dry_run=${DRY_RUN}"

  case "${MODE}" in
    print-dns) mode_print_dns ;;
    healthcheck) mode_healthcheck ;;
    install) mode_install ;;
    *) die 1 "Неизвестный режим: ${MODE}" ;;
  esac
}

main "$@"
