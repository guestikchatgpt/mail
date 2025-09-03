#!/usr/bin/env bash
# modules/05_dkim.sh — OpenDKIM (ключи, конфиг, milter с идемпотентной встройкой)
set -Eeuo pipefail
IFS=$'\n\t'

# --- мини-логгер при автономном запуске ---
if [[ "$(type -t log 2>/dev/null)" != "function" ]]; then
  log(){ printf '[%(%FT%TZ)T] [%s] %s\n' -1 "${1:-INFO}" "${*:2}"; }
fi
if [[ "$(type -t run 2>/dev/null)" != "function" ]]; then
  run(){ log INFO "RUN: $*"; "$@"; }
fi

VARS_FILE="${VARS_FILE:-${1:-vars.yaml}}"

DOMAIN="$(yq -r '.domain' "$VARS_FILE")"
HOSTNAME="$(yq -r '.hostname // ("mail." + .domain)' "$VARS_FILE")"
SELECTOR="$(yq -r '.dkim_selector // "s1"' "$VARS_FILE")"

KEYDIR="/etc/opendkim/keys/${DOMAIN}"
PRIV="${KEYDIR}/${SELECTOR}.private"
PUB="${KEYDIR}/${SELECTOR}.txt"

log INFO "OpenDKIM: подготовка ключей (selector=${SELECTOR}, domain=${DOMAIN})"
run install -d -m 0750 -o opendkim -g opendkim "$KEYDIR"
run install -d -m 0750 -o opendkim -g postfix  "/var/spool/postfix/opendkim"

if [[ ! -s "$PRIV" ]]; then
  log INFO "OpenDKIM: генерирую 2048-бит ключ (впервые)"
  run opendkim-genkey -b 2048 -s "$SELECTOR" -d "$DOMAIN" -D "$KEYDIR"
  run chown opendkim:opendkim "$PRIV" "$PUB"
  run chmod 0600 "$PRIV"
else
  log INFO "OpenDKIM: ключ уже существует (${SELECTOR} @ ${DOMAIN}) — пропускаю генерацию"
  run chown opendkim:opendkim "$PRIV" "$PUB" || true
  run chmod 0600 "$PRIV" || true
fi

# Чистое значение для TXT (v=DKIM1; k=rsa; p=...)
_p_value="$(
  tr -d '\n"' < "$PUB" \
  | sed -E 's/^[^p]*p=([^; )]+).*/\1/' \
  | tr -d '[:space:]'
)"
DKIM_UI_VALUE="v=DKIM1; h=sha256; k=rsa; p=${_p_value}"

# Для BIND: режем p= по 240 символов
_bind_chunks=""
_tmp="$_p_value"
while [[ -n "$_tmp" ]]; do
  _bind_chunks+=$'\n'"\"${_tmp:0:240}\""
  _tmp="${_tmp:240}"
done

# KeyTable/SigningTable/TrustedHosts
log INFO "OpenDKIM: пишу KeyTable/SigningTable/TrustedHosts"
install -m 0640 -o root -g opendkim <(cat <<EOF
${SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${SELECTOR}:${PRIV}
EOF
) /etc/opendkim/key.table

install -m 0640 -o root -g opendkim <(cat <<EOF
*@${DOMAIN} ${SELECTOR}._domainkey.${DOMAIN}
EOF
) /etc/opendkim/signing.table

install -m 0640 -o root -g opendkim <(cat <<'EOF'
127.0.0.1
::1
localhost
EOF
) /etc/opendkim/trusted.hosts
echo "$HOSTNAME" | install -m 0640 -o root -g opendkim /dev/stdin -T /etc/opendkim/trusted.hosts.tmp && \
  cat /etc/opendkim/trusted.hosts >>/etc/opendkim/trusted.hosts.tmp && \
  mv /etc/opendkim/trusted.hosts.tmp /etc/opendkim/trusted.hosts

# Конфиг и defaults
log INFO "OpenDKIM: пишу конфигурацию и defaults (socket=local:/var/spool/postfix/opendkim/opendkim.sock)"
install -m 0644 -o root -g root <(cat <<'EOF'
Syslog                  yes
UMask                   007
UserID                  opendkim
Mode                    sv
AutoRestart             yes
AutoRestartRate         10/1h
Canonicalization        relaxed/simple
OversignHeaders         From
KeyTable                /etc/opendkim/key.table
SigningTable            refile:/etc/opendkim/signing.table
ExternalIgnoreList      /etc/opendkim/trusted.hosts
InternalHosts           /etc/opendkim/trusted.hosts
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
EOF
) /etc/opendkim/opendkim.conf

install -m 0644 -o root -g root <(cat <<'EOF'
SOCKET="local:/var/spool/postfix/opendkim/opendkim.sock"
RUNDIR="/run/opendkim"
EOF
) /etc/default/opendkim

# Удобный файл для UI/DNS
install -d -m 0755 /var/local/msa
cat > /var/local/msa/dkim.txt <<EOF
# DKIM для ${DOMAIN} (selector: ${SELECTOR})

Имя: ${SELECTOR}._domainkey.${DOMAIN}.
Тип: TXT
Значение:
${DKIM_UI_VALUE}

# BIND:
${SELECTOR}._domainkey.${DOMAIN}.  IN TXT (
"v=DKIM1; h=sha256; k=rsa; p="
${_bind_chunks}
)
EOF
chmod 0644 /var/local/msa/dkim.txt

# Идемпотентная встройка milter в Postfix
add_milter_if_missing() {
  local param="$1" want="$2"
  local cur; cur="$(postconf -h "$param" || true)"
  if [[ "$cur" == *"$want"* ]]; then
    log INFO "OpenDKIM: $param уже содержит $want"
  else
    if [[ -n "$cur" ]]; then
      run postconf -e "$param=${cur},${want}"
    else
      run postconf -e "$param=${want}"
    fi
  fi
}

add_milter_if_missing "smtpd_milters" "unix:/var/spool/postfix/opendkim/opendkim.sock"
add_milter_if_missing "non_smtpd_milters" "unix:/var/spool/postfix/opendkim/opendkim.sock"
run postconf -e "milter_default_action=accept"
run postconf -e "milter_protocol=6"

run systemctl enable --now opendkim
run systemctl restart opendkim
run systemctl reload postfix || run systemctl restart postfix

log INFO "OpenDKIM: готово. Чистое значение для DNS записано в /var/local/msa/dkim.txt"
