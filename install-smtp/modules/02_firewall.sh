# modules/02_firewall.sh — открыть нужные порты, если FW активен
# Порты: 465, 587, 993, 995, 80, и УСЛОВНО 25 (accept_inbound)
# Требует: run_cmd, log_info; переменная: ACCEPT_INBOUND
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

fw::open_ports() {
  local ports=(465 587 993 995 80)
  if [[ "${ACCEPT_INBOUND:-true}" == "true" ]]; then
    ports=(25 "${ports[@]}")
  else
    log_info "Firewall: accept_inbound=false — 25/tcp не открываю"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qEi '^Status:\s+active'; then
    for p in "${ports[@]}"; do
      run_cmd "ufw allow ${p}/tcp"
    done
    log_info "Firewall: порты открыты через UFW: ${ports[*]}"
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    # Используем сервисы, где есть
    [[ " ${ports[*]} " == *" 25 "* ]] && run_cmd "firewall-cmd --permanent --add-service=smtp"
    [[ " ${ports[*]} " == *" 587 "* ]] && run_cmd "firewall-cmd --permanent --add-service=submission" || true
    [[ " ${ports[*]} " == *" 587 "* ]] || run_cmd "firewall-cmd --permanent --add-port=587/tcp"
    [[ " ${ports[*]} " == *" 465 "* ]] && run_cmd "firewall-cmd --permanent --add-service=smtps" || run_cmd "firewall-cmd --permanent --add-port=465/tcp"
    [[ " ${ports[*]} " == *" 993 "* ]] && run_cmd "firewall-cmd --permanent --add-service=imaps" || run_cmd "firewall-cmd --permanent --add-port=993/tcp"
    [[ " ${ports[*]} " == *" 995 "* ]] && run_cmd "firewall-cmd --permanent --add-service=pop3s" || run_cmd "firewall-cmd --permanent --add-port=995/tcp"
    [[ " ${ports[*]} " == *" 80 "*  ]] && run_cmd "firewall-cmd --permanent --add-service=http"  || run_cmd "firewall-cmd --permanent --add-port=80/tcp"
    run_cmd "firewall-cmd --reload"
    log_info "Firewall: порты открыты через firewalld: ${ports[*]}"
    return
  fi

  log_info "Firewall: UFW/firewalld не активен — действий не требуется"
}

# --- ENTRYPOINT ---
fw::open_ports
