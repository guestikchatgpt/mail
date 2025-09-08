# modules/01_prepare.sh — подготовка системы (пакеты, vmail, IPv6-off)
# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

prepare::system_packages() {
  log_info "Обновляю индекс пакетов и ставлю базовые зависимости"
  run_cmd apt-get update

  # Базовый набор пакетов
  local -a pkgs=(
    postfix
    dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd dovecot-sieve dovecot-managesieved
    opendkim opendkim-tools opendmarc
    fail2ban certbot
    rsyslog ca-certificates curl gnupg
    dnsutils iproute2 lsof
  )

  # Добросим postfix-pcre при наличии в репах
  pkg_available() { apt-cache show "$1" >/dev/null 2>&1; }
  if pkg_available postfix-pcre; then
    pkgs+=(postfix-pcre)
  fi

  log_info "Устанавливаю пакеты (${#pkgs[@]}): ${pkgs[*]}"

  # Жёстко через env → исключаем нюансы run_cmd/IFS
  if ! /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        APT_LISTCHANGES_FRONTEND=none \
        UCF_FORCE_CONFOLD=1 \
        apt-get -y install --no-install-recommends "${pkgs[@]}"; then
    log_warn "Первый apt-get install завершился ошибкой — пробую apt-get -f install и повтор"
    /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get -f -y install
    /usr/bin/env DEBIAN_FRONTEND=noninteractive \
      APT_LISTCHANGES_FRONTEND=none \
      UCF_FORCE_CONFOLD=1 \
      apt-get -y install --no-install-recommends "${pkgs[@]}"
  fi
}

prepare::create_vmail_user() {
  if ! getent group vmail >/dev/null 2>&1; then
    run_cmd groupadd --system vmail
  fi
  if ! id -u vmail >/dev/null 2>&1; then
    if command -v nologin >/dev/null 2>&1; then
      run_cmd useradd -r -g vmail -d /var/vmail -s /usr/sbin/nologin vmail
    else
      run_cmd useradd -r -g vmail -d /var/vmail -s /bin/false vmail
    fi
  fi
  run_cmd install -d -m 0750 -o vmail -g vmail /var/vmail
}

# Жёстко отключаем IPv6 на уровне ядра — для предсказуемости исходящих
prepare::disable_ipv6() {
  log_info "Отключаю IPv6 на уровне ядра (sysctl)"
  local conf="/etc/sysctl.d/98-msa-disable-ipv6.conf"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# Disabled by msa-installer to ensure IPv4-only routing
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  run_cmd install -m 0644 "$tmp" "$conf"
  rm -f "$tmp"
  run_cmd sysctl -p "$conf"
}

prepare::add_postfix_to_milter_groups() {
  log_info "Добавляю пользователя postfix в группы opendkim и opendmarc для доступа к сокетам"
  run_cmd usermod -a -G opendkim postfix
  run_cmd usermod -a -G opendmarc postfix
}


# --- ENTRYPOINT ---
prepare::system_packages
prepare::create_vmail_user
prepare::disable_ipv6
prepare::add_postfix_to_milter_groups
