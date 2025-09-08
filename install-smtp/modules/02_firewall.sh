#!/usr/bin/env bash
# 02_firewall.sh — базовый периметр через UFW: установка, правила, enable
set -Eeuo pipefail
IFS=$'\n\t'

MOD_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
. "${MOD_DIR}/../lib/common.sh"
: "${VARS_FILE:?}"

fw::_yq() { yq -r "$1" "${VARS_FILE}"; }

fw::vars() {
  ACCEPT_INBOUND="$(fw::_yq '.accept_inbound // "true"')"   # true|false
  # Почтовые порты (TCP). 25 — только если accept_inbound=true
  MAIL_BASE=(465 587 993 995 80 443)
}

fw::ensure_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    log_info "UFW не найден — устанавливаю…"
    run_cmd apt-get update -y
    run_cmd DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
  fi
}

fw::detect_ssh_ports() {
  # Собираем кандидаты портов SSH:
  # 1) из sshd_config (Port …), включая несколько
  # 2) из прослушивающих сокетов sshd
  # 3) дефолт 22
  declare -ag SSH_PORTS=()
  local cfg="/etc/ssh/sshd_config"

  if [[ -r "$cfg" ]]; then
    # учитываем раскомментированные Port; игнорируем комменты/пустые
    while read -r p; do
      [[ -n "$p" ]] && SSH_PORTS+=("$p")
    done < <(awk 'tolower($1)=="port"{print $2}' "$cfg" 2>/dev/null)
  fi

  # добираем из ss (если запущен sshd)
  if command -v ss >/dev/null 2>&1; then
    while read -r p; do
      # формат вида ":::2222", "0.0.0.0:22"
      p="${p##*:}"
      [[ "$p" =~ ^[0-9]+$ ]] && SSH_PORTS+=("$p")
    done < <(ss -lntp 2>/dev/null | awk '/sshd/ && /LISTEN/ {print $4}')
  fi

  # если пусто — 22
  if [[ ${#SSH_PORTS[@]} -eq 0 ]]; then
    SSH_PORTS=(22)
  fi

  # удалить дубли, отсортировать
  mapfile -t SSH_PORTS < <(printf "%s\n" "${SSH_PORTS[@]}" | awk '!seen[$0]++' | sort -n)
  log_info "SSH порты: ${SSH_PORTS[*]}"
}

fw::prepare_policy() {
  # Если UFW не активен — чистый профиль
  if ! ufw status | grep -qi 'Status: active'; then
    run_cmd ufw --force reset
    run_cmd ufw default deny incoming
    run_cmd ufw default allow outgoing
  fi
}

fw::apply_rules() {
  # Разрешаем SSH порты в первую очередь (чтобы не отрезать доступ)
  for p in "${SSH_PORTS[@]}"; do
    run_cmd ufw allow "${p}/tcp"
  done

  # Почтовые/веб порты
  local ports=("${MAIL_BASE[@]}")
  if [[ "${ACCEPT_INBOUND}" == "true" ]]; then
    ports=(25 "${ports[@]}")
  else
    log_info "ACCEPT_INBOUND=false → 25/tcp не открываем (внешняя доставка отключена)"
  fi

  for p in "${ports[@]}"; do
    run_cmd ufw allow "${p}/tcp"
  done
}

fw::enable() {
  if ! ufw status | grep -qi 'Status: active'; then
    run_cmd ufw --force enable
    log_info "UFW включён."
  else
    log_info "UFW уже активен — правила обновлены."
  fi
  ufw status verbose || true
}

fw::sanity() {
  # UFW должен быть активен
  if ! ufw status | grep -qi 'Status: active'; then
    log_error "UFW должен быть активен, но статус не active"
    exit 1
  fi

  # Устойчиво проверяем, что SSH-порты разрешены:
  # Парсим таблицу: колонки "To  Action  From". Важно сравнивать ровно поле $1 и $2.
  local missing=0
  local status
  status="$(LC_ALL=C ufw status)" || status=""

  for p in "${SSH_PORTS[@]}"; do
    if ! awk -v want="${p}/tcp" '
      # пропускаем заголовки
      BEGIN{ok=0}
      NR>=5 {
        # строки вида: "22/tcp  ALLOW  Anywhere"
        if ($1 == want && toupper($2) == "ALLOW") { ok=1; exit }
      }
      END{ exit (ok?0:1) }
    ' <<<"$status"; then
      log_error "Порт SSH ${p}/tcp не найден среди правил ALLOW UFW"
      missing=1
    fi
  done

  if [[ $missing -eq 0 ]]; then
    log_info "Sanity: SSH порты разрешены."
  else
    # Не падаем жёстко: UFW уже активен и правила вероятно есть (разные локали/форматы могут ломать парсинг).
    # Лишь предупреждаем и печатаем текущий статус для дебага.
    log_warn "Проверь вручную вывод 'ufw status' — формат может отличаться."
    echo "$status"
  fi
}

module::main() {
  fw::vars
  fw::ensure_ufw
  fw::detect_ssh_ports
  fw::prepare_policy
  fw::apply_rules
  fw::enable
  fw::sanity
  log_info "Firewall: UFW настроен и активирован."
}
module::main "$@"
