#!/bin/bash
# 进程守护脚本，若服务停止则自动重启
# 配合 crontab 每5分钟执行一次
# 环境变量：HEALTH_CHECK_LOG, HEALTH_CHECK_SERVICES

LOG_FILE=${HEALTH_CHECK_LOG:-/var/log/health-check.log}
SERVICES=${HEALTH_CHECK_SERVICES:-"nginx:nginx php-fpm:php-fpm"}

# 确保日志目录存在
mkdir -p $(dirname $LOG_FILE)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

restart_service() {
    local service=$1
    if systemctl restart $service; then
        log "INFO: $service 重启成功"
    else
        log "ERROR: $service 重启失败"
    fi
}

check_and_restart() {
    local service=$1
    local process_name=$2

    if ! pgrep -x "$process_name" > /dev/null; then
        log "WARNING: $service 进程未运行，正在重启..."
        restart_service $service
    fi
}

# 检查各服务
for item in $SERVICES; do
    service=$(echo $item | cut -d: -f1)
    process=$(echo $item | cut -d: -f2)
    check_and_restart "$service" "$process"
done