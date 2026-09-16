# Linux 集群运维实践

三台 Rocky Linux 9 虚拟机组成的实验集群，用于实践一套完整的运维链路：Web 集群、七层负载均衡、配置管理、数据库主从复制与监控告警。

## 环境

| 主机 | IP | 角色 |
| --- | --- | --- |
| node1 | 192.168.88.100 | Web 节点（Nginx + PHP-FPM）、MySQL 主库 |
| node2 | 192.168.88.101 | Web 节点（Nginx + PHP-FPM）、MySQL 从库 |
| node3 | 192.168.88.102 | Nginx 负载均衡、Ansible 控制机、监控服务端 |

- 虚拟化：VMware Workstation，NAT 网络（VMnet8）
- 操作系统：Rocky Linux 9（最小化安装）
- 单节点规格：2 vCPU / 2GB 内存 / 20GB 磁盘

## 架构

```
                    客户端
                      |
                      v
              node3  192.168.88.102
              Nginx 七层负载均衡（轮询 + 失败剔除）
                      |
          +-----------+-----------+
          v                       v
   node1 192.168.88.100    node2 192.168.88.101
   Nginx + PHP-FPM         Nginx + PHP-FPM
   MySQL 主库  ----------------->  MySQL 从库
          ^                       ^
          |                       |
          +----- node_exporter ----+
                      |
                      v
   node3  Prometheus -> Alertmanager -> webhook -> 钉钉
          Grafana（看板）
```

## 模块

| 目录 | 内容 |
| --- | --- |
| `01-lnmp-cluster` | LNMP 环境、Nginx 虚拟主机、网站与数据库备份脚本 |
| `02-nginx-lb` | Nginx 七层负载均衡配置 |
| `03-ansible-deploy` | Ansible 批量部署 LNMP（含 ansible.cfg、inventory、playbook） |
| `04-mysql-replication` | MySQL 主从复制配置脚本与复制状态巡检脚本 |
| `05-monitoring` | Prometheus 告警规则 |
| `common-scripts` | 通用运维脚本（磁盘告警、服务守护） |

## 部署顺序

1. 准备三台 Rocky Linux 9 虚拟机，按上表配置静态 IP 并配置 SSH 免密
2. 在 node1、node2 上部署 LNMP 环境（`01-lnmp-cluster`）
3. 在 node3 上配置负载均衡（`02-nginx-lb`）
4. 用 Ansible 从 node3 批量部署到 node1、node2（`03-ansible-deploy`）
5. 在 node1、node2 上配置 MySQL 主从复制（`04-mysql-replication`）
6. 在三台机器上部署 node_exporter，在 node3 上部署 Prometheus、Alertmanager、Grafana（`05-monitoring`）

Ansible 部分可以一条命令完成第 2 步：

```bash
cd 03-ansible-deploy
ansible-playbook playbooks/deploy_lnmp.yml --syntax-check
ansible-playbook playbooks/deploy_lnmp.yml --check --diff
ansible-playbook playbooks/deploy_lnmp.yml
```

playbook 是幂等的：连续执行两次，第二次的 `PLAY RECAP` 应该是 `changed=0`。

## 脚本

| 脚本 | 说明 |
| --- | --- |
| `common-scripts/health-check.sh` | 检查服务进程，异常时自动重启。配合 crontab 定时执行 |
| `common-scripts/disk-alert.py` | 磁盘使用率超过阈值时通过钉钉机器人告警 |
| `01-lnmp-cluster/scripts/backup.sh` | 数据库与网站文件备份，带错误处理和过期清理 |
| `04-mysql-replication/setup-slave.sh` | 从库复制配置，含源地址校验，防止把源填成从库自己 |
| `04-mysql-replication/check-replication.sh` | 复制状态巡检，装在从库上；退出码 0/1/2 分别表示正常、异常、环境不满足 |

脚本的敏感参数（数据库密码、Webhook 地址）通过环境变量传入，不写死在文件里。

## 故障排查记录

搭建过程中遇到的一些问题记录在 [docs/troubleshooting.md](docs/troubleshooting.md)，包括：

- MySQL 8.0.22 之后 `SHOW REPLICA STATUS` 的字段变化，以及由此导致的排障脚本失效
- `read_only` 无法阻止 root 写入，以及验证从库只读时的假阳性问题
- Prometheus 采集到的 CPU 使用率变成负数，根因是宿主机休眠导致的时钟漂移

## 说明

本仓库记录的是实验室环境的搭建过程。要用于生产环境，还需要补充高可用（负载均衡器自身、数据库故障切换）、备份策略与恢复演练、以及基于堡垒机的权限管控。
