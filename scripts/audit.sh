#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  [OK]   $desc"; ((PASS++))
  else
    echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
  fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
SSHD=$(sudo sshd -T)
check "Вход от имени root запрещён" "no" "$(awk '/^permitrootlogin/{print $2}' <<<"$SSHD")"
check "Парольная аутентификация отключена" "no" "$(awk '/^passwordauthentication/{print $2}' <<<"$SSHD")"
# TODO 1: порт отличен от 22
port=$(awk '/^port /{print $2}' <<<"$SSHD")
check "Порт SSH отличен от 22" "yes" "$([[ -n "$port" && "$port" != "22" ]] && echo yes || echo "no ($port)")"
# TODO 2: maxauthtries равно 3
check "MaxAuthTries равно 3" "3" "$(awk '/^maxauthtries/{print $2}' <<<"$SSHD")"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo LC_ALL=C ufw status | awk '/^Status:/{print $2}')"
# TODO 3: политика по умолчанию для входящего трафика — deny
check "Политика входящего трафика deny" "deny" \
  "$(sudo LC_ALL=C ufw status verbose | grep '^Default:' | sed -E 's/^Default: ([a-z]+) \(incoming\).*/\1/')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "  %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
CERT=/etc/ssl/certs/devops.crt
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx корректна" "0" "$(sudo nginx -t >/dev/null 2>&1; echo $?)"
check "Сертификат действует ещё ${CERT_MIN_DAYS} дн." "0"   "$(openssl x509 -in "$CERT" -noout -checkend $((CERT_MIN_DAYS*86400)) >/dev/null; echo $?)"
check "Нет файлов ресурса, доступных для записи всем" "" "$(find /var/www/devops-site -perm -o+w)"
check "Права закрытого ключа 600" "600" "$(sudo stat -c '%a' /etc/ssl/private/devops.key)"

echo "[5] Контейнеризация"
check "Служба docker активна" "active" "$(systemctl is-active docker)"
check "Контейнер СУБД healthy" "healthy" "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
check "Порты 5000/5432 только на 127.0.0.1" ""   "$(ss -tln | awk '{print $4}' | grep -E ':(5000|5432)$' | grep -v '^127\.0\.0\.1:')"
check "Права ~/app/.env равны 600" "600" "$(stat -c '%a' "$HOME/app/.env" 2>/dev/null)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
