#!/usr/bin/env bash
# «Панорама Мастер» — подключение боевого домена и HTTPS.
# Перед запуском: A-записи домена и www должны указывать на 201.51.1.60.
# Запуск: bash /var/www/pmaster/deploy/enable-domain.sh ДОМЕН        (например panorama-master.ru)
# Меняет только свой конфиг /etc/nginx/sites-available/panorama-master.
set -euo pipefail
D="${1:?Укажите домен, например: bash enable-domain.sh panorama-master.ru}"
D="$(python3 -c 'import sys;print(sys.argv[1].strip().lower().encode("idna").decode())' "$D")"   # кириллица → punycode
IP=201.51.1.60
for h in "$D" "www.$D"; do
  got="$(dig +short "$h" @1.1.1.1 | tail -1)"
  [ "$got" = "$IP" ] || { echo "СТОП: $h указывает на «${got:-ничего}», а нужно $IP. Поменяйте A-запись и подождите 15–30 минут."; exit 1; }
done
CONF=/etc/nginx/sites-available/panorama-master
cp "$CONF" "$CONF.bak"
cat > "$CONF" <<NGX
# «Панорама Мастер» — боевой домен $D
server {
    listen 80;
    listen [::]:80;
    server_name $D www.$D;
    include /etc/nginx/snippets/pmaster-common.conf;
}
# предпросмотр по IP
server {
    listen 8084 default_server;
    listen [::]:8084 default_server;
    server_name _;
    include /etc/nginx/snippets/pmaster-common.conf;
}
NGX
nginx -t && systemctl reload nginx || { cp "$CONF.bak" "$CONF"; nginx -t && systemctl reload nginx; exit 1; }
command -v certbot >/dev/null || { apt-get update -qq && apt-get install -y -qq certbot python3-certbot-nginx; }
certbot --nginx -n --agree-tos --register-unsafely-without-email --redirect -d "$D" -d "www.$D" --cert-name "$D"
# www → без www (одна главная версия сайта для поиска)
python3 - "$CONF" "$D" <<'PY'
import sys,re
p,d=sys.argv[1],sys.argv[2]; t=open(p).read()
if "return 301 https://"+d not in t:
    t=t.replace("server_name "+d+" www."+d+";","server_name "+d+" www."+d+";\n    if ($host = www."+d+") { return 301 https://"+d+"$request_uri; }",1)
    open(p,"w").write(t)
PY
nginx -t && systemctl reload nginx
echo "$D" > /etc/pmaster/domain
echo "ГОТОВО: https://$D/"
