#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                       # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
# Работа из любого каталога: переходим в корень репозитория. Путь site/ задаётся относительно него:
# в Git Bash --show-toplevel возвращает путь вида F:/..., который rsync принял бы за удалённый узел «F».
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
LOCAL_DIR="site/"
SSH_OPTS="ssh -o BatchMode=yes -o ConnectTimeout=5"                  # без интерактивного пароля

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN="--dry-run" ;;
  *) echo "Использование: $0 [--dry-run]" >&2; exit 1 ;;
esac

# 2. Проверки по требованиям 4 и 5
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
  echo "Ошибка: ${LOCAL_DIR}index.html не найден — доставка отменена" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Ошибка: в репозитории есть незафиксированные изменения — доставка отменена" >&2
  git status --short >&2
  exit 1
fi

# 3. Синхронизация: точная копия site/ с правами 755/644, одно SSH-соединение
rsync -az --delete --itemize-changes --chmod=D755,F644 -e "$SSH_OPTS" $DRY_RUN \
  "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение без проверки доступности
if [[ -n "$DRY_RUN" ]]; then
  echo "Пробный запуск: состояние сервера не изменено"
  exit 0
fi

# 5. Проверка доступности с проверкой сертификата
if ! curl -fsS --max-time 5 --cacert "$CA_CERT" -o /dev/null "$SITE_URL/"; then
  echo "Ошибка: ресурс $SITE_URL недоступен после доставки" >&2
  exit 1
fi
echo "Доставлен коммит $(git rev-parse --short HEAD)"
