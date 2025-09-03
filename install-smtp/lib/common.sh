# lib/common.sh — общие хелперы
# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_info()  { printf '[%s] [INFO]  %s\n'  "$(_ts)" "$*" >&2; }
log_warn()  { printf '[%s] [WARN]  %s\n'  "$(_ts)" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n'  "$(_ts)" "$*" >&2; }

die() {
  local code=1
  if [[ $# -ge 1 && "$1" =~ ^[0-9]+$ ]]; then code="$1"; shift; fi
  log_error "$*"
  exit "${code}"
}

# Безопасное выполнение команд с уважением к DRY_RUN.
# - Если вызвано с несколькими аргументами: исполняем напрямую (без bash -c).
# - Если передана одна строка: совместимость со старым кодом через bash -c.
run_cmd() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "DRY-RUN: $*"
    return 0
  fi

  if [[ $# -gt 1 ]]; then
    log_info "RUN: $*"
    "$@"
  else
    local cmd="$*"
    log_info "RUN: $cmd"
    /bin/bash -o pipefail -c "$cmd"
  fi
}

ensure_root_or_die() {
  if [[ "${EUID}" -ne 0 ]]; then
    die 1 "Нужны root-привилегии (sudo) для режима установки"
  fi
}

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || die 1 "Не найден бинарь: $c"
}
