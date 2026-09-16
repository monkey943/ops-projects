# MySQL 主从复制

node1 作为主库，node2 作为从库。版本 MySQL 8.0。

## 文件

- `setup-slave.sh`：从库配置脚本，写入从库参数并建立复制关系
- `check-replication.sh`：复制状态巡检脚本，装在从库上

## 主库配置

`/etc/my.cnf.d/replication.cnf`：

```ini
[mysqld]
server-id=1
log-bin=mysql-bin
binlog-format=ROW
binlog_expire_logs_seconds=604800
```

`binlog_expire_logs_seconds` 是 8.0 的参数，单位是秒，这里是 7 天。旧版本用的 `expire_logs_days` 已经废弃，写上去不会生效。

创建复制账号，并把来源限制在从库网段：

```sql
CREATE USER 'repl'@'192.168.88.%' IDENTIFIED BY 'Repl@123456';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.88.%';
FLUSH PRIVILEGES;
```

只给从库的 IP 放行 3306，不要用 `--add-port` 对整个网段开放：

```bash
firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=192.168.88.101 port port=3306 protocol=tcp accept'
firewall-cmd --reload
```

## 从库配置

`/etc/my.cnf.d/replication.cnf`：

```ini
[mysqld]
server-id=2
relay-log=relay-bin
read_only=1
super_read_only=1
log_slave_updates=1
```

`read_only` 只阻止没有 `SUPER` 权限的账号写入，root 仍然能写。要真正禁止，需要 `super_read_only=1`。复制线程不受这两个参数影响。

这一点在验证时容易踩坑：只开 `read_only` 然后用 root 去测试，不会报错，看起来像是"只读生效了"，实际上是假阳性。

建立复制关系：

```bash
REPL_PASS='Repl@123456' MASTER_IP=192.168.88.100 \
MASTER_LOG_FILE=mysql-bin.000003 MASTER_LOG_POS=157 \
./setup-slave.sh
```

脚本会校验源地址，如果填成了从库自己会直接退出，避免把复制指向本机。

## 巡检脚本

`check-replication.sh` 装在从库上，检查两个复制线程的状态：

- 退出码 0：复制正常
- 退出码 1：复制异常，输出 `Last_IO_Error` / `Last_SQL_Error`
- 退出码 2：环境不满足（比如连不上数据库、没有复制配置）

```bash
/opt/ops/scripts/check-replication.sh
```

## 排障

查看复制状态：

```bash
mysql -uroot -e "SHOW REPLICA STATUS\G" | grep -E "Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_IO_Error|Last_SQL_Error"
```

注意字段名。MySQL 8.0.22 之后 **`Last_Error` 字段已经不存在了**，只剩 `Last_IO_Error` 和 `Last_SQL_Error`。排障命令里如果还写 `grep Last_Error`，匹配结果为空，等于把真正的错误信息过滤掉了，会让人误以为是"没有错误"。

常见的几种状态和对应方向：

- `Replica_IO_Running: Connecting`：拉不到数据。先看 `Last_IO_Error`，然后核对源地址（`SELECT HOST,USER FROM performance_schema.replication_connection_configuration;`）、测网络（`nc -zv 主库IP 3306`）、检查账号的网段限制
- `Replica_IO_Running: No`：IO 线程遇到致命错误停止，比如两台机器 server-id 相同，看 MySQL 错误日志
- `Replica_SQL_Running: No`：SQL 回放出错，看 `Last_SQL_Error`，常见是主键冲突或找不到行
- `Seconds_Behind_Source` 持续增长：复制延迟，检查从库负载、大事务、网络带宽

判断从库有没有被本地写入过，可以看从库自己的 binlog：

```bash
mysql -uroot -e "SHOW BINLOG EVENTS IN 'binlog.000002';"
```

其中 `Server_id` 等于从库 `server-id` 的记录就是本地写入。正常情况下应该只有复制过来的记录，以及首次导入数据时的记录。这类脏数据会导致主从数据不一致，而且不容易定位。

## 复制延迟

常见原因是大事务、从库单线程回放、从库机器配置偏低。可以开并行复制：

```sql
SET GLOBAL replica_parallel_type = 'LOGICAL_CLOCK';
SET GLOBAL replica_parallel_workers = 4;
STOP REPLICA;
START REPLICA;
```

另外把强一致的读请求放在主库，不要依赖从库的实时性。
