#!/bin/sh
set -e

# ==========================================
# mytv token 版一键部署脚本
# 支持系统：Debian / Ubuntu / Alpine Linux
#
# 它做两件事：
#   阶段 1：委托主安装器 php/install.sh，装好 nginx + php-fpm + 站点（幂等）
#   阶段 2：把站点换成 token 版——部署 token/mytv.php、删掉无认证的 sub.php、
#           生成 /etc/mytv/tokens.php（稳定 token 数组），并做 token 感知自检
#
# 可选环境变量：
#   MYTV_REF        首选的文件版本（分支 / 标签 / commit），默认 main。
#                   脚本会按「$MYTV_REF → main → token」探测哪个 ref 下真的有
#                   token/mytv.php，用第一个命中的，因此：
#                     · 合并进 main 之前：自动落到 token 分支
#                     · 合并进 main 之后（哪怕 token 分支已删除）：直接用 main
#                     · 固定到 tag / commit：命中即用，保证部署可复现
#                   想锁定某个版本就设成 tag 或 commit。
#   MYTV_SKIP_BASE  设为 1 时跳过阶段 1（基础环境已由主脚本装好的机器）
#   MYTV_TOKEN      设为 0 时只做阶段 1（等价主脚本，站点无认证）。
#                   这是 token/mytv.php 拉不到时的应急退路。
#   SHA_MYTV_PHP    token/mytv.php 的 sha256（可选，设置后强制校验）。
#                   注意：token 版部署的文件与仓库文件逐字节一致，所以这个
#                   校验覆盖的是最终产物（主安装器那边因为配置写进源码而做不到）。
#
# 回退到无认证版：跑主安装器，它会覆盖回原版并恢复 sub.php
#   curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/main/php/install.sh | sh
#   （/etc/mytv/tokens.php 留着无害，回退后没人再读它）
#   （/etc/mytv/tokens.php 留着无害，不会再被读取）
#
# 设计文档：docs/plans/01-auth-token.md
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

case "$OS" in
    debian|ubuntu|alpine) ;;
    *)
        echo "❌ 暂不支持的操作系统: ${OS:-未知}"
        echo "目前仅支持 Debian, Ubuntu 和 Alpine Linux。"
        exit 1
        ;;
esac

# ========== 可配置项 ==========
# MYTV_REF 只是「首选 ref」，最终用哪个由下面的 resolve_ref() 探测决定。
# 默认值不写死分支名：写死的话，token 分支合并进 main（并删除）之后，
# 这个脚本的第一步就会 404 —— 而不是"自动跟着 main 走"。
MYTV_REF="${MYTV_REF:-main}"
MYTV_REF_CANDIDATES="$MYTV_REF main token"
GITHUB_RAW="https://raw.githubusercontent.com/HasonHuang/mytv"

MYTV_SKIP_BASE="${MYTV_SKIP_BASE:-}"
MYTV_TOKEN="${MYTV_TOKEN:-1}"
SHA_MYTV_PHP="${SHA_MYTV_PHP:-}"

WEB_DIR="/var/www/html"
TOKENS_DIR="/etc/mytv"
TOKENS_FILE="$TOKENS_DIR/tokens.php"
if [ "$OS" = "alpine" ]; then
    SITE_CONF="/etc/nginx/http.d/php-site.conf"
else
    SITE_CONF="/etc/nginx/conf.d/php-site.conf"
fi
PHP_GROUP=""
NEW_TOKEN=""

echo "========================================="
echo "   🔐 mytv token 版安装"
echo "   💻 检测到系统: ${OS}"
echo "   🏷️  首选版本: ${MYTV_REF}"
echo "========================================="

# 探测哪个 ref 下真的有 token/mytv.php，输出第一个命中的 ref 名。
# 顺序：首选 ref → main → token。404 就试下一个；网络类失败也落到下一个，
# 全部失败才返回非零，由调用方报错（报错信息里会列出试过哪些 ref）。
resolve_ref() {
    for ref in $MYTV_REF_CANDIDATES; do
        # 2>/dev/null：候选 ref 未命中时 curl 会往 stderr 吐一行 (22) 404，
        # 那是预期内的探测过程，不该吓到用户
        if curl -fsS --connect-timeout 10 --max-time 60 -o /dev/null \
                "$GITHUB_RAW/$ref/token/mytv.php" 2>/dev/null; then
            printf '%s' "$ref"
            return 0
        fi
    done
    return 1
}

# 解析实际使用的 ref。必须在阶段 1 之前完成：阶段 1 委托的主安装器
# （php/install.sh）也要从同一个 ref 拉文件，两个阶段不能各拉各的。
if ! command -v curl >/dev/null 2>&1; then
    echo "❌ 需要 curl：本脚本用它拉取仓库文件（安装命令本身就是 curl | sh，正常不会缺）。"
    exit 1
fi
echo
echo "🔍 解析文件版本..."
if ! RESOLVED_REF=$(resolve_ref); then
    echo "❌ 以下 ref 下都找不到 token/mytv.php：$MYTV_REF_CANDIDATES" >&2
    echo "   请确认仓库地址（当前为 $GITHUB_RAW）与分支/标签名，且已推送到 GitHub。" >&2
    exit 1
fi
if [ "$RESOLVED_REF" != "$MYTV_REF" ]; then
    echo "⚠️ 首选 ref '$MYTV_REF' 下没有 token/mytv.php，已改用 '$RESOLVED_REF'。"
    echo "   （token 分支合并进 main 之后属正常现象；分支被删时同样如此。）"
fi
echo "✅ 文件版本: $RESOLVED_REF"

REPO_RAW="$GITHUB_RAW/$RESOLVED_REF"
MYTV_PHP_URL="${REPO_RAW}/token/mytv.php"
BASE_INSTALL_URL="${REPO_RAW}/php/install.sh"

# ========== 通用函数 ==========


# 下载文件（带重试、非空校验、<?php 头校验、可选 sha256），先写临时文件再原子替换
# fetch <url> <目标文件> <sha256|空>
fetch() {
    url=$1
    dest=$2
    want_sha=$3

    # 中间文件放在目标同目录（保证 mv 是原地重命名），名字以 "." 开头：
    # 万一被 Ctrl-C 打断，也不会在网站根目录留下能被当静态文件下载的残留。
    tmp="$(dirname "$dest")/.$(basename "$dest").tmp.$$"
    FETCH_TMP="$tmp"
    trap 'rm -f "$FETCH_TMP"' EXIT
    trap 'rm -f "$FETCH_TMP"; exit 130' HUP INT TERM

    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 "$url" -o "$tmp"; then
        rm -f "$tmp"
        echo "❌ 下载失败: $url"
        echo "   请确认 MYTV_REF='$MYTV_REF' 下该文件存在（token 分支需已推送到 GitHub）。"
        exit 1
    fi

    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo "❌ 下载内容为空: $url"
        exit 1
    fi

    if ! head -c 5 "$tmp" | grep -q '<?php'; then
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

# 生成 20 位十六进制随机 token。
# 不依赖 openssl：优先内核 UUID 字符设备，退化到 /dev/urandom，再退化到混熵 sha256。
gen_token() {
    t=''
    if [ -r /proc/sys/kernel/random/uuid ]; then
        t=$(tr -d '-' < /proc/sys/kernel/random/uuid | tr -dc 'a-f0-9' | cut -c1-20)
    fi
    if [ "${#t}" -lt 20 ] && [ -r /dev/urandom ]; then
        t=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' | tr -dc 'a-f0-9' | cut -c1-20)
    fi
    if [ "${#t}" -lt 20 ]; then
        t=$(printf '%s%s%s' "$(date +%s)" "$$" "$(cat /proc/loadavg 2>/dev/null || echo x)" | sha256sum | cut -c1-20)
    fi
    printf '%s\n' "$t"
}

# 探测 php-fpm 的运行组名。
# 必须在覆盖 mytv.php 属主之前调用：主安装器刚把它 chown 成 web 属主，
# 那正是"PHP 以哪个用户跑"的权威答案；等我们改成 root:root 之后就问不出来了。
detect_php_group() {
    if [ -f "$WEB_DIR/mytv.php" ]; then
        g=$(stat -c %G "$WEB_DIR/mytv.php" 2>/dev/null || true)
        # 排除 root：阶段 2 会把 mytv.php 改成 root:root，重跑时若照抄这个属主，
        # /etc/mytv 就成了 root:root 0710 —— php-fpm 读不到凭据，整站 503。
        # php-fpm 也绝不该以 root 运行，所以 root 一律视为"问错了对象"。
        if [ -n "$g" ] && [ "$g" != "root" ] && grep -q "^$g:" /etc/group 2>/dev/null; then
            printf '%s\n' "$g"
            return 0
        fi
    fi

    # php-fpm 池配置里的 group 指令（最权威，且不受上面那种自我覆盖影响）
    g=$(grep -hs '^[[:space:]]*group[[:space:]]*=' \
            /etc/php/*/fpm/pool.d/*.conf /etc/php*/php-fpm.d/*.conf 2>/dev/null \
        | sed 's/^[[:space:]]*group[[:space:]]*=[[:space:]]*//; s/;.*$//; s/[[:space:]]*$//' \
        | grep -v '^root$' \
        | head -n 1 || true)
    if [ -n "$g" ] && grep -q "^$g:" /etc/group 2>/dev/null; then
        printf '%s\n' "$g"
        return 0
    fi

    case "$OS" in
        alpine) printf 'nginx\n' ;;
        *)      printf 'www-data\n' ;;
    esac
}

# 现有的 tokens.php 是否"看起来可用"。
# 失败方向很重要：**验证不了就当作可用**（保留原文件）。反过来——把好文件当坏的、
# 重新生成一份——会静默轮换掉用户所有凭据，所有客户端同时失效，这是最糟的结果。
tokens_file_ok() {
    [ -f "$TOKENS_FILE" ] || return 1

    # 首选 PHP 真解析一遍（能同时发现语法错误）
    if command -v php >/dev/null 2>&1; then
        r=$(php -r '$f=$argv[1]; try { $c = include $f; } catch (Throwable $e) { $c = false; } echo (is_array($c) && isset($c["tokens"]) && is_array($c["tokens"])) ? "ok" : "bad";' "$TOKENS_FILE" 2>/dev/null || true)
        if [ "$r" = "ok" ]; then
            return 0
        fi
        if [ "$r" = "bad" ]; then
            return 1
        fi
        # r 为空 = php 跑不起来（CLI 缺失或版本异常），落到下面的结构检查
    fi

    # 结构化兜底：有 return、有 tokens 数组、至少一个 64 位十六进制键
    grep -q 'return'  "$TOKENS_FILE" 2>/dev/null || return 1
    grep -q 'tokens'  "$TOKENS_FILE" 2>/dev/null || return 1
    grep -qE "'[0-9a-fA-F]{64}'" "$TOKENS_FILE" 2>/dev/null || return 1
    return 0
}

# ========== 阶段 1：基础环境（委托主安装器，幂等）==========
if [ "$MYTV_SKIP_BASE" = "1" ]; then
    echo
    echo "[1/2] 跳过基础环境安装（MYTV_SKIP_BASE=1）"
else
    echo
    echo "[1/2] 安装 Nginx + PHP-FPM + 站点（委托主安装器）"
    # 主安装器负责：装包、探测并写 /etc/nginx/mytv-fpm.conf、装站点配置（含备份与
    # nginx -t 回滚）、部署 php/mytv.php + php/sub.php、自检。它自己就是幂等的。
    # ⚠️ 它会部署"无认证"的 mytv.php 并期望裸访问返回 200，所以重跑本脚本时会有一个
    #    短暂的无认证窗口，阶段 2 随后覆盖。幂等重跑通常发生在维护窗口，可接受。
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 "$BASE_INSTALL_URL" \
        | MYTV_REF="$RESOLVED_REF" sh || {
        # 主安装器的最后一步自检要求「裸访问 = 200」，而 token 版站点裸访问是 403；
        # 叠加 opcache 的 revalidate_freq（默认 2s）——重跑时它可能仍在执行刚被覆盖掉的
        # token 版脚本，于是读成 403 判定"站点不可访问"并 exit 1。
        # 那种情况下它其实已经把 nginx/php/站点配置/文件全部装好了，直接中断本脚本
        # 反而会把站点留在"阶段 1 部署的无认证版本"上——这正是不该发生的状态。
        #
        # 所以这里只区分「口径不符」与「真故障」：要求 nginx+php-fpm 端到端确实在跑
        # （200 = 基线版，403 = token 版），否则如实报错退出，不掩盖问题。
        health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1/mytv.php" || true)
        case "$health" in
            200|403)
                echo
                echo "⚠️ 主安装器自检未通过——token 版站点裸访问返回 403，与它要求的 200 口径不符"
                echo "   （或它读到了 opcache 里尚未失效的旧脚本）。站点已能端到端响应 $health，"
                echo "   说明环境与站点配置都已就绪，继续执行阶段 2。"
                ;;
            *)
                echo "❌ 基础安装失败：站点无法端到端响应（HTTP $health）。请检查上面的错误输出。" >&2
                exit 1
                ;;
        esac
    }
fi

if [ "$MYTV_TOKEN" = "0" ]; then
    echo
    echo "ℹ️ MYTV_TOKEN=0：只做了阶段 1，站点当前**没有认证**（等价主脚本）。"
    echo "   要启用认证请去掉该变量重跑本脚本。"
    exit 0
fi

# ========== 阶段 2：token 化 ==========
echo
echo "[2/2] 切换为 token 版"

# 2.1 先探测 php 运行组（必须在 chown root:root 之前做，理由见函数注释）
PHP_GROUP=$(detect_php_group)
echo "ℹ️ PHP 运行组: $PHP_GROUP"

# 2.2 部署 token 版应用文件。
# 属主是 root:root 0644（有意偏离主安装器的 chown web 属主）：PHP 只需要读权限，
# 而 root 属主堵死了"Web 层被攻破后改写认证逻辑"这条路。配置在 /etc/mytv 里，
# 与源码分离，所以覆盖安装天然安全，不需要备份。
mkdir -p "$WEB_DIR"
rm -f "$WEB_DIR"/.mytv.php.tmp.* "$WEB_DIR"/mytv.php.tmp.* \
      "$WEB_DIR"/.sub.php.tmp.* "$WEB_DIR"/sub.php.tmp.* 2>/dev/null || true
fetch "$MYTV_PHP_URL" "$WEB_DIR/mytv.php" "$SHA_MYTV_PHP"
chown root:root "$WEB_DIR/mytv.php"
chmod 0644 "$WEB_DIR/mytv.php"
echo "✅ 已部署 $WEB_DIR/mytv.php（root:root 0644）"

# 2.3 删掉 sub.php：token 版不提供它（功能已并入 mytv.php?sub=）。
# 阶段 1 刚部署了一份，留着就是一个**无认证入口**，必须清掉。
if [ -f "$WEB_DIR/sub.php" ]; then
    rm -f "$WEB_DIR/sub.php"
    echo "✅ 已删除 $WEB_DIR/sub.php（功能改用 mytv.php?sub=）"
fi

# 2.4 配置目录：root:组 0710，文件 0640 —— 目录不可列，组内可读
mkdir -p "$TOKENS_DIR"
chown "root:$PHP_GROUP" "$TOKENS_DIR"
chmod 0710 "$TOKENS_DIR"

# 2.5 幂等生成 tokens.php
TOKENS_REGEN=""
if tokens_file_ok; then
    echo "✅ $TOKENS_FILE 已存在且可用，保持不变（不重复生成、不重复打印 token）"
elif [ -f "$TOKENS_FILE" ]; then
    # 走到这里说明 PHP 明确报了 bad：这种配置会让整站 503。
    # 不静默覆盖用户数据——先留证据再重建。
    bad_backup="$TOKENS_FILE.bad.$(date +%Y%m%d%H%M%S)"
    cp "$TOKENS_FILE" "$bad_backup" 2>/dev/null || true
    echo "⚠️ $TOKENS_FILE 结构不正确（站点会返回 503），已备份到 $bad_backup"
    echo "   现在重新生成一份新凭据；原文件里的 token 若还想用，可从备份里找回哈希。"
    TOKENS_REGEN=1
fi

if [ ! -f "$TOKENS_FILE" ] || [ -n "$TOKENS_REGEN" ]; then
    NEW_TOKEN=$(gen_token)
    if [ "${#NEW_TOKEN}" -lt 20 ]; then
        echo "❌ 无法生成足够的随机数，安装中止（别用可预测的 token）。"
        exit 1
    fi
    new_hash=$(printf '%s' "$NEW_TOKEN" | sha256sum | awk '{print $1}')
    tmp_tok="$TOKENS_DIR/.tokens.php.tmp.$$"
    cat > "$tmp_tok" <<EOF
<?php
// 由 token/install.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')；改完即生效（opcache 默认 2s 内）。
//
// 键 = sha256(token) 的 hex，值 = 人类可读标签（仅供辨认，不参与判定，可以随便写）。
// 加人：printf '%s' '新token' | sha256sum   把输出的哈希粘进下面的数组
// 封人：删掉对应那一行即可，立即生效（无需 reload、无需重启）
// 注意：token 大小写敏感，长度 8~40 的低位 ASCII 最稳（本脚本生成的是 20 位十六进制）
return [
    'auth'   => true,          // 总开关：false = 完全放行且不盖章（与无认证版行为一致）
    'tokens' => [
        '$new_hash' => 'install-generated',
    ],
];
EOF
    mv -f "$tmp_tok" "$TOKENS_FILE"
    chown "root:$PHP_GROUP" "$TOKENS_FILE"
    chmod 0640 "$TOKENS_FILE"
    echo "✅ 已生成 $TOKENS_FILE（0640 root:$PHP_GROUP）"
fi

# 2.6 自检：认证必须真的生效
echo "🔍 站点自检..."
# ⚠️ 为什么这里要轮询而不是直接 curl 一次：
# opcache 的 validate_timestamps 有 revalidate_freq（默认 2s）的延迟窗口，刚替换
# mytv.php 的瞬间，php-fpm 可能还在执行**阶段 1 那份无认证的**旧脚本，于是裸访问
# 会返回 200，自检就会误报"认证没有生效"并在全新安装时中止。
# 轮询到出现确定结论为止：403 是我们要的结果；502/504/000 是明确故障，不必等。
code=""
n=0
while [ "$n" -lt 6 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1/mytv.php" || true)
    case "$code" in
        403) break ;;                 # 期望结果
        200|503) n=$((n + 1)); sleep 2 ;;  # 可能是 opcache 尚未失效，再等等
        *) break ;;                   # 502/504/000 等：明确故障，直接判定
    esac
done
case "$code" in
    403)
        echo "✅ 裸访问返回 403（未授权被正确拒绝）"
        ;;
    503)
        echo "❌ 裸访问返回 503：认证配置读不到。请依次检查："
        echo "     ls -l $TOKENS_FILE      # 应为 0640 root:$PHP_GROUP"
        echo "     ls -ld $TOKENS_DIR      # 应为 0710 root:$PHP_GROUP"
        echo "     php -r 'var_dump(include \"$TOKENS_FILE\");'"
        echo "     若 PHP 配了 open_basedir，需要包含 $TOKENS_DIR"
        exit 1
        ;;
    502|504)
        echo "❌ 裸访问返回 HTTP $code：Nginx 连不上 PHP-FPM。"
        echo "   请对比 /etc/nginx/mytv-fpm.conf 里的 fastcgi_pass 与 'ss -ltnp | grep -E \"sock|9000\"' 的实际监听地址。"
        exit 1
        ;;
    200)
        echo "❌ 裸访问返回 200：认证没有生效——$WEB_DIR/mytv.php 可能不是 token 版。"
        echo "   请确认 $MYTV_PHP_URL 拉到的文件就是 token 版，或核对 SHA_MYTV_PHP。"
        exit 1
        ;;
    000|"")
        echo "❌ 无法访问 http://127.0.0.1/mytv.php。"
        echo "   请检查 80 端口是否被占用（ss -ltnp | grep :80）、防火墙是否放行。"
        if [ "$OS" = "alpine" ]; then
            echo "   若你用过仓库里的 nginx/alpine/nginx.conf，请确认 /etc/nginx/nginx.conf 中"
            echo "     include /etc/nginx/http.d/*.conf;"
            echo "   这行没有被注释掉。"
        fi
        exit 1
        ;;
    *)
        echo "⚠️ 裸访问返回 HTTP $code，请手动访问 http://<服务器IP>/mytv.php 确认。"
        ;;
esac

# 有明文 token（本次新生成）时才可能做"带 token 应当放行"的正向探针；
# 已存在 tokens.php 的机器上脚本拿不到明文，只能提示用户自己验证。
if [ -n "$NEW_TOKEN" ]; then
    # 同上：opcache 可能还没失效，403/503 都可能是短暂现象，轮询到稳定结论
    code2=""
    n=0
    while [ "$n" -lt 6 ]; do
        code2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1/mytv.php?token=$NEW_TOKEN" || true)
        if [ "$code2" = "200" ]; then
            break
        fi
        case "$code2" in
            403|503) n=$((n + 1)); sleep 2 ;;
            *) break ;;
        esac
    done
    if [ "$code2" = "200" ]; then
        echo "✅ 带 token 访问返回 200（认证链路通）"
    else
        echo "❌ 带 token 访问返回 HTTP $code2（期望 200）。"
        echo "   请核对 $TOKENS_FILE 里的哈希是否为："
        printf '%s' "$NEW_TOKEN" | sha256sum
        exit 1
    fi
else
    echo "ℹ️ 未能取得明文 token（$TOKENS_FILE 已存在），请用你自己的 token 访问验证："
    echo "     curl -i 'http://127.0.0.1/mytv.php?token=<你的token>&p=m3u'"
fi

# ========== 完成 ==========
echo
echo "========================================="
echo "   🎉 token 版安装完成！"
echo "========================================="
if [ -n "$NEW_TOKEN" ]; then
    echo
    echo "🔑 你的稳定 token（这串明文只会显示这一次）："
    echo
    echo "        $NEW_TOKEN"
    echo
    echo "   ⚠️ 服务器上只保存它的 sha256 哈希，明文丢了只能重新生成；"
    echo "      请立刻保存到密码管理器。"
fi
echo
echo "📁 应用: $WEB_DIR/mytv.php（root:root 0644，取自 $RESOLVED_REF，与仓库文件逐字节一致，可 sha256 比对）"
echo "🔧 凭据: $TOKENS_FILE（加人/封人都改这里）"
echo
echo "用法示例（token 放最前面，浏览器地址栏直接粘）："
echo "  整份订阅:  http://<服务器IP>/mytv.php?token=<你的token>&p=m3u"
echo "  只留两台:  http://<服务器IP>/mytv.php?token=<你的token>&p=m3u&filter=翡翠台,凤凰中文"
echo "  代理订阅:  http://<服务器IP>/mytv.php?token=<你的token>&sub=<编码后的上游m3u地址>"
echo "            （filter 也可用；关键字按节目名子串匹配，大小写不敏感，英文逗号分隔）"
echo
echo "命令行自检（⚠️ 链接必须用引号包住，否则 & 会被 shell 当成后台执行符、命令从 & 处截断，"
echo "              token 根本传不到服务器，还会看到 [1]+ Done）："
echo "        curl -i 'http://127.0.0.1/mytv.php?token=<你的token>&p=m3u'   # 期望 200"
echo "        curl -i 'http://127.0.0.1/mytv.php?p=m3u'                    # 期望 403"
echo
echo "加一枚 token："
echo "        printf '%s' '你的新token' | sha256sum"
echo "      把输出的哈希粘进 $TOKENS_FILE 的 tokens 数组（值随便写个标签，只为辨认）"
echo "封一枚 token：删掉对应那一行即可，立即生效（opcache 默认 2s 内）"
echo
echo "回退到无认证版："
echo "        curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/main/php/install.sh | sh"
echo
echo "⚠️ 强烈建议：打开 $SITE_CONF 里注释掉的 limit_req"
echo "   （默认开启认证后，所有扫描请求都会打到 PHP 进程，而不是被 nginx 直接挡掉）。"
echo "⚠️ 安全边界三段话："
echo "   ① mytv.php 可以代理任意 url 参数，这个事实没有改变；"
echo "   ② token 挡的是全网扫描器和白嫖，但**任何拿到一枚 token 的人，在你删掉那一行之前，"
echo "      都能永久拿它当开放代理用**——playlist 里印的就是这枚凭据，转发出去等于交出权限；"
echo "   ③ 真要收紧：把 mytv.php 里的 \$enable_domain_check 打开并维护域名白名单，"
echo "      再配合 limit_req 与 allow/deny。"
