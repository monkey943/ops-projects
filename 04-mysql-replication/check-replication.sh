#!/bin/bash
# MySQL 复制状态巡检脚本
#
# 注意：必须在从库上执行（本套是 node2）。
#    在主库上执行时 SHOW REPLICA STATUS 永远是空的——那不是复制坏了，是跑错机器了。
#
# 用法：
#   /opt/ops/scripts/check-replication.sh
#
# 退出码（接告警时按这个判断）：
#   0 = 复制正常
#   1 = 复制异常（IO/SQL 线程异常，或延迟超过 MAX_DELAY）
#   2 = 环境不对（连不上 MySQL，或本机根本不是从库）——不是复制的问题，别误告警
#
# 环境变量：
#   MYSQL_USER / MYSQL_PASS   本机 MySQL 账号（默认 root 无密码，走 socket）
#   MAX_DELAY                 允许的最大延迟秒数（默认 60）
#
# 完整说明见 docs/02-操作手册/2.4-MySQL主从复制与备份.md 步骤 12

set -uo pipefail

MYSQL_USER=${MYSQL_USER:-root}
MYSQL_PASS=${MYSQL_PASS:-}
MAX_DELAY=${MAX_DELAY:-60}

mysql_q() {
    if [ -n "$MYSQL_PASS" ]; then
        mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$@"
    else
        mysql -u"$MYSQL_USER" "$@"
    fi
}

TS=$(date '+%F %T')

# ---------- 1. MySQL 连得上吗 ----------
if ! ERR=$(mysql_q -N -e "SELECT 1" 2>&1); then
    echo "[$TS] ERROR 连不上 MySQL：$ERR"
    exit 2
fi

# ---------- 2. 本机是不是从库 ----------
STATUS=$(mysql_q -e "SHOW REPLICA STATUS\G" 2>/dev/null)
if [ -z "$STATUS" ]; then
    echo "[$TS] SKIP 本机没有复制配置（不是从库），本脚本要在【从库】上跑。"
    echo "       当前机器：$(hostname) $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "       主库上 SHOW REPLICA STATUS 永远是空的，这不代表复制有故障。"
    exit 2
fi

# ---------- 3. 取关键指标 ----------
IO=$(echo "$STATUS"    | grep "Replica_IO_Running:"    | awk '{print $2}')
SQLR=$(echo "$STATUS"  | grep "Replica_SQL_Running:"   | awk '{print $2}')
DELAY=$(echo "$STATUS" | grep "Seconds_Behind_Source:" | awk '{print $2}')
LAST_IO=$(echo "$STATUS"  | grep "Last_IO_Error:"  | sed 's/^ *Last_IO_Error: //')
LAST_SQL=$(echo "$STATUS" | grep "Last_SQL_Error:" | sed 's/^ *Last_SQL_Error: //')

# 主库长时间无写入时 Seconds_Behind_Source 是 NULL，按 0 处理（不能拿它判断故障）
case "$DELAY" in ''|NULL) DELAY=0 ;; esac

# ---------- 4. 判定 ----------
if [ "$IO" = "Yes" ] && [ "$SQLR" = "Yes" ] && [ "$DELAY" -le "$MAX_DELAY" ] 2>/dev/null; then
    echo "[$TS] OK 复制正常，延迟 ${DELAY}s"
    exit 0
fi

echo "[$TS] ERROR 复制异常！Replica_IO_Running=$IO Replica_SQL_Running=$SQLR 延迟=${DELAY}s"
# 注意：MySQL 8.0.22+ 没有 Last_Error 字段，真正的错误在这两个里面
[ -n "$LAST_IO" ]  && echo "        Last_IO_Error : $LAST_IO"
[ -n "$LAST_SQL" ] && echo "        Last_SQL_Error: $LAST_SQL"
echo "        常见原因：源地址填错(1130) / 网络或 3306 不通 / 账号权限网段不对 / SQL 回放冲突"
exit 1
