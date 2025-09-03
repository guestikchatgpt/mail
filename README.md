# install-smtp

## Требования
- Debian 12/Ubuntu 24.04
- root/sudo
- yq v4, curl, openssl

## Быстрый старт
1) cp vars.yaml.example vars.yaml
2) правим domain/hostname/ipv4/users
3) ./install.sh --vars vars.yaml
4) Проверяем:
   - /var/local/msa/manifest.json
   - /var/local/msa/report.md
   - ./install.sh --vars vars.yaml --print-dns
   - ./install.sh --vars vars.yaml --healthcheck

## Режимы
- --dry-run        — валидирует вход, не меняет систему
- --print-dns      — JSON с A/MX/SPF/DKIM/DMARC
- --healthcheck    — JSON со статусами TLS/DKIM/PTR
- install (по умолчанию)

## Пути
- LE: /etc/letsencrypt/live/<hostname>/{fullchain.pem,privkey.pem}
- DKIM: /etc/opendkim/keys/<domain>/<selector>.{private,txt}
- Манифест: /var/local/msa/manifest.json
- Отчёт: /var/local/msa/report.md
- Логи инсталлятора: /var/log/msa-install.log (если подключим tee)

## DNS
Пример записей (см. --print-dns):
- A: <ipv4>
- MX: mail.<domain>
- SPF: v=spf1 ip4:<ipv4> a:mail.<domain> ~all
- DKIM: s1._domainkey.<domain> TXT "v=DKIM1; k=rsa; p=..."
- DMARC: _dmarc.<domain> TXT "v=DMARC1; p=none; rua=mailto:dmarc@<domain>"
- (опц.) CAA 0 issue "letsencrypt.org"
