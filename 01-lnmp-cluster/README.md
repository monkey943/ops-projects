# LNMP 环境与备份

在 node1、node2 上部署 Nginx + PHP-FPM，并提供一个网站与数据库的备份脚本。

## 文件

- `nginx-config/blog.conf`：Nginx 虚拟主机配置
- `scripts/backup.sh`：数据库与网站文件备份脚本

## 部署要点

Rocky 9 的 AppStream 自带 Nginx 和 PHP，不需要额外装 EPEL：

```bash
dnf -y install nginx php php-fpm php-mysqlnd php-gd php-xml php-mbstring
systemctl enable --now nginx php-fpm
```

PHP-FPM 要把运行用户改成 nginx。默认配置里写的是 apache，而系统里没有这个用户，不改会导致 502：

```bash
sed -i 's/^user = .*/user = nginx/'   /etc/php-fpm.d/www.conf
sed -i 's/^group = .*/group = nginx/' /etc/php-fpm.d/www.conf
sed -i 's|^listen = .*|listen = 127.0.0.1:9000|' /etc/php-fpm.d/www.conf
systemctl restart php-fpm
```

部署虚拟主机配置后先检查语法再重载，不要直接 restart：

```bash
cp nginx-config/blog.conf /etc/nginx/conf.d/
nginx -t && systemctl reload nginx
```

放行 HTTP：

```bash
firewall-cmd --permanent --add-service=http && firewall-cmd --reload
```

## 备份脚本

`backup.sh` 的参数都通过环境变量传入，可以用默认值也可以覆盖：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DB_NAME` | blog | 数据库名 |
| `DB_USER` / `DB_PASS` | root / 空 | 数据库账号 |
| `DB_HOST` | localhost | 数据库地址 |
| `BACKUP_DIR` | /backup/www | 备份存放目录 |
| `RETENTION` | 7 | 备份保留天数 |

```bash
DB_NAME=blog /opt/ops/scripts/backup.sh
```

加 crontab 之前先手动执行一次，确认没有报错。定时任务里的失败默认看不到，脚本会把结果写进日志文件。

## 常见故障

- **502 Bad Gateway**：PHP-FPM 没启动，或者 `www.conf` 里的 `listen` 与 Nginx 配置里 `fastcgi_pass` 的地址不一致
- **403 Forbidden**：目录属主不对，或者 SELinux 上下文不对。用 `restorecon -Rv /var/www/html` 恢复上下文
- **404 Not Found**：`root` 指向的目录里没有对应文件
