### 欢迎加入直播源等影视资源分享交流群:https://t.me/tvzby

#
## Nginx反代教程
1.以Debian/Ubuntu系统举例，安装nginx:
```
sudo apt update
sudo apt install nginx
```
2.替换/etc/nginx/nginx.conf:
```
curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/nginx/nginx.conf -o /etc/nginx/nginx.conf
```
如需自定义token，请把nginx.conf第69行的"mytv123"修改为你自己的token。

3.重启Nginx:
```
sudo systemctl restart nginx
```
4.订阅链接(mytv.m3u)：
```
http://服务器ip:30000/mytv.m3u?token=mytv123
```
5.stream-link订阅链接:
```
http://服务器ip:30001/playlist.m3u?token=你的token
```

## Alpine系统Nginx反代教程
1.安装Nginx:
```
apk update
apk add nginx
service nginx start
rc-update add nginx boot
```
2.替换/etc/nginx/nginx.conf:
```
curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/nginx/alpine/nginx.conf -o /etc/nginx/nginx.conf
```
3.重启Nginx:
```
service nginx restart
```
4.订阅链接(mytv.m3u)：
```
http://服务器ip:30000/mytv.m3u?token=mytv123
```
5.stream-link订阅链接:
```
http://服务器ip:30001/playlist.m3u?token=你的token
```

## 无token版nginx.conf
除非你有特殊需求，否则不推荐使用,支持Ubuntu/Debian系统:
https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/nginx/notoken/nginx.conf

## docker部署教程
1.下载alpine系统版的nginx.conf到指定目录(默认为/root/mytv):
```
mkdir -p /root/mytv && curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/nginx/alpine/nginx.conf -o /root/mytv/nginx.conf
```
2.一键部署命令：
```
docker run --name="mytv" --restart=always --net=host -d --mount type=bind,source=/root/mytv/nginx.conf,target=/etc/nginx/nginx.conf --log-opt max-size=10m --log-opt max-file=3 nginx:alpine3.22-slim
```
3.后续如果需要更新，可使用一键更新命令：
```
curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/nginx/alpine/nginx.conf -o /root/mytv/nginx.conf && docker restart mytv
```
4.订阅链接(mytv.m3u)：
```
http://服务器ip:30000/mytv.m3u?token=mytv123
```
5.stream-link订阅链接:
```
http://服务器ip:30001/playlist.m3u?token=你的token
```

## PHP部署方案：

### 方式一：一键部署脚本（推荐）

支持 Debian / Ubuntu / Alpine Linux，自动完成 Nginx + PHP-FPM 安装、站点配置、文件部署与自检：

```
curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/php/install.sh -o install.sh && sh install.sh
```

可选环境变量：

| 变量 | 说明 |
| --- | --- |
| `MYTV_REF` | 拉取的文件版本（分支/标签/commit），默认 `main`。建议固定到 tag 或 commit 以保证可复现，例如 `MYTV_REF=v1.0.0 sh install.sh` |
| `SHA_NGINX_CONF` / `SHA_MYTV_PHP` / `SHA_SUB_PHP` | 对应文件的 sha256，设置后强制校验，例如 `SHA_MYTV_PHP=<sha256> sh install.sh` |

脚本会按系统下载对应的站点配置（Debian/Ubuntu 用 `nginx/debian/php-site.conf`，Alpine 用 `nginx/alpine/php-site.conf`），并部署为 `/etc/nginx/conf.d/php-site.conf`（Alpine 为 `/etc/nginx/http.d/php-site.conf`）；原有同名文件会备份为 `.bak.<时间戳>`，配置校验失败时自动回滚并中止。

站点配置里不含 PHP-FPM 监听地址（该地址随 PHP 版本变化，如 `/run/php/php8.4-fpm.sock`），脚本会探测本机实际地址后写入 `/etc/nginx/mytv-fpm.conf`，站点配置只 `include` 它，因此下载下来的配置永远不需要被改写。

脚本还会自动移除发行版自带的默认站点（`/etc/nginx/sites-enabled/default`、`/etc/nginx/http.d/default.conf`），避免它与本站点抢占 80 端口导致访问到 nginx 欢迎页。

### 方式二：手动部署

1. 将 mytv.php 上传到网站目录  
   PHP文件链接：https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/php/mytv.php  

2. 下载对应系统的站点配置：
   - Debian / Ubuntu：https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/nginx/debian/php-site.conf
   - Alpine：https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/nginx/alpine/php-site.conf

3. **移除发行版自带的默认站点**。它带有 `default_server` 且根目录同为 `/var/www/html`，不删掉的话用 IP 访问会落到它上面：`/mytv.php` 会被当作静态文件直接下载（源码泄露），首页则显示 nginx 欢迎页。

   ```
   rm -f /etc/nginx/sites-enabled/default      # Debian / Ubuntu
   rm -f /etc/nginx/http.d/default.conf        # Alpine
   ```

   Alpine 还要确认 `/etc/nginx/nginx.conf` 里有 `include /etc/nginx/http.d/*.conf;`：
   仓库里的 `nginx/alpine/nginx.conf`（反代用的那份）默认把这行注释掉了，用它替换
   nginx.conf 之后站点配置不会被加载——`nginx -t` 照样通过，80 端口却没有任何响应。

4. 创建 PHP-FPM 监听地址文件（实际地址可用 `ls /run/php/*.sock` 或 `ss -ltnp | grep 9000` 查看）：

   ```
   echo 'fastcgi_pass unix:/run/php/php8.4-fpm.sock;' > /etc/nginx/mytv-fpm.conf
   ```

   也可以不用该文件，直接把站点配置里的 `include /etc/nginx/mytv-fpm.conf;` 换成你自己的 `fastcgi_pass` 一行；或者改用内联好 `fastcgi_pass` 的手动部署版：https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/nginx/debian/php-site-manual.conf （用它可跳过本步，但需自行把里面的 `php8.4-fpm.sock` 改成实际文件名）。

5. 校验并重载：`nginx -t && nginx -s reload`

6. 已支持获取订阅功能，访问：  
   `mytv.php?p=m3u`  

7. 也可代理任何其他 hls/m3u8 直播源：  
   `mytv.php?url=http://xxxx.com/hls/xxx.m3u8`

### 小内存机器（64MB / 128MB）

PHP 版的瓶颈不在 nginx，而在 PHP：`mytv.php` 会把整个 `.ts` 分片读进内存
（`CURLOPT_RETURNTRANSFER`），而 Debian / Alpine 的 `php.ini` 默认
`memory_limit = 128M`、php-fpm 默认 `pm.max_children = 5`。64MB 机器上「单请求
内存上限」比物理内存还大，128MB 机器则允许 5 个请求各自吃到 128M——几个并发
播放就会被 OOM killer 杀掉 php-fpm 子进程，表现为整站 502。

一键脚本检测到内存小于 512MB 时会直接打印按本机填好的收紧命令；手动部署请自行
写入池配置（注意先按 `ls /etc/php/` 确认版本号）：

```
cat > /etc/php/8.4/fpm/pool.d/zz-mytv.conf <<'EOF'
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 30s
pm.max_requests = 200
php_admin_value[memory_limit] = 64M
EOF
systemctl restart php8.4-fpm
```

Alpine 的池目录是 `/etc/php83/php-fpm.d/`，重启用 `rc-service php-fpm83 restart`。

- **64MB**：只适合自用，并发基本串行，把 `pm.max_children` 设为 `1`、
  `memory_limit` 设为 `32M`。
- **128MB**：`pm.max_children = 2`、`memory_limit = 64M` 可用。
- **256MB 以上**：不用改。

`pm = ondemand` 很关键：默认的 `pm = dynamic` 会常驻几个空闲进程，低配机空闲时
也白占几十 MB。

反过来，站点配置里的 `fastcgi_read_timeout` / `send_timeout` 在低配机上应该**调小**
而不是调大：超时决定「一个 worker 被占用多久」，而 `pm.max_children` 只有 1~2 时，
上游卡住 120s 就等于整站 2 分钟不可用。

> 文档开头的 Nginx 反代方案（含 Alpine、无 token、docker 三种）都不经过 PHP，
> 不受这一节影响。

> ⚠️ 注意：`mytv.php?url=` 可代理任意地址，默认对访问者完全开放（存在被当作开放代理/SSRF 利用的风险）。若服务器暴露在公网，建议在 php-site.conf 的 PHP 解析块中启用 `allow` / `deny` 访问控制。


### 更多直播源分享，欢迎加入直播源等影视资源分享交流群:https://t.me/tvzby





