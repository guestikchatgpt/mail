# modules/100_report.sh — финальный человекочитаемый отчёт (Markdown)
# Источник данных: ТОЛЬКО переменные окружения, выставленные предыдущими модулями.
# Никаких чтений vars.yaml/manifest.json и никаких внешних команд.
# Пишет /var/local/msa/report.md (кроме --dry-run). stdout не трогаем.
# Требует: log_info, log_warn, run_cmd, переменные: DOMAIN, HOSTNAME, IPV4, LE_DOMAIN, LE_VALID_FROM, LE_VALID_UNTIL,
#          DKIM_SELECTOR, DKIM_TXT, PORT_25, PORT_465, PORT_587, PORT_993, PORT_995,
#          HC_SMTPS_465, HC_SMTP_587_STARTTLS, HC_IMAPS_993, HC_DKIM_SIGN, HC_HELO_MATCHES_PTR

# shellcheck shell=bash

report::_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Безопасные геттеры (без внешних вызовов)
report::_val() { local v="$1" d="$2"; [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "$d"; }

# Разбить длинный DKIM TXT на куски по 255 символов
report::_chunk_255() {
  local s="$1" len=${#1} i=0 out=""
  while (( i < len )); do
    out+="\"${s:i:255}\" "
    (( i += 255 ))
  done
  printf '%s' "${out% }"
}

report::render() {
  local now hostname domain ipv4
  now="$(report::_now_iso)"
  hostname="$(report::_val "${HOSTNAME:-}" "n/a")"
  domain="$(report::_val "${DOMAIN:-}" "n/a")"
  ipv4="$(report::_val "${IPV4:-}" "n/a")"

  local le_dom le_from le_until
  le_dom="$(report::_val "${LE_DOMAIN:-}" "${hostname}")"
  le_from="$(report::_val "${LE_VALID_FROM:-}" "n/a")"
  le_until="$(report::_val "${LE_VALID_UNTIL:-}" "n/a")"

  local dkim_sel dkim_txt dkim_chunks
  dkim_sel="$(report::_val "${DKIM_SELECTOR:-}" "s1")"
  dkim_txt="$(report::_val "${DKIM_TXT:-}" "")"
  if [[ -n "$dkim_txt" ]]; then
    dkim_chunks="$(report::_chunk_255 "$dkim_txt")"
  else
    dkim_chunks=""
  fi

  local p25 p465 p587 p993 p995
  p25="$(report::_val "${PORT_25:-}"  "open")"
  p465="$(report::_val "${PORT_465:-}" "open")"
  p587="$(report::_val "${PORT_587:-}" "open")"
  p993="$(report::_val "${PORT_993:-}" "open")"
  p995="$(report::_val "${PORT_995:-}" "open")"

  local hc465 hc587 hc993 hcdkim hchelo
  hc465="$(report::_val "${HC_SMTPS_465:-}" "unknown")"
  hc587="$(report::_val "${HC_SMTP_587_STARTTLS:-}" "unknown")"
  hc993="$(report::_val "${HC_IMAPS_993:-}" "unknown")"
  hcdkim="$(report::_val "${HC_DKIM_SIGN:-}" "unknown")"
  hchelo="$(report::_val "${HC_HELO_MATCHES_PTR:-}" "unknown")"

  # Производные DNS-значения из известных переменных (без сторонних вызовов)
  local dns_a dns_mx dns_spf dns_dmarc
  dns_a="${ipv4}"
  dns_mx="${hostname}"
  dns_spf="v=spf1 ip4:${ipv4} a:${hostname} ~all"
  dns_dmarc="v=DMARC1; p=none; rua=mailto:dmarc@${domain}"

  local tmp; tmp="$(mktemp)"

  {
    printf "# Mail instance report\n\n"
    printf "- Generated at: \`%s\` (UTC)\n" "$now"
    printf "- Hostname: \`%s\`\n" "$hostname"
    printf "- Domain: \`%s\`\n" "$domain"
    printf "- IPv4: \`%s\`\n\n" "$ipv4"

    printf "## TLS certificate\n\n"
    printf "- Certificate for (LE): \`%s\`\n" "$le_dom"
    printf "- Valid from: \`%s\`\n" "$le_from"
    printf "- Valid until: \`%s\`\n\n" "$le_until"

    printf "## Ports (listen) & Health\n\n"
    printf "| Port | Listen | Health |\n"
    printf "|------|--------|--------|\n"
    printf "| 25   | %s | (HELO/PTR: %s) |\n" "$p25" "$hchelo"
    printf "| 465  | %s | SMTPS: %s |\n" "$p465" "$hc465"
    printf "| 587  | %s | STARTTLS: %s |\n" "$p587" "$hc587"
    printf "| 993  | %s | IMAPS: %s |\n" "$p993" "$hc993"
    printf "| 995  | %s | — |\n\n" "$p995"

    printf "## DNS records (to set/verify)\n\n"
    printf "- **A**: \`%s\`\n" "$dns_a"
    printf "- **MX**: \`%s\`\n" "$dns_mx"
    printf "- **SPF**: \`%s\`\n" "$dns_spf"
    printf "- **DKIM selector**: \`%s\`\n" "$dkim_sel"
    if [[ -n "$dkim_txt" ]]; then
      printf "- **DKIM TXT (single line)**:\n"
      printf "  \`\`\`\n  %s\n  \`\`\`\n" "$dkim_txt"
      printf "- **DKIM TXT (chunked ≤255 chars for DNS)**:\n"
      printf "  \`\`\`\n  %s\n  \`\`\`\n" "$dkim_chunks"
    else
      printf "- **DKIM TXT**: _not available yet_\n"
    fi
    printf "- **DMARC**: \`%s\`\n\n" "$dns_dmarc"

    printf "## Summary\n"
    printf "- HELO matches PTR: **%s**\n" "$hchelo"
    printf "- DKIM test: **%s**\n" "$hcdkim"
    printf "- TLS: 465=%s, 587/STARTTLS=%s, 993=%s\n" "$hc465" "$hc587" "$hc993"
  } > "$tmp"

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "DRY-RUN: отчёт не записываю. Путь был бы: /var/local/msa/report.md"
    rm -f "$tmp"
    return 0
  fi

  run_cmd "install -d -m 0755 /var/local/msa"
  run_cmd "install -m 0644 '${tmp}' /var/local/msa/report.md"
  rm -f "$tmp"
  log_info "Отчёт сохранён: /var/local/msa/report.md"
}

# --- ENTRYPOINT ---
report::render
