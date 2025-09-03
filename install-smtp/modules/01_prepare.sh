# modules/01_prepare.sh — базовая подготовка системы
# Требует переменные и функции из install.sh/lib/common.sh:
#   DRY_RUN, DOMAIN/HOSTNAME/IPV4, run_cmd, log_info, require_cmd

prepare::system_packages() {
  log_info "Обновляю индекс пакетов и ставлю базовые зависимости"

  # Базовый набор для Debian/Ubuntu. Минимум для старта; остальное добавим позже модулями.
  local pkgs=(
    postfix postfix-pcre
    dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve dovecot-managesieved
    opendkim opendkim-tools
    opendmarc
    fail2ban
    certbot
    rsyslog
    ca-certificates curl gnupg
  )

  run_cmd "apt-get update"
  run_cmd "DEBIAN_FRONTEND=noninteractive apt-get -y install ${pkgs[*]}"
}

prepare::create_vmail_user() {
  log_info "Создаю системного пользователя/директорию для почтового хранилища (vmail)"

  # Группа и пользователь vmail (если отсутствуют)
  if ! getent group vmail >/dev/null 2>&1; then
    run_cmd "groupadd --system vmail"
  else
    log_info "Группа vmail уже существует"
  fi

  if ! id -u vmail >/dev/null 2>&1; then
    run_cmd "useradd --system --gid vmail --home-dir /var/vmail --create-home --shell /usr/sbin/nologin vmail"
  else
    log_info "Пользователь vmail уже существует"
  fi

  run_cmd "chmod 0750 /var/vmail"
  run_cmd "chown -R vmail:vmail /var/vmail"
}

# --- ENTRYPOINT модуля ---
prepare::system_packages
prepare::create_vmail_user
