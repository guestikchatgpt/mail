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
# Поведение:
# - Если передана одна строка — исполняем через bash -c (для пайпов и т.п.).
# - Если передано несколько аргументов:
#     * Если в начале идут присваивания вида KEY=VALUE — исполняем через /usr/bin/env KEY=VALUE cmd args...
#     * Иначе — исполняем напрямую без шелла.
run_cmd() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "DRY-RUN: $*"
    return 0
  fi

  # Несколько аргументов → прямая exec с поддержкой префиксных VAR=VAL
  if [[ $# -gt 1 ]]; then
    local -a argv=( "$@" )
    local i=0
    # Ищем ведущие присваивания окружения KEY=VALUE
    while (( i < ${#argv[@]} )); do
      # Разрешаем только корректные имена переменных окружения
      if [[ "${argv[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        ((i++))
        continue
      fi
      break
    done

    if (( i > 0 )); then
      # Есть хотя бы одно присваивание окружения → запускаем через env
      log_info "RUN: env ${argv[*]}"
      /usr/bin/env "${argv[@]}"
    else
      log_info "RUN: ${argv[*]}"
      "${argv[@]}"
    fi
    return
  fi

  # Один аргумент — строка (нужен шелл для пайпов/редиректов)
  local cmd="$*"
  log_info "RUN: $cmd"
  /bin/bash -o pipefail -c "$cmd"
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
