#!/bin/bash
# setup_ssh.sh — настройка SSH-ключей и отключение входа по паролю
# Запуск: sudo bash setup_ssh.sh
#
# ВАЖНО: перед запуском скопируйте свой публичный SSH-ключ на этот хост:
#   ssh-copy-id ubuntu@IP_ХОСТА
#
# Скрипт НЕ отключит пароль, если проверка входа по ключу не пройдёт.

set -e

if [ "$EUID" -ne 0 ]; then
   echo "❌ Запустите от root: sudo bash $0"
   exit 1
fi

echo "============================================================"
echo "Настройка SSH-ключей"
echo "============================================================"

# ============================================================
# 1. ОПРЕДЕЛЕНИЕ ЦЕЛЕВОГО ПОЛЬЗОВАТЕЛЯ
# ============================================================
# Скрипт запускается от root через sudo. Ключ был скопирован
# пользователю, который запустил sudo. Берём его из SUDO_USER.
TARGET_USER="${SUDO_USER:-ubuntu}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
AUTHORIZED_KEYS="${TARGET_HOME}/.ssh/authorized_keys"

echo ""
echo "Целевой пользователь: $TARGET_USER"
echo "Файл ключей: $AUTHORIZED_KEYS"
echo ""

# ============================================================
# 2. ПРОВЕРКА, ЧТО ФАЙЛ С КЛЮЧАМИ СУЩЕСТВУЕТ
# ============================================================
if [ ! -s "$AUTHORIZED_KEYS" ]; then
   echo "❌ Файл $AUTHORIZED_KEYS отсутствует или пуст."
   echo ""
   echo "С машины, откуда вы работаете, выполните:"
   LOCAL_IP=$(hostname -I | awk '{print $1}')
   echo "    ssh-copy-id ${TARGET_USER}@${LOCAL_IP}"
   echo ""
   echo "После этого запустите скрипт снова."
   exit 1
fi

KEY_COUNT=$(grep -c "ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo 0)
echo "✅ Найдено ключей: $KEY_COUNT"
echo ""

# ============================================================
# 3. ПРОВЕРКА ВХОДА ПО КЛЮЧУ (ДО ИЗМЕНЕНИЙ)
# ============================================================
echo "=== Проверка входа по ключу ==="

LOCAL_IP=$(hostname -I | awk '{print $1}')

if ssh -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      "${TARGET_USER}@${LOCAL_IP}" "echo ok" &>/dev/null; then
   echo "✅ Вход по ключу для ${TARGET_USER}@${LOCAL_IP} работает"
else
   echo "❌ Вход по ключу НЕ работает."
   echo ""
   echo "Проверьте:"
   echo "  1. Ключ действительно скопирован:"
   echo "       ssh-copy-id ${TARGET_USER}@${LOCAL_IP}"
   echo "  2. Права на файлы:"
   echo "       chmod 700 ${TARGET_HOME}/.ssh"
   echo "       chmod 600 ${AUTHORIZED_KEYS}"
   echo "       chown -R ${TARGET_USER}:${TARGET_USER} ${TARGET_HOME}/.ssh"
   echo ""
   echo "⚠️  Пароль НЕ отключён — доступ сохранён."
   exit 1
fi

# ============================================================
# 4. ПРАВА НА ФАЙЛЫ КЛЮЧЕЙ
# ============================================================
echo ""
echo "=== Права на файлы ключей ==="
chmod 700 "${TARGET_HOME}/.ssh"
chmod 600 "$AUTHORIZED_KEYS"
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.ssh"
echo "✅ Права выставлены"

# ============================================================
# 5. ОТКЛЮЧЕНИЕ ВХОДА ПО ПАРОЛЮ
# ============================================================
echo ""
echo "=== Отключение входа по паролю ==="

# В Ubuntu 26.04 настройки SSH разнесены по файлам в sshd_config.d/.
# Файл 99-... имеет приоритет над остальными (60-cloudimg-settings.conf и т.д.)
cat > /etc/ssh/sshd_config.d/99-no-password.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF

# Проверяем синтаксис конфига перед перезапуском
if ! sshd -t; then
   echo "❌ Ошибка в конфиге SSH. Откатываю изменения."
   rm -f /etc/ssh/sshd_config.d/99-no-password.conf
   exit 1
fi

systemctl restart ssh
systemctl restart ssh.socket 2>/dev/null || true

sleep 1

# ============================================================
# 6. ПРОВЕРКА, ЧТО КЛЮЧ ВСЁ ЕЩЁ РАБОТАЕТ
# ============================================================
echo ""
echo "=== Проверка после перезапуска SSH ==="

if ssh -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no \
      "${TARGET_USER}@${LOCAL_IP}" "echo ok" &>/dev/null; then
   echo "✅ Вход по ключу после перезапуска работает"
else
   echo "❌ После отключения пароля вход по ключу сломался!"
   echo "   Откатываю изменения, чтобы не потерять доступ..."
   rm -f /etc/ssh/sshd_config.d/99-no-password.conf
   systemctl restart ssh
   systemctl restart ssh.socket 2>/dev/null || true
   echo "⚠️  Пароль снова разрешён. Разберитесь с ключами и запустите скрипт снова."
   exit 1
fi

# ============================================================
# 7. ПРОВЕРКА ЭФФЕКТИВНОЙ КОНФИГУРАЦИИ
# ============================================================
echo ""
echo "=== Текущая эффективная конфигурация SSH ==="
sshd -T | grep -E "passwordauthentication|pubkeyauthentication|permitrootlogin|kbdinteractiveauthentication"

if sshd -T | grep -q "^passwordauthentication yes"; then
   echo ""
   echo "⚠️  Пароль всё ещё разрешён — что-то переопределяет настройку."
   echo "   Проверьте: ls /etc/ssh/sshd_config.d/"
   echo "   Возможно, другой файл имеет высший приоритет."
else
   echo ""
   echo "✅ Вход по паролю отключён. Теперь только ключи."
fi

# ============================================================
# ИТОГ
# ============================================================
echo ""
echo "============================================================"
echo "✅ Настройка SSH завершена"
echo "============================================================"
echo ""
echo "Проверьте вход по ключу с машины, откуда вы работаете:"
echo "  ssh ${TARGET_USER}@${LOCAL_IP}"
echo ""
echo "Если что-то пошло не так и вы потеряли SSH:"
echo "  Зайдите через консоль хостера и удалите файл:"
echo "  sudo rm /etc/ssh/sshd_config.d/99-no-password.conf"
echo "  sudo systemctl restart ssh"
echo "  Пароль снова заработает."
echo ""
