# modules/01_prepare.sh — подготовка системы (пакеты, vmail)
# Требует: run_cmd, log_info, log_warn
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

prepare::system_packages() {
  log_info "Обновляю индекс пакетов и ставлю базовые зависимости"

  run_cmd "apt-get update"

  # Базовый набор (Ubuntu 24.04 / Debian 12)
  local pkgs=(
    postfix
    dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve dovecot-managesieved
    opendkim opendkim-tools opendmarc
    fail2ban certbot
    rsyslog ca-certificates curl gnupg
    dnsutils iproute2 lsof
  )

  # Опциональные пакеты — добавляем только если доступны в репозитории
  pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }
  if pkg_available postfix-pcre; then pkgs+=(postfix-pcre); fi

  # Собираем команду в ОДНУ строку с квотированием каждого аргумента
  local cmd="DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends"
  local p
  for p in "${pkgs[@]}"; do
    cmd+=" $(printf '%q' "$p")"
  done

  run_cmd "$cmd"
}

prepare::create_vmail_user() {
  # системная группа/пользователь для хранения почты
  if ! getent group vmail >/dev/null 2>&1; then
    run_cmd "groupadd --system vmail"
  fi
  if ! id -u vmail >/dev/null 2>&1; then
    if command -v nologin >/dev/null 2>&1; then
      run_cmd "useradd -r -g vmail -d /var/vmail -s /usr/sbin/nologin vmail"
    else
      run_cmd "useradd -r -g vmail -d /var/vmail -s /bin/false vmail"
    fi
  fi
  run_cmd "install -d -m 0750 -o vmail -g vmail /var/vmail"
}

# --- ENTRYPOINT ---
prepare::system_packages
prepare::create_vmail_user
