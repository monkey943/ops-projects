#!/bin/bash
# MySQL 8.0 从库一键配置脚本（在从库 node2 上执行）
# 完整操作步骤见 docs/02-操作手册/2.4-MySQL主从复制与备份.md
#
# 环境变量（除 MASTER_IP / REPL_PASS / 位点外都有默认值）：
#   MASTER_IP                主库 IP（必填，且不能是本机地址）
#   REPL_PASS                复制账号密码（必填；不传则交互式输入）
#   MYSQL_USER / MYSQL_PASS  本机 MySQL 账号（默认 root 无密码，走 socket 登录）
#   REPL_USER                复制账号名（默认 repl）
#   MASTER_LOG_FILE / _POS   主库位点；不传则交互式询问
#   CNF                      从库配置文件（默认 /etc/my.cnf.d/replication.cnf）
#   DRY_RUN=1                演练：只打印将执行的 SQL、不重启 mysqld、不建立复制
#                            （配合 CNF=/tmp/x.cnf 可以安全地试跑配置生成）
#
# 用法示例：
#   REPL_PASS='Repl@123456' MASTER_IP=192.168.88.100 \
#   MASTER_LOG_FILE=mysql-bin.000001 MASTER_LOG_POS=1742 ./setup-slave.sh
#
# 注意：MASTER_IP 必须是【主库】的 IP。填成从库自己的 IP 会被本脚本直接拦下——
#       那种情况下 IO 线程只会一直卡在 Connecting（errno 1130），而 SQL 线程仍显示 Yes，
#       很容易被误判成「复制是好的」。

set -uo pipefail

MYSQL_USER=${MYSQL_USER:-root}
MYSQL_PASS=${MYSQL_PASS:-}
MASTER_IP=${MASTER_IP:-}
REPL_USER=${REPL_USER:-repl}
REPL_PASS=${REPL_PASS:-}
CNF=${CNF:-/etc/my.cnf.d/replication.cnf}
DRY_RUN=${DRY_RUN:-0}

mysql_exec() {
    if [ -n "$MYSQL_PASS" ]; then
        mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$@"
    else
        mysql -u"$MYSQL_USER" "$@"
    fi
}

# ---------- 0. 参数校验（先校验再动手，避免改到一半才发现参数错） ----------
[ -n "$MASTER_IP" ] || read -rp "主库 IP（如 192.168.88.100）: " MASTER_IP
if [ -z "$REPL_PASS" ]; then
    read -rsp "复制账号 $REPL_USER 的密码: " REPL_PASS
    echo
fi

if echo " $(hostname -I) " | grep -q " ${MASTER_IP} "; then
    echo "[ERROR] MASTER_IP=$MASTER_IP 是本机地址——复制源不能填从库自己。"
    echo "   请填【主库】的 IP，例如：MASTER_IP=192.168.88.100 $0"
    exit 1
fi

# ---------- 1. 补齐从库配置（增量修改，保留文件里已有的注释） ----------
# 只补「缺失或值不对」的项，已经正确的行一个字都不动。
# （不要用「文件里有 server-id=2 就整体跳过」的写法：后加的 super_read_only 会永远不生效。）
REQUIRED_CNF="server-id=2 relay-log=relay-bin read_only=1 super_read_only=1 log_slave_updates=1"

ensure_cnf() {
    local line key val
    CNF_CHANGED=0
    if [ ! -f "$CNF" ]; then
        printf '[mysqld]\n' > "$CNF"
        CNF_CHANGED=1
    fi
    for line in $REQUIRED_CNF; do
        key=${line%%=*}
        val=${line#*=}
        if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*${val}[[:space:]]*$" "$CNF"; then
            # 删掉同名但值不对（或缺失）的旧行，再补上正确的
            sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/d" "$CNF"
            echo "$line" >> "$CNF"
            echo "   + $line"
            CNF_CHANGED=1
        fi
    done
}

echo "[1/3] 检查从库配置 $CNF"
ensure_cnf
if [ "$CNF_CHANGED" = "1" ]; then
    echo "   配置有变更，需要重启 mysqld 生效："
    if [ "$DRY_RUN" = "1" ]; then
        echo "   [dry-run] 跳过重启"
    else
        systemctl restart mysqld
        sleep 3
    fi
else
    echo "   配置已是最新，无需重启"
fi

# ---------- 2. 获取主库位点 ----------
if [ -z "${MASTER_LOG_FILE:-}" ] || [ -z "${MASTER_LOG_POS:-}" ]; then
    echo ""
    echo "请先在【主库】执行： mysql -uroot -e \"SHOW MASTER STATUS\\G\""
    read -rp "主库 binlog 文件名（如 mysql-bin.000001）: " MASTER_LOG_FILE
    read -rp "主库 binlog 位置（如 1742）: " MASTER_LOG_POS
fi

# ---------- 3. 建立并启动复制 ----------
# GET_SOURCE_PUBLIC_KEY=1：主库复制账号用 caching_sha2_password 且未走 TLS 时，
# 需要它来取服务端公钥，否则会报 2061 Authentication requires secure connection。
CHANGE_SQL=$(cat <<EOF
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='$MASTER_IP',
  SOURCE_USER='$REPL_USER',
  SOURCE_PASSWORD='$REPL_PASS',
  SOURCE_LOG_FILE='$MASTER_LOG_FILE',
  SOURCE_LOG_POS=$MASTER_LOG_POS,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
EOF
)

echo "[2/3] 配置并启动复制，源=$MASTER_IP（位点 $MASTER_LOG_FILE:$MASTER_LOG_POS）"
if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] 将执行："
    echo "$CHANGE_SQL" | sed -e "s/\(SOURCE_PASSWORD=\)[^,]*,/\1'******',/" -e 's/^/     /'
else
    echo "$CHANGE_SQL" | mysql_exec
fi

# ---------- 4. 检查结果 ----------
echo "[3/3] 复制状态："
if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] 跳过检查"
    exit 0
fi

# 8.0.22+ 没有 Last_Error 字段，只 grep 它会什么都看不到，必须带上这两个
mysql_exec -e "SHOW REPLICA STATUS\G" | grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error|Last_SQL_Error"

IO=$(mysql_exec -N -e "SHOW REPLICA STATUS\G" | grep "Replica_IO_Running:" | awk '{print $2}')
SQLR=$(mysql_exec -N -e "SHOW REPLICA STATUS\G" | grep "Replica_SQL_Running:" | awk '{print $2}')

if [ "$IO" = "Yes" ] && [ "$SQLR" = "Yes" ]; then
    echo "[OK] 复制已建立成功"
    mysql_exec -N -e "SELECT CONCAT('   只读状态（都要是 1）：read_only=', @@read_only, '  super_read_only=', @@super_read_only);"
    echo "   复制源（HOST 必须是主库 IP）："
    mysql_exec -e "SELECT CHANNEL_NAME,HOST,PORT,USER FROM performance_schema.replication_connection_configuration;"
else
    echo "[ERROR] 复制未建立成功（Replica_IO_Running=$IO, Replica_SQL_Running=$SQLR）"
    echo "   请看上面的 Last_IO_Error / Last_SQL_Error —— 注意 8.0.22+ 已没有 Last_Error 字段"
    exit 1
fi
