#!/bin/sh
set -e

# ==========================================
# mytv PHP 版一键部署脚本
# 支持系统：Debian / Ubuntu / Alpine Linux
#
# 可选环境变量：
#   MYTV_REF        拉取的文件版本（分支 / 标签 / commit），默认 main。
#                   建议固定到 tag 或 commit 以保证部署结果可复现，例如：
#                   MYTV_REF=v1.0.0 sh install.sh
#   SHA_NGINX_CONF  php-site.conf 的 sha256（可选，设置后强制校验）
#   SHA_MYTV_PHP    mytv.php 的 sha256（可选）
#   SHA_SUB_PHP     sub.php 的 sha256（可选）
# ==========================================

# ========== 基础检查 ==========
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请以 root 身份运行此脚本，例如: sudo sh install.sh"
  exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "❌ 无法识别操作系统，脚本终止。"
    exit 1
fi

echo "========================================="
echo "   🚀 开始安装 Nginx 和 PHP-FPM 环境"
echo "   💻 检测到系统: ${OS:-未知}"
echo "========================================="

# ========== 可配置项 ==========
MYTV_REF="${MYTV_REF:-main}"
REPO_RAW="https://raw.githubusercontent.com/HasonHuang/mytv/${MYTV_REF}"

NGINX_CONF_URL_DEBIAN="${REPO_RAW}/nginx/debian/php-site.conf"
NGINX_CONF_URL_ALPINE="${REPO_RAW}/nginx/alpine/php-site.conf"
MYTV_PHP_URL="${REPO_RAW}/php/mytv.php"
SUB_PHP_URL="${REPO_RAW}/php/sub.php"

# PHP-FPM 监听地址（含 PHP 版本号）由本脚本写入该文件，
# 站点配置只负责 include 它，因此下载下来的站点配置永远不需要被改写。
FPM_CONF="/etc/nginx/mytv-fpm.conf"

SHA_NGINX_CONF="${SHA_NGINX_CONF:-}"
SHA_MYTV_PHP="${SHA_MYTV_PHP:-}"
SHA_SUB_PHP="${SHA_SUB_PHP:-}"

WEB_DIR="/var/www/html"
PHP_VERSION=""

# ========== 通用函数 ==========

# 下载文件（带重试、非空校验、可选 sha256 校验），先写临时文件再原子替换
# fetch <url> <目标文件> <sha256|空> <php|conf>
fetch() {
    url=$1
    dest=$2
    want_sha=$3
    kind=$4

    # 中间文件写在与目标相同的目录（保证 mv 是原地重命名），但名字以 "." 开头：
    # 万一脚本被 Ctrl-C / kill 打断，也不会在网站根目录留下
    # mytv.php.tmp.<pid> 这种可被当作静态文件下载的残留。
    # 站点配置里另有隐藏文件拒绝规则兜底。
    tmp="$(dirname "$dest")/.$(basename "$dest").tmp.$$"
    FETCH_TMP="$tmp"
    trap 'rm -f "$FETCH_TMP"' EXIT
    trap 'rm -f "$FETCH_TMP"; exit 130' HUP INT TERM

    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 "$url" -o "$tmp"; then
        rm -f "$tmp"
        echo "❌ 下载失败: $url"
        echo "   请检查网络连通性，并确认 MYTV_REF='$MYTV_REF' 下该文件是否存在。"
        exit 1
    fi

    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo "❌ 下载内容为空: $url"
        exit 1
    fi

    # 粗略的内容校验：防止下载到错误页面 / 被劫持的内容
    if [ "$kind" = "php" ] && ! head -c 5 "$tmp" | grep -q '<?php'; then
        rm -f "$tmp"
        echo "❌ 下载到的内容不是 PHP 文件: $url"
        exit 1
    fi

    if [ -n "$want_sha" ]; then
        got=$(sha256sum "$tmp" | awk '{print $1}')
        if [ "$got" != "$want_sha" ]; then
            rm -f "$tmp"
            echo "❌ sha256 校验失败: $url"
            echo "   期望: $want_sha"
            echo "   实际: $got"
            exit 1
        fi
    fi

    mv -f "$tmp" "$dest"
}

# 找 php-fpm 可执行文件。两边的命名不一样：Debian/Ubuntu 是 /usr/sbin/php-fpm8.4，
# Alpine 是 /usr/sbin/php-fpm85（而且没有不带版本号的名字）。
find_php_fpm_bin() {
    for cand in \
        "/usr/sbin/php-fpm${PHP_VERSION}" \
        "/usr/sbin/php-fpm$(printf '%s' "$PHP_VERSION" | tr -d '.')" \
        /usr/sbin/php-fpm /usr/local/sbin/php-fpm /usr/bin/php-fpm \
        /usr/sbin/php-fpm[0-9]* /usr/local/sbin/php-fpm[0-9]* /usr/bin/php-fpm[0-9]*
    do
        if [ -x "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

# 没有 init 系统时的兜底（典型：容器）：直接把守护进程拉起来。
# 只处理本脚本会启动的 nginx 与 php-fpm，别的服务名一律失败，不猜。
start_daemon() {
    svc=$1
    echo "ℹ️ 未检测到 init 系统（容器环境），直接启动 $svc"
    case "$svc" in
        nginx)
            # pid 文件默认写在 /run/nginx/nginx.pid；正常安装里这个目录由 OpenRC 的
            # checkpath 建好，容器里没人建，缺了它 nginx 会直接起不来。
            mkdir -p /run/nginx
            # -g 'daemon on;'：镜像自带的 nginx.conf 常写着 daemon off;（官方 nginx
            # 镜像就是），那样直接跑会占住前台把脚本卡死。
            nginx -g 'daemon on;'
            ;;
        php-fpm|php-fpm[0-9]*|php[0-9]*-fpm)
            bin=$(find_php_fpm_bin || true)
            if [ -z "$bin" ]; then
                echo "❌ 找不到 php-fpm 可执行文件。"
                return 1
            fi
            # -D 强制退到后台，忽略配置文件里的 daemonize（发行版默认是 yes，
            # 但被改成 no 的话前台启动会把脚本卡住）
            "$bin" -D
            ;;
        *)
            return 1
            ;;
    esac
}

# 启动服务（并尽量设置开机自启），成功返回 0
start_service() {
    svc=$1

    # 1) systemd
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable --now "$svc"
        return $?
    fi

    # 2) OpenRC。判据是 /run/openrc/softlevel（OpenRC 真的 boot 过），而不是
    #    "rc-service 命令在不在"：容器里 rc-service 可能压根没装（Alpine 3.2x 起
    #    主包不再依赖 openrc），装了也可能因为 "openrc did not boot" 必然失败。
    #    另外得确认 init 脚本存在——同一轮拆包把 nginx 的服务脚本挪进了
    #    nginx-openrc 子包，主包里没有 /etc/init.d/nginx。
    if [ -e /run/openrc/softlevel ] && command -v rc-service >/dev/null 2>&1 \
       && [ -x "/etc/init.d/$svc" ]; then
        rc-update add "$svc" default >/dev/null 2>&1 || true
        rc-service "$svc" start
        return $?
    fi

    # 3) sysvinit 兼容层（Debian 的 /usr/sbin/service 包装 /etc/init.d/*）。
    #    失败不在这里判死：容器里 init.d 脚本会说 "openrc did not boot"，
    #    继续往下走直接拉进程才是可用的那条路。
    if command -v service >/dev/null 2>&1 && [ -x "/etc/init.d/$svc" ]; then
        service "$svc" start && return 0
    fi

    # 4) 没有可用的 init 系统 → 直接启动守护进程
    start_daemon "$svc"
}

# 重新加载 Nginx
reload_nginx() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl reload nginx
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service nginx reload 2>/dev/null || rc-service nginx restart
    elif command -v service >/dev/null 2>&1; then
        service nginx reload
    else
        nginx -s reload
    fi
}

# 探测已安装的 PHP 主次版本号（如 8.4），失败返回 1
detect_php_version() {
    # 1) Debian / Ubuntu：以「实际装了的 php*-fpm 包」为准。
    #    不能优先用 php CLI 的版本：本机可能早就装着 php8.2-cli（例如装过
    #    composer），而脚本刚装的是 php8.4-fpm，两者不一致时脚本会去启动一个
    #    根本不存在的 php8.2-fpm 服务然后中途失败；就算 8.2-fpm 恰好也在，
    #    站点也会被绑到旧版本的 socket 上。Alpine 没有 dpkg，会直接落到第 2 步。
    v=$(dpkg-query -W -f='${Package}\n' 'php*-fpm' 2>/dev/null \
        | sed -n 's/^php\([0-9][0-9.]*\)-fpm$/\1/p' \
        | sort -V | tail -n 1 || true)
    if [ -n "$v" ]; then
        printf '%s\n' "$v"
        return 0
    fi

    # 2) PHP CLI（Alpine 会安装 php CLI，其版本与 php-fpm 一致）
    v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    if [ -n "$v" ]; then
        printf '%s\n' "$v"
        return 0
    fi

    # 3) Alpine：从 /etc/php83 这类目录名推断（php83 -> 8.3，php810 -> 8.10）
    d=$(ls -d /etc/php[0-9]* 2>/dev/null | sort -V | tail -n 1 || true)
    if [ -n "$d" ]; then
        n=${d#/etc/php}
        printf '%s.%s\n' "$(printf '%s' "$n" | cut -c1)" "$(printf '%s' "$n" | cut -c2-)"
        return 0
    fi

    return 1
}

# 读取 php-fpm 池配置中的所有 listen 指令（每行一个，已排序去重）
read_pool_listens() {
    # shellcheck disable=SC2086  # 这里需要通配符展开
    files=$(ls $1 2>/dev/null | sort || true)
    if [ -z "$files" ]; then
        return 0
    fi
    # shellcheck disable=SC2086
    grep -hs '^[[:space:]]*listen[[:space:]]*=' $files 2>/dev/null \
        | sed 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//; s/;.*$//; s/[[:space:]]*$//' \
        | sort -u
}

# 校验监听目标是否真的可用，成功则输出 nginx 可用的 fastcgi_pass 目标
# 输入形如 /run/php/php8.4-fpm.sock 或 127.0.0.1:9000
verify_listen() {
    target=$1
    case "$target" in
        /*)
            if [ -S "$target" ]; then
                printf 'unix:%s\n' "$target"
                return 0
            fi
            ;;
        *:*)
            host=${target%:*}
            # 用 ## 贪婪匹配，兼容 [::]:9000 这类 IPv6 写法
            port=${target##*:}
            case "$host" in
                ""|"0.0.0.0"|"[::]"|"::"|"*") host="127.0.0.1" ;;
            esac
            if command -v ss >/dev/null 2>&1; then
                if ss -ltn 2>/dev/null | grep -q "[:.]${port}[[:space:]]"; then
                    printf '%s\n' "$host:$port"
                    return 0
                fi
            elif command -v netstat >/dev/null 2>&1; then
                if netstat -ltn 2>/dev/null | grep -q "[:.]${port}[[:space:]]"; then
                    printf '%s\n' "$host:$port"
                    return 0
                fi
            else
                # 无法校验端口占用情况，按配置直接采用
                printf '%s\n' "$host:$port"
                return 0
            fi
            ;;
    esac
    return 1
}

# 兜底：直接扫描系统中已存在的 php-fpm unix socket
find_fpm_sock() {
    php_ver=$1
    candidates=$(find /run /var/run -maxdepth 3 -name '*.sock' 2>/dev/null | grep -i php | sort -u || true)
    if [ -z "$candidates" ]; then
        return 1
    fi
    if [ -n "$php_ver" ]; then
        match=$(printf '%s\n' "$candidates" | grep -F "$php_ver" | head -n 1 || true)
        if [ -n "$match" ]; then
            printf '%s\n' "$match"
            return 0
        fi
    fi
    printf '%s\n' "$candidates" | head -n 1
}

# 解析 php-fpm 的实际监听地址，输出 nginx 的 fastcgi_pass 目标；失败返回 1
resolve_fastcgi_target() {
    php_ver=$1
    alt_ver=$(printf '%s' "$php_ver" | tr -d '.')

    # 1) 优先读取 php-fpm 池配置里的 listen（最准确，且同时覆盖 unix socket 与 TCP）；
    #    池目录中可能有多个池，取第一个当前真实可用的。
    for pool_glob in \
        "/etc/php/$php_ver/fpm/pool.d/*.conf" \
        "/etc/php${alt_ver}/php-fpm.d/*.conf" \
        "/etc/php*/php-fpm.d/*.conf" \
        "/etc/php/*/fpm/pool.d/*.conf"
    do
        listens=$(read_pool_listens "$pool_glob")
        for listen in $listens; do
            t=$(verify_listen "$listen" || true)
            if [ -n "$t" ]; then
                printf '%s\n' "$t"
                return 0
            fi
        done
    done

    # 2) 退而求其次：扫描实际存在的 unix socket
    sock=$(find_fpm_sock "$php_ver" || true)
    if [ -n "$sock" ]; then
        printf 'unix:%s\n' "$sock"
        return 0
    fi

    # 3) 最后兜底：常见的 TCP 监听
    t=$(verify_listen "127.0.0.1:9000" || true)
    if [ -n "$t" ]; then
        printf '%s\n' "$t"
        return 0
    fi

    return 1
}

# 探测 PHP-FPM 监听地址并写入独立的一行地址文件；站点配置只 include 该文件，
# 因此下载下来的 php-site.conf 永远不需要被改写。
write_fpm_address() {
    echo "🔍 正在探测 PHP-FPM 监听地址..."
    target=$(resolve_fastcgi_target "$PHP_VERSION" || true)
    if [ -z "$target" ]; then
        echo "❌ 无法确定 PHP-FPM 的监听地址，安装中止。"
        echo "   请手动确认 PHP-FPM 是否已启动，例如："
        echo "     ss -ltnp | grep 9000"
        echo "     ls -l /run/php/*.sock /run/*.sock 2>/dev/null"
        exit 1
    fi

    mkdir -p "$(dirname "$FPM_CONF")"
    printf 'fastcgi_pass %s;\n' "$target" > "$FPM_CONF"
    echo "✅ 已写入 $FPM_CONF -> fastcgi_pass $target"
}

# 下载站点配置、写入 PHP-FPM 地址文件、校验配置；校验失败则回滚并退出
# install_site_conf <配置 URL> <目标目录>
install_site_conf() {
    conf_url=$1
    conf_dir=$2
    conf_file="$conf_dir/php-site.conf"
    stamp=$(date +%Y%m%d%H%M%S)

    mkdir -p "$conf_dir"

    if [ -f "$conf_file" ]; then
        cp "$conf_file" "$conf_file.bak.$stamp"
        echo "ℹ️ 已备份原有配置到 $conf_file.bak.$stamp"
    fi

    # 顺序很重要：先探测地址、写好 mytv-fpm.conf，再覆盖站点配置。
    # 这两步中任何一步失败都会 exit，而此时旧的 php-site.conf 还完好无损；
    # 反过来（先覆盖站点配置）一旦探测失败就直接退出，下面的回滚分支永远
    # 执行不到，磁盘上会留下一个 include 了不存在文件的 php-site.conf ——
    # 此后 nginx -t / reload 全部失败，重启后 nginx 直接起不来，
    # 同机 conf.d 里其它站点会一起下线。
    write_fpm_address

    fetch "$conf_url" "$conf_file" "$SHA_NGINX_CONF" conf

    if ! nginx -t; then
        if [ -f "$conf_file.bak.$stamp" ]; then
            cp "$conf_file.bak.$stamp" "$conf_file"
            echo "↩️ Nginx 配置校验失败，已回滚到原有配置。"
        else
            rm -f "$conf_file"
            echo "↩️ Nginx 配置校验失败，已移除新写入的配置。"
        fi
        exit 1
    fi
    echo "✅ Nginx 配置校验通过"
}

# 部署 PHP 文件并做端到端自检
# setup_site <配置 URL> <目标目录> <网站属主>
setup_site() {
    conf_url=$1
    conf_dir=$2
    web_owner=$3

    echo "[3/5] 配置 Nginx 站点..."
    install_site_conf "$conf_url" "$conf_dir"
    reload_nginx

    echo "[4/5] 部署 PHP 文件到 $WEB_DIR ..."
    mkdir -p "$WEB_DIR"
    # 清理历史遗留的下载中间文件（旧版本把它们写在网站根目录且不带前导点，
    # 会被 nginx 当作静态文件公开，这里顺手擦掉）
    rm -f "$WEB_DIR"/.mytv.php.tmp.* "$WEB_DIR"/.sub.php.tmp.* \
          "$WEB_DIR"/mytv.php.tmp.* "$WEB_DIR"/sub.php.tmp.* 2>/dev/null || true
    fetch "$MYTV_PHP_URL" "$WEB_DIR/mytv.php" "$SHA_MYTV_PHP" php
    fetch "$SUB_PHP_URL" "$WEB_DIR/sub.php" "$SHA_SUB_PHP" php
    # nginx 与 php-fpm 只需要读取权限，因此只授权这两个文件，
    # 避免影响该目录下其它站点已有的属主与权限。
    chmod 644 "$WEB_DIR/mytv.php" "$WEB_DIR/sub.php"
    chown "$web_owner:$web_owner" "$WEB_DIR/mytv.php" "$WEB_DIR/sub.php"

    echo "[5/5] 站点自检..."
    verify_site
}

# 通过本机请求确认站点真的可用，避免"脚本报成功、实际 502"
verify_site() {
    curl_code() {
        curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1/mytv.php" || true
    }

    # nginx reload 是异步的：信号发出后，旧 worker 仍会用**部署前**的配置应答，
    # 直到新 worker 接管。窗口不长（实测不到 1s，但容器上足够快过本函数），
    # 表现就是站点配置明明刚上线，/mytv.php 却回 404（旧配置里没有这个站点），
    # 或 000（reload 期间没有任何 worker 在听）。把这两种都当作"还没就绪"重试，
    # 其余状态码是确定结论，直接判定。
    code=$(curl_code)
    retry=0
    while [ "$retry" -lt 10 ]; do
        case "$code" in
            404|000|"") retry=$((retry + 1)); sleep 1; code=$(curl_code) ;;
            *) break ;;
        esac
    done

    case "$code" in
        200)
            echo "✅ 站点自检通过 (HTTP 200)"
            ;;
        502|504)
            echo "❌ 站点返回 HTTP $code：Nginx 无法连接 PHP-FPM。"
            echo "   请对比配置中的 fastcgi_pass 与 'ss -ltnp | grep -E \"sock|9000\"' 的实际监听地址。"
            exit 1
            ;;
        403|404)
            echo "❌ 站点返回 HTTP $code：/mytv.php 不可访问。"
            echo "   请检查 $WEB_DIR/mytv.php 是否存在，以及 nginx 配置中的 root 是否一致。"
            exit 1
            ;;
        000|"")
            echo "❌ 无法访问 http://127.0.0.1/mytv.php（已重试 ${retry} 次）。"
            echo "   请检查 80 端口是否被占用（ss -ltnp | grep :80）、防火墙是否放行 80 端口。"
            if [ "$OS" = "alpine" ]; then
                echo "   若你用过仓库里的 nginx/alpine/nginx.conf，请确认 /etc/nginx/nginx.conf 中"
                echo "     include /etc/nginx/http.d/*.conf;"
                echo "   这行没有被注释掉——仓库那份默认是注释状态，取消注释后 http.d 下的"
                echo "   站点配置才会被加载（否则 nginx -t 通过但 80 端口无人监听）。"
            fi
            exit 1
            ;;
        *)
            echo "⚠️ 站点返回 HTTP $code，请手动访问 http://<服务器IP>/mytv.php 确认。"
            ;;
    esac
}

# 读取物理内存总量（MB）；读不到则输出空
detect_mem_mb() {
    [ -r /proc/meminfo ] || return 1
    awk '/^MemTotal:/ { printf "%d\n", $2 / 1024; exit }' /proc/meminfo 2>/dev/null
}

# 高配机器提示：站点配置的出厂值按 64/128MB 小内存机定值（超时 60s、
# memory_limit 64M），内存充裕的机器反而需要放宽，否则并发数和单个分片的
# 大小上限都会被按住。这里只打印可直接执行的命令，不擅自改系统配置。
advise_high_mem() {
    mem_mb=$(detect_mem_mb || true)
    case "$mem_mb" in
        ''|*[!0-9]*) return 0 ;;
    esac
    # 1GB 以下沿用低配出厂值，不打扰用户
    [ "$mem_mb" -ge 1024 ] || return 0

    if [ "$mem_mb" -ge 4096 ]; then
        children=20
        mem_limit=256M
    else
        children=8
        mem_limit=128M
    fi

    if [ "$OS" = "alpine" ]; then
        pool_dir="/etc/php$(printf '%s' "$PHP_VERSION" | tr -d '.')/php-fpm.d"
        site_conf="/etc/nginx/http.d/php-site.conf"
        fpm_restart="rc-service ${PHP_FPM_SVC:-php-fpm} restart"
        nginx_reload="rc-service nginx reload"
    else
        pool_dir="/etc/php/${PHP_VERSION}/fpm/pool.d"
        site_conf="/etc/nginx/conf.d/php-site.conf"
        fpm_restart="systemctl restart php${PHP_VERSION}-fpm"
        nginx_reload="systemctl reload nginx"
    fi

    echo
    echo "ℹ️ 检测到物理内存 ${mem_mb}MB：站点配置是按需 64/128MB 小内存机定的"
    echo "   （超时 60s、单请求 memory_limit 64M），你这台可以放宽。"
    echo
    echo "   下面两段已按本机填好路径，各自整段复制执行即可；不动也能用，"
    echo "   只是并发数和分片大小上限受限："
    echo
    echo "   ① 放宽 PHP-FPM（$children 个 worker，每个最多 $mem_limit）："
    echo
    printf '%s\n' \
"cat > $pool_dir/zz-mytv.conf <<'EOF'" \
"[www]" \
"pm.max_children = $children" \
"pm.max_requests = 500" \
"php_admin_value[memory_limit] = $mem_limit" \
"EOF" \
"$fpm_restart"
    echo
    echo "   ② 放宽 nginx 超时（分片要整段下完才吐第一个字节，慢源站需要更宽松）："
    echo
    printf '%s\n' \
"sed -i -E 's/^([[:space:]]*(fastcgi_read_timeout|fastcgi_send_timeout|send_timeout))[[:space:]]+60s;/\1 120s;/' $site_conf" \
"nginx -t && $nginx_reload"
    echo
    echo "   说明：①里的 php_admin_value 优先级高于站点配置里的 PHP_ADMIN_VALUE，"
    echo "   两处 memory_limit 以池配置为准；②若你用的是 php-site-manual.conf 或"
    echo "   改过站点配置路径，请把文件名换成实际路径。"
}

# ==========================================
# Debian / Ubuntu 安装逻辑
# ==========================================
install_debian() {
    export DEBIAN_FRONTEND=noninteractive

    echo "[1/5] 安装 Nginx 和 基础工具..."
    apt-get update
    apt-get install -y nginx curl

    echo "[2/5] 安装 PHP 和 PHP-FPM..."
    if ! apt-get install -y php8.4-fpm php8.4-curl; then
        echo "⚠️ 未找到 php8.4，尝试安装系统默认版本的 php-fpm..."
        apt-get install -y php-fpm php-curl
    fi

    PHP_VERSION=$(detect_php_version || true)
    if [ -z "$PHP_VERSION" ]; then
        echo "❌ 未能识别已安装的 PHP 版本，请确认 php-fpm 是否安装成功。"
        exit 1
    fi
    echo "ℹ️ 检测到 PHP 版本: $PHP_VERSION"

    if ! start_service "php${PHP_VERSION}-fpm"; then
        echo "❌ 启动 php${PHP_VERSION}-fpm 失败，请执行 'systemctl status php${PHP_VERSION}-fpm' 查看原因。"
        exit 1
    fi

    if ! start_service nginx; then
        echo "❌ 启动 Nginx 失败，请检查 80 端口是否被其它服务占用（ss -ltnp | grep :80）。"
        exit 1
    fi

    # 该文件是指向 sites-available/default 的软链接，删除后如需恢复可重新 ln -s
    rm -f /etc/nginx/sites-enabled/default

    setup_site "$NGINX_CONF_URL_DEBIAN" "/etc/nginx/conf.d" "www-data"
}

# ==========================================
# Alpine Linux 安装逻辑
# ==========================================
install_alpine() {
    echo "[1/5] 安装 Nginx, PHP 和 基础工具..."
    apk update
    apk add --no-cache nginx php php-fpm php-curl curl
    # Alpine 3.2x 起 nginx 的 OpenRC 服务脚本被拆进 nginx-openrc 子包，主包不再包含，
    # 于是 `rc-service nginx start` 会报 "service does not exist"。只有真的有 OpenRC
    # 在跑（不是容器）时才需要它；老版本 Alpine 里该包不存在，装不上也无妨——
    # 下面的 start_service 会退到直接启动。
    if [ -e /run/openrc/softlevel ]; then
        apk add --no-cache nginx-openrc 2>/dev/null || true
    fi

    echo "[2/5] 启动 Nginx 和 PHP-FPM..."
    if ! start_service nginx; then
        echo "❌ 启动 Nginx 失败。常见原因："
        echo "   · 80 端口被其它服务占用：ss -ltnp | grep :80"
        echo "   · 配置有误：nginx -t 看报错（上面通常已有输出）"
        exit 1
    fi
    # Alpine 默认站点使用 /var/www/localhost/htdocs，且会以 default_server 抢占 80 端口
    rm -f /etc/nginx/http.d/default.conf

    PHP_VERSION=$(detect_php_version || true)
    if [ -z "$PHP_VERSION" ]; then
        echo "❌ 未能识别已安装的 PHP 版本，请确认 php-fpm 是否安装成功。"
        exit 1
    fi
    echo "ℹ️ 检测到 PHP 版本: $PHP_VERSION"

    # 动态获取 Alpine 下的 php-fpm 服务名（可能是 php-fpm 或 php-fpm83 等）
    PHP_FPM_SVC=$(ls /etc/init.d/php-fpm* 2>/dev/null | head -n 1 | awk -F'/' '{print $NF}' || true)
    if [ -z "$PHP_FPM_SVC" ]; then PHP_FPM_SVC="php-fpm"; fi

    if ! start_service "$PHP_FPM_SVC"; then
        echo "❌ 启动 $PHP_FPM_SVC 失败。"
        echo "   有 init 系统：rc-service $PHP_FPM_SVC status"
        echo "   容器里没有 rc-service：前台跑一次 php-fpm 看报错（如 /usr/sbin/php-fpm85 -F）"
        exit 1
    fi

    # Alpine 的 nginx 站点配置目录是 /etc/nginx/http.d
    setup_site "$NGINX_CONF_URL_ALPINE" "/etc/nginx/http.d" "nginx"
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
        echo "❌ 暂不支持的操作系统: ${OS:-未知}"
        echo "目前仅支持 Debian, Ubuntu 和 Alpine Linux。"
        exit 1
        ;;
esac

echo "========================================="
echo "   🎉 安装完成！"
echo "========================================="
echo "👉 请访问 http://<你的服务器IP>/mytv.php 进行测试。"
echo "📁 网站根目录: $WEB_DIR"
# 容器里没有 init 系统，服务是本脚本直接拉起来的：容器重启后不会自己回来
if [ ! -d /run/systemd/system ] && [ ! -e /run/openrc/softlevel ]; then
    echo "⚠️ 当前环境没有 init 系统（容器）：nginx 与 php-fpm 已由本脚本直接启动，"
    echo "   容器重启后不会自动恢复，重新跑一遍本脚本即可（它是幂等的）。"
fi
advise_high_mem
if command -v ufw >/dev/null 2>&1; then
    echo "💡 若外部无法访问，请放行端口: ufw allow 80/tcp"
elif command -v firewall-cmd >/dev/null 2>&1; then
    echo "💡 若外部无法访问，请放行端口: firewall-cmd --add-service=http --permanent && firewall-cmd --reload"
fi
echo "⚠️ 注意：mytv.php 可代理任意 url 参数，默认对访问者完全开放（存在被当作开放代理/SSRF 利用的风险）。"
echo "   若服务器暴露在公网，建议在 php-site.conf 的 php 解析块中启用 allow/deny 访问控制。"
