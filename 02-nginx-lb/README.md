# Nginx 七层负载均衡

在 node3 上做统一入口，把请求分发到 node1、node2 两台 Web 节点。

## 配置

`nginx-lb.conf`：upstream 里定义后端节点，默认使用轮询。

```nginx
upstream web_cluster {
    server 192.168.88.100:80 max_fails=3 fail_timeout=30s;
    server 192.168.88.101:80 max_fails=3 fail_timeout=30s;
}
```

`upstream` 必须定义在 `http` 层级，放在 `/etc/nginx/conf.d/` 下正好在 `http` 块内。

部署：

```bash
cp nginx-lb.conf /etc/nginx/conf.d/
nginx -t && systemctl reload nginx
firewall-cmd --permanent --add-service=http && firewall-cmd --reload
```

## 验证

两个 Web 节点的测试页会输出各自的主机名，连续请求就能看到轮询效果：

```bash
for i in {1..6}; do curl -s http://192.168.88.102/index.php | grep 主机名; done
```

## 后端故障时的行为

停掉 node1 的 Nginx 后再请求，前几次仍然会有请求发往 node1（`max_fails=3` 还没攒够失败次数），之后该节点被标记为不可用，请求全部转到 node2。`fail_timeout` 到期后 Nginx 会重新尝试转发。

这是被动健康检查：靠真实请求的失败计数判断节点状态，不会主动探测。端口通但服务卡死的情况它检测不到。

## 会话保持

默认轮询会让同一用户的连续请求落到不同后端。如果需要会话保持，两种做法：

- 在 upstream 里加 `ip_hash`，按客户端 IP 哈希
- 用 `least_conn` 按连接数分发

如果后端没有做 Session 共享，更稳妥的方式是把 Session 外置到 Redis，让负载均衡层保持无状态。

## 请求头

代理时要把客户端信息传给后端，否则后端拿到的 Host 是 upstream 的名字，基于域名的判断会全部失效：

```nginx
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
```
