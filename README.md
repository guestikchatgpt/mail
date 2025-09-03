# install-smtp

Автодеплой **Postfix + Dovecot + OpenDKIM + OpenDMARC + Fail2ban** на чистый VPS.
Один `vars.yaml` на входе → рабочий инстанс с TLS 1.2/1.3, DKIM/SPF/DMARC, healthcheck и отчётом.

---

## Требования

- Debian 12 / Ubuntu 24.04 (root/sudo)
- `yq` v4, `curl`, `openssl`
- Публичный **A-запись** на `hostname` (нужна для LE HTTP-challenge на :80)

## Что ставится

- **Postfix** (SMTP: 587/STARTTLS, 465/SMTPS; опционально 25/tcp для входящей)
- **Dovecot** (IMAPS 993, POP3S 995, LMTP, SASL proxy для Postfix)
- **OpenDKIM** (подпись исходящих, 2048-bit)
- **OpenDMARC** (проверка входящих)
- **Fail2ban** (jails: postfix, postfix-sasl, dovecot)
- **Certbot** c deploy-hook (reload Postfix/Dovecot на реню)
- Базовый firewall-модуль для UFW/firewalld

Пути:
- LE: `/etc/letsencrypt/live/<hostname>/{fullchain.pem,privkey.pem}`
- DKIM: `/etc/opendkim/keys/<domain>/<selector>.{private,txt}`
- Манифест: `/var/local/msa/manifest.json`
- Отчёт (Markdown): `/var/local/msa/report.md`

---

## Быстрый старт

```bash
cd install-smtp
cp vars.yaml.example vars.yaml
# отредактируй domain/hostname/ipv4, users, (необязательно) acme_email/dkim_selector

# предварительно укажи A-запись на hostname -> ipv4, чтобы LE выдал сертификат
./install.sh --vars vars.yaml
