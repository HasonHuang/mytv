#!/bin/sh
set -e

# 检查是否以 root 身份运行
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请以 root 身份运行此脚本，例如: sudo sh install.sh"
  exit 1
fi

# 获取操作系统信息
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别操作系统，脚本终止。"
    exit 1
fi

echo "========================================="
echo "   🚀 开始安装 Nginx 和 PHP-FPM 环境"
echo "   💻 检测到系统: $OS"
echo "========================================="

# 定义远程文件 URL
NGINX_CONF_URL="https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/php/nginx/php-site.conf"
MYTV_PHP_URL="https://raw.githubusercontent.com/rad168/mytv/refs/heads/main/php/mytv.php"
SUB_PHP_URL="https://raw.githubusercontent.com/HasonHuang/mytv/refs/heads/main/php/sub.php"
WEB_DIR="/var/www/html"

# 通用函数：自动探测 PHP-FPM Socket 并修正 Nginx 配置
fix_nginx_socket() {
    CONF_FILE=$1
    echo "🔍 正在探测 PHP-FPM Socket 路径..."
    # 在 /run 和 /var/run 下寻找 php 相关的 sock 文件
    SOCK_PATH=$(find /run /var/run -name "*.sock" 2>/dev/null | grep -i php | head -n 1)
    
    if [ -n "$SOCK_PATH" ] && [ -f "$CONF_FILE" ]; then
        echo "✅ 发现 Socket: $SOCK_PATH"
        # 转义路径中的斜杠以便 sed 使用
        ESCAPED_SOCK=$(echo "$SOCK_PATH" | sed 's/\//\\\//g')
        # 替换配置文件中的 fastcgi_pass 行
        sed -i "s/fastcgi_pass.*/fastcgi_pass unix:$ESCAPED_SOCK;/" "$CONF_FILE"
        echo "🛠️ 已自动更新 Nginx 配置中的 fastcgi_pass 路径。"
    else
        echo "⚠️ 未自动探测到 PHP-FPM Socket，请手动检查 Nginx 配置中的 fastcgi_pass 设置。"
    fi
}

# ==========================================
# Debian / Ubuntu 安装逻辑
# ==========================================
install_debian() {
    export DEBIAN_FRONTEND=noninteractive
    
    echo "[1/4] 安装 Nginx 和 基础工具..."
    apt-get update
    apt-get install -y nginx curl

    echo "[2/4] 安装 PHP 和 PHP-FPM..."
    if ! apt-get install -y php8.4-fpm php8.4-curl; then
        echo "⚠️ 未找到 php8.4，尝试安装系统默认版本的 php-fpm..."
        apt-get install -y php-fpm php-curl
    fi

    systemctl enable --now nginx
    rm -f /etc/nginx/sites-enabled/default

    # 获取 PHP 版本以启动对应服务
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || echo "")
    if [ -z "$PHP_VERSION" ]; then
        PHP_VERSION=$(dpkg -l 2>/dev/null | grep "php[0-9.]*-fpm" | awk '{print $2}' | head -n 1 | sed 's/^php//;s/-fpm$//')
    fi
    [ -z "$PHP_VERSION" ] && PHP_VERSION="8.4" # 兜底

    systemctl enable --now "php${PHP_VERSION}-fpm"

    echo "[3/4] 配置 Nginx 站点..."
    mkdir -p /etc/nginx/conf.d
    curl -fsSL "$NGINX_CONF_URL" -o /etc/nginx/conf.d/php-site.conf
    
    # 修正 Socket 路径
    fix_nginx_socket "/etc/nginx/conf.d/php-site.conf"

    nginx -t && systemctl reload nginx

    echo "[4/4] 部署 PHP 文件..."
    mkdir -p "$WEB_DIR"
    curl -fsSL "$MYTV_PHP_URL" -o "$WEB_DIR/mytv.php"
    curl -fsSL "$SUB_PHP_URL" -o "$WEB_DIR/sub.php"
    chown -R www-data:www-data "$WEB_DIR"
}

# ==========================================
# Alpine Linux 安装逻辑
# ==========================================
install_alpine() {
    echo "[1/4] 安装 Nginx, PHP 和 基础工具..."
    apk update
    apk add --no-cache nginx php php-fpm php-curl curl

    # 启动 Nginx
    rc-update add nginx default >/dev/null 2>&1
    rc-service nginx start
    # 删除 Alpine 默认的 default 站点
    rm -f /etc/nginx/http.d/default.conf

    echo "[2/4] 启动 PHP-FPM..."
    # 动态获取 Alpine 下的 php-fpm 服务名 (可能是 php-fpm 或 php-fpm83 等)
    PHP_FPM_SVC=$(ls /etc/init.d/php-fpm* 2>/dev/null | head -n 1 | awk -F'/' '{print $NF}')
    if [ -z "$PHP_FPM_SVC" ]; then PHP_FPM_SVC="php-fpm"; fi

    rc-update add "$PHP_FPM_SVC" default >/dev/null 2>&1
    rc-service "$PHP_FPM_SVC" start

    echo "[3/4] 配置 Nginx 站点..."
    # Alpine 默认 include 的是 /etc/nginx/http.d/ 目录
    curl -fsSL "$NGINX_CONF_URL" -o /etc/nginx/http.d/php-site.conf
    
    # 修正 Socket 路径 (Alpine 的 socket 路径与 Debian 不同，这一步至关重要)
    fix_nginx_socket "/etc/nginx/http.d/php-site.conf"

    nginx -t && nginx -s reload

    echo "[4/4] 部署 PHP 文件..."
    mkdir -p "$WEB_DIR"
    curl -fsSL "$MYTV_PHP_URL" -o "$WEB_DIR/mytv.php"
    curl -fsSL "$SUB_PHP_URL" -o "$WEB_DIR/sub.php"
    # Alpine 的 nginx 默认用户通常是 nginx
    chown -R nginx:nginx "$WEB_DIR"
}

# ==========================================
# 主程序分发
# ==========================================
case "$OS" in
    debian|ubuntu)
        install_debian
        ;;
    alpine)
        install_alpine
        ;;
    *)
        echo "❌ 暂不支持的操作系统: $OS"
        echo "目前仅支持 Debian, Ubuntu 和 Alpine Linux。"
        exit 1
        ;;
esac

echo "========================================="
echo "   🎉 安装完成！"
echo "========================================="
echo "👉 请访问 http://<你的服务器IP>/mytv.php 进行测试。"
echo "📁 网站根目录: $WEB_DIR"
