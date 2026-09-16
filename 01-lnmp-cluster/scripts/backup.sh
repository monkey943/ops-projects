#!/bin/bash
# 网站文件 + 数据库每日备份脚本
# 完整操作步骤见 docs/02-操作手册/2.4-MySQL主从复制与备份.md
#
# 环境变量（全部有默认值，可按需覆盖）：
#   DB_NAME / DB_USER / DB_PASS / DB_HOST / WEB_DIR / BACKUP_DIR / RETENTION
#
# 用法：
#   DB_NAME=blog DB_HOST=localhost /opt/ops/scripts/backup.sh
#
# 安全建议：生产环境不要在这里写明文密码，改用 ~/.my.cnf（chmod 600）
#          或 mysql_config_editor 生成的加密登录路径。

set -uo pipefail

DATE=$(date +%F)
BACKUP_DIR=${BACKUP_DIR:-/backup/www}
DB_NAME=${DB_NAME:-blog}
DB_USER=${DB_USER:-root}
DB_PASS=${DB_PASS:-}
DB_HOST=${DB_HOST:-localhost}
WEB_DIR=${WEB_DIR:-/var/www/html}
RETENTION=${RETENTION:-7}
LOG_FILE=${LOG_FILE:-/var/log/backup.log}

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"; }

# ---------- 1. 备份数据库 ----------
if [ -n "$DB_PASS" ]; then
    MYSQL_OPTS="-h$DB_HOST -u$DB_USER -p$DB_PASS"
else
    MYSQL_OPTS="-h$DB_HOST -u$DB_USER"
fi

DB_DUMP="${BACKUP_DIR}/${DB_NAME}_${DATE}.sql"
# shellcheck disable=SC2086
if mysqldump $MYSQL_OPTS --single-transaction --databases "$DB_NAME" > "$DB_DUMP" 2>>"$LOG_FILE"; then
    log "OK 数据库备份完成：$DB_DUMP ($(du -h "$DB_DUMP" | cut -f1))"
else
    log "ERROR 数据库备份失败：$DB_NAME"
    rm -f "$DB_DUMP"
fi

# ---------- 2. 备份网站文件 ----------
if [ -d "$WEB_DIR" ]; then
    WEB_TAR="${BACKUP_DIR}/www_${DATE}.tar.gz"
    if tar -czf "$WEB_TAR" "$WEB_DIR" 2>>"$LOG_FILE"; then
        log "OK 网站文件备份完成：$WEB_TAR ($(du -h "$WEB_TAR" | cut -f1))"
    else
        log "ERROR 网站文件备份失败：$WEB_DIR"
    fi
else
    log "WARN 网站目录不存在，跳过：$WEB_DIR"
fi

# ---------- 3. 清理过期备份 ----------
DELETED=$(find "$BACKUP_DIR" -type f \( -name "*.sql" -o -name "*.tar.gz" \) -mtime +"$RETENTION" -print -delete | wc -l)
log "OK 清理过期备份 $DELETED 个（保留 $RETENTION 天）"
