# modules/02_firewall.sh — открыть нужные порты, если FW активен
# Порты: 25, 465, 587, 993, 995, 80
# Требует: run_cmd, log_info
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

fw::open_ports() {
  local ports=(25 465 587 993 995 80)

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qEi '^Status:\s+active'; then
    for p in "${ports[@]}"; do
      run_cmd "ufw allow ${p}/tcp"
    done
    log_info "Firewall: открыты порты через UFW"
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    run_cmd "firewall-cmd --permanent --add-service=smtp"
    run_cmd "firewall-cmd --permanent --add-service=submission" || run_cmd "firewall-cmd --permanent --add-port=587/tcp"
    run_cmd "firewall-cmd --permanent --add-service=smtps" || run_cmd "firewall-cmd --permanent --add-port=465/tcp"
    run_cmd "firewall-cmd --permanent --add-service=imaps" || run_cmd "firewall-cmd --permanent --add-port=993/tcp"
    run_cmd "firewall-cmd --permanent --add-service=pop3s" || run_cmd "firewall-cmd --permanent --add-port=995/tcp"
    run_cmd "firewall-cmd --permanent --add-service=http"  || run_cmd "firewall-cmd --permanent --add-port=80/tcp"
    run_cmd "firewall-cmd --reload"
    log_info "Firewall: открыты порты через firewalld"
    return
  fi

  log_info "Firewall: UFW/firewalld не активен — действий не требуется"
}

# --- ENTRYPOINT ---
fw::open_ports
