# Prometheus 监控与告警

node3 作为监控服务端，采集三台机器的指标并通过钉钉发送告警。

## 链路

```
node_exporter（三台）-> Prometheus（node3:9090）-> Alertmanager（node3:9093）
                                                       |
                                                       v
                                        webhook 转发（node3:8060）-> 钉钉机器人
Prometheus -> Grafana（node3:3000）
```

Alertmanager 原生不支持钉钉，只支持 webhook、邮件、企业微信等。中间需要加一个转发层把告警的 JSON 转成钉钉要求的格式。

## 文件

- `prometheus-rules.yml`：告警规则

## 告警规则

当前包含四条：CPU 使用率过高、内存使用率过高、根分区可用空间不足、节点失联。

每条规则都配了 `for`，表示条件需要持续满足一段时间才触发。不设 `for` 的话，一次瞬时抖动就会发出告警。

CPU 使用率的表达式：

```yaml
expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
```

结果要按实例聚合。不加 `by (instance)` 的话，三台机器的数据会被平均成一个值，某一台跑满时不一定能触发。

改完规则文件不会自动生效，需要让 Prometheus 重新加载：

```bash
curl -X POST localhost:9090/-/reload
```

这个接口需要启动时带 `--web.enable-lifecycle`。`promtool check rules` 只校验语法，不保证规则真的被加载了，排查时应该看实际生效的内容：

```bash
curl -s localhost:9090/api/v1/rules
```

## 一个踩过的坑：CPU 使用率变成负数

现象是 Grafana 上出现负的 CPU 使用率。这条表达式用的是 `100 - rate(空闲时间)`，出现负数说明 `rate()` 算出来大于 1。

`rate()` 的含义是"计数器每秒增长了多少"。`node_cpu_seconds_total` 的单位是秒，一个核心每秒钟最多涨 1，所以正常情况下列率不会超过 1。超过 1 只有一种可能：**机器的时间不对**。

计数器是按机器自己的时间累加的，而 Prometheus 给样本打的时间戳是按 Prometheus 服务器的时间。两边速率不一致，比值就不再是 1。用下面这条查询可以看出这台机器的时间偏差：

```promql
deriv(node_time_seconds[5m])
```

结果接近 1.08，说明这台机器的时间比真实时间快了约 8%。8.33% 正好是 chrony 默认的最大校时速率，说明它正在缓慢追赶时间。

判断根因看这个指标：

```promql
node_timex_sync_status
```

值为 0 表示时钟没有和 NTP 同步。

**触发场景**：宿主机休眠、虚拟机快照恢复、虚拟机挂起。机器被冻住的时候时钟不走，恢复之后就落后了。chrony 默认只在启动后的前几次校时允许跳变，之后只能以最大 8.33% 的速率缓慢校正，如果差了几个小时，需要很久才能追上，这段时间内监控数据都是不可信的。

**修复**：

```bash
chronyc makestep
```

或者重启 chronyd 让它重新满足跳变条件。

顺带补充两个判断时钟状态的指标：`node_timex_sync_status`（1 表示已同步）和 `node_timex_offset_seconds`（偏移秒数）。注意在校时过程中 offset 读数可能仍然显示为 0，要看 sync_status 才准。

## 部署要点

- 三台机器都装 node_exporter，监听 9100，只对 node3 放行
- Prometheus 抓取配置里列出三个 target
- Grafana 接 Prometheus 数据源时地址填 `http://localhost:9090`，填外网 IP 会被 SSRF 防护拦下
