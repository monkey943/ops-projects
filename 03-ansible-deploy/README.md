# Ansible 批量部署 LNMP

从 node3 作为控制机，批量在 node1、node2 上部署 LNMP 环境。

## 文件

- `ansible.cfg`：控制机配置（inventory 路径、并发数、SSH 参数）
- `inventory/hosts`：主机清单
- `playbooks/deploy_lnmp.yml`：部署剧本
- `playbooks/files/blog.conf`：分发的 Nginx 配置模板

## 前置条件

控制机到被管节点要配置好 SSH 免密。被管节点只需要有 Python 3，不需要装 agent。

验证连通性：

```bash
cd 03-ansible-deploy
ansible all -m ping
```

## 执行

```bash
# 语法检查
ansible-playbook playbooks/deploy_lnmp.yml --syntax-check

# 试运行，只报告会改什么
ansible-playbook playbooks/deploy_lnmp.yml --check --diff

# 只在单台机器上试
ansible-playbook playbooks/deploy_lnmp.yml --limit node1

# 确认无误后全量执行
ansible-playbook playbooks/deploy_lnmp.yml
```

## 幂等性

playbook 里用的是 `dnf`、`file`、`copy`、`lineinfile`、`systemd` 这些模块，它们会先检查当前状态，只做必要的变更。

连续执行两次，第二次的 `PLAY RECAP` 应该是：

```
node1 : ok=12  changed=0  unreachable=0  failed=0
node2 : ok=12  changed=0  unreachable=0  failed=0
```

`changed=0` 说明没有产生任何变更。如果用 `shell` 模块做 `echo >>` 这类追加操作，每执行一次就会多一行，幂等性就被破坏了。

## handler

`notify` 只在对应任务的执行结果是 `changed` 时触发，并且一轮 play 结束后统一执行一次。所以多个任务改了 Nginx 配置，Nginx 也只会重载一次。
