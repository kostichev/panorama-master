#!/usr/bin/env bash
# «Панорама Мастер» — установка и обновление на общем сервере sites-1.
# Запуск (и для первой установки, и для обновления):
#   curl -fsSL https://raw.githubusercontent.com/kostichev/panorama-master/main/deploy/install.sh | bash
# Скрипт трогает ТОЛЬКО свои файлы: /var/www/pmaster, /etc/pmaster, /var/lib/pmaster,
# службу pmaster-lead (порт 127.0.0.1:8098), конфиг nginx «panorama-master» (порт 8084) и правило ufw 8084.
# Чужие сайты, их конфиги и правила файрвола не меняются.
set -euo pipefail
REPO="https://github.com/kostichev/panorama-master.git"
WWW="/var/www/pmaster"
PORT=8084
[ "$(id -u)" = 0 ] || { echo "Запустите от root"; exit 1; }
say(){ echo -e "\n== $*"; }

say "1/5 Проверяю, что порты $PORT и 8098 свободны для «Панорамы Мастер»"
for f in /etc/nginx/sites-enabled/*; do
  [ -e "$f" ] || continue
  case "$(basename "$(readlink -f "$f")")" in panorama-master) continue;; esac
  if grep -Eq "^[[:space:]]*listen[[:space:]]+([^;]*:)?$PORT([[:space:]]|;)" "$(readlink -f "$f")"; then
    echo "СТОП: порт $PORT занят другим сайтом ($f). Ничего не меняю."; exit 1
  fi
done
if ss -tlnH "sport = :8098" | grep -q . && ! systemctl is-active -q pmaster-lead; then
  echo "СТОП: порт 8098 занят другой программой. Ничего не меняю."; exit 1
fi

say "2/5 Скачиваю свежую версию сайта"
if [ -d "$WWW/.git" ]; then
  git -C "$WWW" fetch -q --depth 1 origin main && git -C "$WWW" reset -q --hard origin/main
else
  rm -rf "$WWW.new"; git clone -q --depth 1 "$REPO" "$WWW.new"
  [ -d "$WWW" ] && mv "$WWW" "$WWW.old.$(date +%s)"
  mv "$WWW.new" "$WWW"
fi
chmod -R a+rX "$WWW"
echo "версия: $(git -C "$WWW" log -1 --format='%h %ad %s' --date=short)"

say "3/5 Сервис приёма заявок (MAX)"
mkdir -p /etc/pmaster /var/lib/pmaster; chmod 700 /etc/pmaster /var/lib/pmaster
install -m 755 "$WWW/deploy/lead.py" /usr/local/bin/pmaster-lead
install -m 644 "$WWW/deploy/pmaster-lead.service" /etc/systemd/system/pmaster-lead.service
systemctl daemon-reload; systemctl enable -q pmaster-lead; systemctl restart pmaster-lead
sleep 1; systemctl is-active -q pmaster-lead && echo "сервис заявок работает" || { journalctl -u pmaster-lead -n 20 --no-pager; exit 1; }

say "4/5 Настройка nginx (только свой конфиг)"
install -m 644 "$WWW/deploy/nginx-common.conf" /etc/nginx/snippets/pmaster-common.conf
CONF=/etc/nginx/sites-available/panorama-master
[ -f "$CONF" ] && cp "$CONF" "$CONF.bak"
if [ -f /etc/pmaster/domain ]; then   # домен уже подключён — конфиг с доменом не перезаписываем
  echo "домен $(cat /etc/pmaster/domain) подключён — конфиг nginx оставлен как есть"
else
  install -m 644 "$WWW/deploy/nginx.conf" "$CONF"
fi
ln -sf "$CONF" /etc/nginx/sites-enabled/panorama-master
if nginx -t 2>/dev/null; then
  systemctl reload nginx; echo "nginx: ок"
else
  echo "Ошибка в настройках — откатываю только свой конфиг"; nginx -t || true
  if [ -f "$CONF.bak" ]; then cp "$CONF.bak" "$CONF"; else rm -f /etc/nginx/sites-enabled/panorama-master; fi
  nginx -t && systemctl reload nginx; exit 1
fi

say "5/5 Файрвол: открываю порт предпросмотра $PORT"
ufw allow "$PORT/tcp" >/dev/null && echo "ufw: $PORT открыт"

echo
echo "Проверка:"
curl -s -o /dev/null -w "  сайт:   http://127.0.0.1:$PORT/  → %{http_code}\n" "http://127.0.0.1:$PORT/"
curl -s -w "  заявки: %{http_code}\n" -o /dev/null "http://127.0.0.1:8098/api/lead/ping"
echo
echo "ГОТОВО. Сайт: http://201.51.1.60:$PORT/"
echo "Следующий шаг — подключить MAX:  pmaster-lead setup   затем   pmaster-lead test"
