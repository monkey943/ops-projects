# 搭建过程中遇到的问题

按模块记录，每条包含现象、原因、处理方式。

## 环境准备

### 网卡名和文档里的不一致

克隆模板机后用 `nmcli device status` 看到的网卡名是 `ens33`，而按经验写的 `ens160` 找不到。

网卡名由虚拟网卡类型决定。VMware 的 e1000e 网卡对应 `ens33`，vmxnet3 对应 `ens160`。克隆或新建虚拟机时如果改过网卡类型，名字就会变。所以配静态 IP 之前先用 `nmcli device status` 确认实际名字，不要照抄。

### 克隆出来的机器标识重复

从同一台模板机克隆多台虚拟机后，`/etc/machine-id` 是一样的。不处理会导致日志混乱、DHCP 冲突、systemd 服务异常。

每台克隆机都要重新生成：

```bash
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id
```

## LNMP

### Nginx 报 502，PHP-FPM 是启动状态

`systemctl status php-fpm` 显示正常，但访问 PHP 页面返回 502。

两个原因都会导致这个现象：

1. `www.conf` 里的 `listen` 和 Nginx 配置里 `fastcgi_pass` 的地址不一致。一边是 unix socket，一边是 `127.0.0.1:9000`，浏览器上就只看到 502。
2. `www.conf` 里的 `user` 还是默认的 `apache`，而系统里没有这个用户。PHP-FPM 能启动，但处理请求时失败。

排查时把两边对照一下：

```bash
grep -E '^(user|group|listen)' /etc/php-fpm.d/www.conf
grep -n 'fastcgi_pass' /etc/nginx/conf.d/blog.conf
```

### 站点目录报 403

目录属主和权限都正确，仍然返回 403，`error.log` 里是 `Permission denied`。

这种多半是 SELinux 的文件上下文问题。用 `ls -Z` 可以看到目录的上下文是 `default_t` 而不是 `httpd_sys_content_t`。恢复：

```bash
restorecon -Rv /var/www/html
```

生产环境不建议直接关闭 SELinux，应该用 `semanage fcontext` 加规则再 `restorecon`。

## MySQL

### 用 root 验证从库只读，没有报错

配置里写了 `read_only=1`，用 root 执行 INSERT 却能成功，看起来是只读没生效。

实际上 `read_only` 只阻止没有 `SUPER` 权限的账号写入，root 带 `SUPER` 权限，不受限制。这是一个假阳性：不报错不等于没生效，只是验证用的账号权限太高。

要真正禁止写入，需要开 `super_read_only=1`。复制线程不受这两个参数影响，仍然可以正常回放。

### 排障脚本里 grep Last_Error 什么都匹配不到

`SHOW REPLICA STATUS` 的输出里没有 `Last_Error` 字段，脚本里的 `grep Last_Error` 返回空，于是判断"没有错误"，实际上错误信息就在旁边被漏掉了。

MySQL 8.0.22 起这个字段已经拆成两个：`Last_IO_Error` 和 `Last_SQL_Error`，分别对应 IO 线程和 SQL 线程。排障时按线程分开看，反而更容易定位。

网上的很多资料还是老版本的写法，照抄会踩这个坑。

### binlog 没有自动清理

按旧文档配了 `expire_logs_days=7`，但 binlog 还是一直堆积。

这个参数在 MySQL 8.0 已经废弃，虽然写上去不报错，但不生效。8.0 用的是秒为单位的 `binlog_expire_logs_seconds`：

```ini
binlog_expire_logs_seconds=604800
```

### 复制起不来，IO 线程一直是 Connecting

`SHOW REPLICA STATUS` 里 `Replica_IO_Running` 显示 `Connecting`，`Last_IO_Error` 指向连接失败。

按下面的顺序排查，基本能覆盖：

1. 源地址是否填对：`SELECT HOST,USER FROM performance_schema.replication_connection_configuration;`。填成从库自己是最常见的手误
2. 网络和防火墙：从从库上 `nc -zv <主库IP> 3306`
3. 账号和网段：主库上 `SELECT user,host FROM mysql.user WHERE user='repl';`，确认 host 和从库的 IP 匹配
4. 主库的 binlog 是否还在，位点是否填对

为此在 `setup-slave.sh` 里加了源地址校验：如果 `MASTER_IP` 等于从库自己的 IP，脚本直接退出。

### 两台机器 server-id 相同

`Replica_IO_Running: No`，MySQL 错误日志里有明确的提示。

`server-id` 在主从之间必须唯一，主库是 1，从库是 2。虚拟机克隆的场景下很容易两台配置一模一样。

## Prometheus

### CPU 使用率显示为负数

Grafana 上出现负的 CPU 使用率。

表达式是 `100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100`，出现负数说明 `rate()` 的结果大于 1。

`rate()` 表示计数器每秒的增长量。`node_cpu_seconds_total` 单位是秒，一个核心每秒最多增长 1，正常不可能超过 1。超过只有一种解释：**采集到的样本数据本身有问题，具体说是时间不对**。

计数器按机器自己的时间累加，Prometheus 按自己的时间给样本打时间戳。两边速率不同，算出来的比值就不等于 1。

判断这台机器的时间偏差：

```promql
deriv(node_time_seconds[5m])
```

结果约 1.08，说明机器时间比真实时间快 8% 左右。8.33% 是 chrony 默认的最大校时速率，说明它正在追赶时间。

确认同步状态：

```promql
node_timex_sync_status
```

值为 0 表示未同步。

触发场景是宿主机休眠、虚拟机快照恢复或挂起。机器被冻结期间时钟不走，恢复后落后几个小时。chrony 默认只在启动后的前几次校时允许跳变，之后只能以最大 8.33% 的速度缓慢校正，差几个小时需要很久才能追上，这段时间内这台机器的监控数据都是不可信的。

修复：

```bash
chronyc makestep
```

或重启 chronyd，让它重新满足跳变条件。

> 补充：判断时钟状态要看 `node_timex_sync_status`。`node_timex_offset_seconds` 在校时过程中可能仍然显示 0，单看它会得出错误结论。

### 改了告警规则但没有生效

修改了规则文件，也执行了 `promtool check rules`（通过），但告警行为没变。

`promtool` 只校验语法，不负责加载。规则文件改了之后需要让 Prometheus 重新读取，前提是启动时带了 `--web.enable-lifecycle`：

```bash
curl -X POST localhost:9090/-/reload
```

确认实际生效的规则应该看运行时的接口，而不是看文件：

```bash
curl -s localhost:9090/api/v1/rules
```

### 单台机器 CPU 跑满但不触发告警

告警规则的表达式如果写成 `100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90`，三台机器的数据会先被平均成一个值，单台跑满时整体平均未必超过阈值。

要按实例分别判断，加上 `by (instance)`：

```yaml
expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
```

### 告警恢复后没有通知

Alertmanager 的接收器配置里如果没有开 `send_resolved: true`，问题恢复时不会发消息。运维不知道问题好没好，只能自己去查，时间长了告警就会被静默掉，等于失效。
