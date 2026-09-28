<?php
//error_reporting(E_ALL);
//ini_set('display_errors', '1');

// ===== 兼容低版本 PHP 的辅助函数 =====
// [mytv-token] 从基线文件中部上移到此处：并入的 sub= 分支与本次新增的 helper
// 都会用到它们，而基线把它们定义在使用点之后，不移动就会出现「函数未定义」。
if (!function_exists('getallheaders')) {
    function getallheaders() {
        $headers = [];
        foreach ($_SERVER as $name => $value) {
            if (strpos($name, 'HTTP_') === 0) {
                $key = str_replace('_', '-', ucwords(strtolower(str_replace('_', ' ', substr($name, 5)))));
                $headers[$key] = $value;
            }
        }
        return $headers;
    }
}

// 兼容 str_starts_with() 函数
if (!function_exists('str_starts_with')) {
    function str_starts_with($haystack, $needle) {
        return substr($haystack, 0, strlen($needle)) === $needle;
    }
}

// 兼容 str_contains() 函数
if (!function_exists('str_contains')) {
    function str_contains($haystack, $needle) {
        return $needle !== '' && strpos($haystack, $needle) !== false;
    }
}

/* ===== mytv-token begin ===== */
/*
 * mytv token 版：稳定 token 认证 + 订阅过滤
 * 设计文档：docs/plans/01-auth-token.md
 *
 * 本块是相对仓库 php/mytv.php 新增的全部内容。块外的代码除若干标注为
 * 「[mytv-token]」的改动点外与基线逐字一致，方便日后同步上游。
 *
 * 模型：单层稳定 token。auth 开启时任何端点都只要求「一枚有效 token」——
 * 没有端点矩阵、没有临时 token、没有过期时间。吊销 = 从 tokens.php 删一行。
 */

// 唯一需要知道的配置入口（本文件永不需要编辑）
$MYTV_TOKENS_FILE = '/etc/mytv/tokens.php';
// sub= 的播放列表改写里，是否把别站的 mytv.php?url=X 解包成本站单跳
$MYTV_UNWRAP_REMOTE_PROXY = true;
defined('MYTV_TOKENS_FILE') || define('MYTV_TOKENS_FILE', $MYTV_TOKENS_FILE);
defined('MYTV_UNWRAP_REMOTE_PROXY') || define('MYTV_UNWRAP_REMOTE_PROXY', (bool) $MYTV_UNWRAP_REMOTE_PROXY);

if (!function_exists('mytv_cfg')) {
    /**
     * 读取 /etc/mytv/tokens.php，进程内静态缓存一次。
     * 返回数组，或 false（文件缺失 / 不可读 / 语法错 / 返回值不是数组）。
     * include 一个语法错误的文件在 PHP7+ 抛 ParseError（Throwable 子类），
     * 这里捕获成 false —— 要的是 503 加一句能看懂的提示，而不是 500 白屏。
     */
    function mytv_cfg() {
        static $cfg = null;
        if ($cfg !== null) {
            return $cfg;
        }
        $cfg  = false;
        $file = defined('MYTV_TOKENS_FILE') ? MYTV_TOKENS_FILE : '/etc/mytv/tokens.php';
        // 先用 is_readable 兜住「文件不存在」：include 一个不存在的文件只会发 warning
        // 并返回 1，那条 warning 会被打进响应体（把服务器路径暴露给访问者）。
        if (is_readable($file)) {
            try {
                $r = include $file;
            } catch (\Throwable $e) {
                $r = false;
            }
            if (is_array($r)) {
                $cfg = $r;
            }
        }
        return $cfg;
    }
}

if (!function_exists('mytv_auth_on')) {
    /** 总开关：tokens.php 里 'auth' => true 时开启认证 */
    function mytv_auth_on() {
        $c = mytv_cfg();
        return is_array($c) && !empty($c['auth']);
    }
}

if (!function_exists('mytv_fail_503')) {
    /**
     * 认证配置坏了就 fail closed（503）。
     * 与 403 严格区分：503 是管理员配置错误，403 是请求者未授权。
     */
    function mytv_fail_503($why) {
        $file = defined('MYTV_TOKENS_FILE') ? MYTV_TOKENS_FILE : '/etc/mytv/tokens.php';
        http_response_code(503);
        header('Content-Type: text/plain; charset=utf-8');
        header('Retry-After: 300');
        echo "503 认证配置错误：" . $why . "\n\n";
        echo "配置文件：" . $file . "\n";
        echo "认证已开启，但服务器读不到凭据列表，因此拒绝所有请求（fail closed），不会裸奔放行。\n\n";
        echo "排查步骤：\n";
        echo "  ls -l " . $file . "        # 应为 0640 root:<php-fpm 用户组>\n";
        echo "  ls -ld " . dirname($file) . "   # 应为 0710 root:<php-fpm 用户组>\n";
        echo "  php -r 'var_dump(include \"" . $file . "\");'\n";
        echo "  若 PHP 配了 open_basedir，需要包含 " . dirname($file) . "\n";
        exit;
    }
}

if (!function_exists('mytv_misconfigured')) {
    /**
     * 配置错误检测，返回 false 表示配置可用。
     * 注意 auth 关闭时也要求 tokens.php 可读：读不到就无法确认 auth 究竟是
     * true 还是 false，这时宁可 503 也不猜（猜错就是整站裸奔）。
     */
    function mytv_misconfigured() {
        $c = mytv_cfg();
        if ($c === false) {
            mytv_fail_503('缺失 / 不可读 / 语法错误 / 返回值不是数组');
        }
        if (!empty($c['auth'])) {
            if (!isset($c['tokens']) || !is_array($c['tokens']) || count($c['tokens']) === 0) {
                mytv_fail_503('auth 已开启，但 tokens 数组为空或不是数组（尚未签发任何凭据）');
            }
        }
        return false;
    }
}

if (!function_exists('mytv_token_ok')) {
    /**
     * token 是否有效。数组键是 sha256(token) 的 hex，所以判定就是一次
     * O(1) 键查找：不存明文，也不需要 hash_equals 逐字节比较——被查的是
     * 攻击者无法反推原像的哈希值，哈希表的时序差异泄露不了可用信息。
     */
    function mytv_token_ok($tok) {
        $c = mytv_cfg();
        if (!is_array($c) || !is_string($tok) || $tok === '') {
            return false;
        }
        if (!isset($c['tokens']) || !is_array($c['tokens'])) {
            return false;
        }
        return isset($c['tokens'][hash('sha256', $tok)]);
    }
}

if (!function_exists('mytv_deny')) {
    /** 403：只说结果，不夹带命令、路径与 token 回显。 */
    function mytv_deny($tok_given) {
        http_response_code(403);
        header('Content-Type: text/plain; charset=utf-8');
        if (is_string($tok_given) && $tok_given !== '') {
            echo "403 未授权：token 无效。\n";
        } else {
            echo "403 未授权：需要有效的 token。\n";
            echo "请在链接后追加 token 参数（已有 ? 参数时用 & 连接）。\n";
        }
        exit;
    }
}

if (!function_exists('mytv_require_token')) {
    /**
     * 入口处一次性判定，覆盖所有端点（p=m3u / sub= / url= / 裸访问 / 未知参数组合）。
     * 单层模型下所有端点同规则，所以整个文件只有这一处调用。
     */
    function mytv_require_token() {
        mytv_misconfigured();
        // ?token[]=x 会给到数组：非字符串一律当成"没带"，省得下游拿到数组
        $tok = (isset($_GET['token']) && is_string($_GET['token'])) ? $_GET['token'] : '';
        if (mytv_auth_on() && !mytv_token_ok($tok)) {
            mytv_deny($tok);
        }
    }
}

if (!function_exists('mytv_strip_token')) {
    /** 剥掉 URL 里已有的 token 查询参数（保留 fragment 与其它参数顺序，不留悬空的 ? 或 &） */
    function mytv_strip_token($url) {
        if (!is_string($url) || $url === '') {
            return $url;
        }
        $frag = '';
        $hash = strpos($url, '#');
        if ($hash !== false) {
            $frag = substr($url, $hash);
            $url  = substr($url, 0, $hash);
        }
        $q = strpos($url, '?');
        if ($q === false) {
            return $url . $frag;
        }
        $base = substr($url, 0, $q);
        $keep = [];
        foreach (explode('&', substr($url, $q + 1)) as $pair) {
            if ($pair === '') {
                continue;
            }
            $eq   = strpos($pair, '=');
            $name = strtolower($eq === false ? $pair : substr($pair, 0, $eq));
            if ($name === 'token') {
                continue;
            }
            $keep[] = $pair;
        }
        return $base . ($keep ? '?' . implode('&', $keep) : '') . $frag;
    }
}

if (!function_exists('mytv_stamp')) {
    /**
     * 盖上「请求者自己那枚」token。
     * auth 关闭时原样返回：无认证版的行为必须逐字节保持不变，不能平白多出 token 参数。
     * 盖章前先剥旧值，既防重复盖章，也防沿用上游或旧 playlist 里已吊销的 token。
     *
     * token 一律放在**第一个**查询参数位：mytv.php?token=T&url=<目标URL>。
     * 排在尾部（…?url=<目标URL>&token=T）时目标 URL 自带查询串就被读成"我们的参数"，
     * 反过来尾部的 token 也容易被当成目标 URL 的参数——播放器与人都分不清
     * "这是本站入口的凭据"还是"上游源站的 token"。放最前面则一眼可辨。
     */
    function mytv_stamp($url, $tok) {
        if (!mytv_auth_on() || !is_string($tok) || $tok === '') {
            return $url;
        }
        $u = mytv_strip_token($url);

        // 先摘掉 fragment，token 参数必须插在 ? 之后、# 之前
        $frag = '';
        $hash = strpos($u, '#');
        if ($hash !== false) {
            $frag = substr($u, $hash);
            $u    = substr($u, 0, $hash);
        }

        $stamp = 'token=' . rawurlencode($tok);
        $q     = strpos($u, '?');
        if ($q === false) {
            return $u . '?' . $stamp . $frag;
        }
        $rest = substr($u, $q + 1);
        return substr($u, 0, $q) . '?' . $stamp . ($rest === '' ? '' : '&' . $rest) . $frag;
    }
}

if (!function_exists('mytv_url_host')) {
    /** 取 URL 的 host（小写）；相对链接或解析失败返回空串 */
    function mytv_url_host($url) {
        if (!is_string($url) || $url === '') {
            return '';
        }
        $h = parse_url($url, PHP_URL_HOST);
        return is_string($h) ? strtolower($h) : '';
    }
}

if (!function_exists('mytv_is_own_url')) {
    /** 是否指向本站入口。用于「只给自有链接盖章」——凭据不能送给第三方源站 */
    function mytv_is_own_url($url, $opts) {
        if (!is_string($url) || $url === '') {
            return false;
        }
        if ($opts['path'] !== '' && strpos($url, $opts['path']) === 0) {
            return true;
        }
        $h = mytv_url_host($url);
        if ($h === '') {
            // 相对链接：以 mytv.php 开头的才算我们的（如 "mytv.php?url=..."）
            return (stripos(ltrim($url), 'mytv.php') === 0);
        }
        return $h === $opts['own_host'];
    }
}

if (!function_exists('mytv_stamp_own')) {
    /** 只给自有链接盖章（hostsub 模式用：host 替换已由整行 preg_replace 做完） */
    function mytv_stamp_own($url, $opts) {
        if (!mytv_is_own_url($url, $opts)) {
            return $url;
        }
        return mytv_stamp($url, $opts['token']);
    }
}

if (!function_exists('mytv_is_proxy_link')) {
    /**
     * 是否形如 mytv.php?url=... 的代理链接（本站、别站、相对形态都算）。
     * 命中时把内层 url 写入 $inner 并返回 true。
     * 用 parse_str 只解码一次：$_GET 已被 PHP 解码过，再 urldecode 会双重解码，
     * 把内层 URL 里本来就有的 % 序列解坏。
     */
    function mytv_is_proxy_link($url, &$inner) {
        $inner = null;
        if (!is_string($url) || $url === '') {
            return false;
        }
        if (stripos($url, 'mytv.php') === false) {
            return false;
        }
        $q = strpos($url, '?');
        if ($q === false) {
            return false;
        }
        if (stripos(substr($url, 0, $q), 'mytv.php') === false) {
            return false;
        }
        $params = [];
        parse_str(substr($url, $q + 1), $params);
        if (!isset($params['url']) || !is_string($params['url']) || $params['url'] === '') {
            return false;
        }
        $inner = $params['url'];
        return true;
    }
}

if (!function_exists('mytv_rewrite_link')) {
    /**
     * wrap 模式（sub=）：把一条链接归一化成「本站单跳代理链接」并盖章。
     *
     * $onlyOwn = true 时只处理代理形态（mytv.php?url=…）与本站链接，纯第三方
     * 直连 URL 原样返回 —— 用于 #EXTM3U 的 url-tvg / catchup-source 等属性：
     * 既不能把凭据送给源站，也不该把第三方直连 EPG 平白拖进本站代理。
     */
    function mytv_rewrite_link($uri, $opts, $onlyOwn) {
        $uri = trim($uri);
        if ($uri === '') {
            return $uri;
        }

        $inner   = null;
        $isProxy = mytv_is_proxy_link($uri, $inner);
        $host    = mytv_url_host($uri);
        $isOwn   = $isProxy ? ($host === '' || $host === $opts['own_host'])
                            : ($host !== '' && $host === $opts['own_host']);

        if ($onlyOwn && !$isProxy && !$isOwn) {
            return $uri;   // 纯第三方直连：不动、不盖章
        }

        if ($isProxy) {
            if (!$opts['unwrap'] && !$isOwn) {
                // 关闭解包：退回 stock sub.php 的行为——把别站代理链接原样再包一层
                $target = $uri;
                if (!preg_match('#^https?://#i', $target)) {
                    $target = $opts['base_root'] . '/' . ltrim($target, '/');
                }
                return mytv_stamp($opts['path'] . '?url=' . urlencode($target), $opts['token']);
            }
            // 解包成本站单跳：避免双跳套娃，也不再依赖别人的服务器
            $url = $inner;
        } else {
            if (preg_match('#^https?://#i', $uri)) {
                $url = $uri;
            } elseif (substr($uri, 0, 1) === '/') {
                $url = $opts['base_root'] . $uri;
            } else {
                $url = $opts['base_dir'] . $uri;
            }
        }

        return mytv_stamp($opts['path'] . '?url=' . urlencode($url), $opts['token']);
    }
}

if (!function_exists('mytv_rewrite_attr_value')) {
    /** 改写一条属性值（url-tvg / x-tvg-url / catchup-source 可能是逗号分隔的多值） */
    function mytv_rewrite_attr_value($attr, $val, $opts) {
        if (strcasecmp($attr, 'URI') === 0) {
            return ($opts['mode'] === 'hostsub')
                ? mytv_stamp_own($val, $opts)
                : mytv_rewrite_link($val, $opts, false);
        }
        $items = explode(',', $val);
        foreach ($items as $k => $one) {
            $one = trim($one);
            if ($one === '') {
                continue;
            }
            $items[$k] = ($opts['mode'] === 'hostsub')
                ? mytv_stamp_own($one, $opts)
                : mytv_rewrite_link($one, $opts, true);
        }
        return implode(',', $items);
    }
}

if (!function_exists('mytv_rewrite_attrs')) {
    /**
     * 处理 # 行里带 URL 的属性（含 #EXTM3U 头部行）。
     *
     * catchup-source 含 ${...} 模板时一律不动：模板要留给播放器替换，一旦被
     * urlencode 成 %24%7B…%7D，播放器就认不出模板，时移播放直接取不到流。
     * 这类链接指向的多半是无需认证的第三方代理，保持原样反而能用。
     */
    function mytv_rewrite_attrs($line, $opts) {
        if (strpos($line, '=') === false) {
            return $line;
        }
        $out = preg_replace_callback(
            '/\b(url-tvg|x-tvg-url|catchup-source|URI)\s*=\s*("([^"]*)"|[^\s]+)/i',
            function ($m) use ($opts) {
                $attr   = $m[1];
                $full   = $m[2];
                $quoted = (substr($full, 0, 1) === '"');
                $val    = $quoted ? substr($full, 1, -1) : $full;
                if ($val === '') {
                    return $m[0];
                }
                if (strcasecmp($attr, 'catchup-source') === 0 && strpos($val, '${') !== false) {
                    return $m[0];
                }
                $new = mytv_rewrite_attr_value($attr, $val, $opts);
                if ($new === $val) {
                    return $m[0];
                }
                return $attr . '=' . ($quoted ? '"' . $new . '"' : $new);
            },
            $line
        );
        return ($out === null) ? $line : $out;
    }
}

if (!function_exists('mytv_filter_keywords')) {
    /**
     * 解析 filter=A,B 参数（英文逗号分隔，容忍全角逗号）。
     * 空输入返回空数组 = 不过滤。上限 20 个关键字、每个 64 字节：
     * filter 是直接来自 URL 的输入，不设上限的话一个超长参数就能把
     * 每行的匹配开销放大到病态程度。
     */
    function mytv_filter_keywords($raw) {
        if (!is_string($raw) || trim($raw) === '') {
            return [];
        }
        $raw = str_replace('，', ',', $raw);
        $out = [];
        foreach (explode(',', $raw) as $kw) {
            $kw = trim($kw);
            if ($kw === '') {
                continue;
            }
            if (strlen($kw) > 64) {
                $kw = substr($kw, 0, 64);
            }
            if (!in_array($kw, $out, true)) {
                $out[] = $kw;
            }
            if (count($out) >= 20) {
                break;
            }
        }
        return $out;
    }
}

if (!function_exists('mytv_entry_matches')) {
    /**
     * 条目块是否命中过滤关键字。$inf_lines 是该块里的所有 #EXTINF 行。
     * 名称取「属性区之后、逗号之后」的部分（M3U 的显示名），兼匹配 tvg-name。
     *
     * 用 stripos 而不是 mb_stripos：二进制安全，UTF-8 多字节（>=0x80）不参与
     * 大小写折叠，因此中文子串匹配正确、ASCII 大小写不敏感，且不依赖 mbstring
     * —— Alpine 的 php 默认不带 mbstring，这条依赖能省则省。
     */
    function mytv_entry_matches($inf_lines, $kws) {
        if (empty($kws)) {
            return true;
        }
        foreach ((array) $inf_lines as $line) {
            $names = [];
            // 显示名在「最后一个引号之后的首个逗号」之后；整行没有引号则取首个逗号。
            // 不能直接用最后一个逗号：显示名自身可能含逗号（如「翡翠台,高清」）。
            $q = strrpos($line, '"');
            $c = ($q === false) ? strpos($line, ',') : strpos($line, ',', $q);
            $names[] = ($c === false) ? $line : substr($line, $c + 1);
            if (preg_match_all('/tvg-name\s*=\s*"([^"]*)"/i', $line, $m)) {
                foreach ($m[1] as $v) {
                    $names[] = $v;
                }
            } elseif (preg_match_all('/tvg-name\s*=\s*([^"\s,]+)/i', $line, $m2)) {
                foreach ($m2[1] as $v) {
                    $names[] = $v;
                }
            }
            foreach ($names as $name) {
                foreach ($kws as $kw) {
                    if (stripos($name, $kw) !== false) {
                        return true;
                    }
                }
            }
        }
        return false;
    }
}

if (!function_exists('mytv_rewrite_playlist')) {
    /**
     * p=m3u 与 sub= 共用的播放列表改写器：分块解析 -> 过滤 -> 改写 -> 盖章。
     *
     * $opts:
     *   mode      'hostsub' = p=m3u 的「替换 host」语义（基线语义）
     *             'wrap'    = sub= 的「包装成本站代理」语义
     *   path      本站入口前缀 scheme://host/script，来自 SCRIPT_NAME
     *   base_root 'scheme://host[:port]'（wrap 解析相对路径用）
     *   base_dir  base_root 加目录（wrap 解析相对路径用）
     *   token     请求者自己那枚 token
     *   kws       过滤关键字数组（空数组 = 不过滤）
     *   own_host  本站 host（小写）
     *   unwrap    是否把别站 mytv.php?url= 解包成本站单跳
     *
     * 换行符逐字节保留（上游可能是 CRLF）：把正文切成「行, 分隔符」交替的数组，
     * 只改行本身，最后原样拼回。这样「不改写时输出 === 输入」。
     *
     * 过滤以「条目块」为粒度：连续若干 # 行 + 紧随的一行 URL 视为一块，整块同去
     * 同留 —— 否则会产出没有 URL 的 EXTINF 或没有 EXTINF 的裸 URL。
     */
    function mytv_rewrite_playlist($body, $opts) {
        if (!is_string($body) || $body === '') {
            return $body;
        }

        $opts = array_merge([
            'mode'      => 'wrap',
            'path'      => '',
            'base_root' => '',
            'base_dir'  => '',
            'token'     => '',
            'kws'       => [],
            'own_host'  => '',
            'unwrap'    => true,
        ], is_array($opts) ? $opts : []);

        $filtering = !empty($opts['kws']);
        $hostsub   = ($opts['mode'] === 'hostsub');

        $parts = preg_split('/(\r\n|\n|\r)/', $body, -1, PREG_SPLIT_DELIM_CAPTURE);
        $n     = count($parts);

        $out      = '';
        $pend     = [];      // 已处理但还没等到 URL 的 # 行（连同它们各自的分隔符）
        $infSeen  = false;   // 本块里出现过 #EXTINF
        $infMatch = false;   // 且至少有一行命中了关键字

        for ($i = 0; $i < $n; $i += 2) {
            $raw   = $parts[$i];
            $delim = ($i + 1 < $n) ? $parts[$i + 1] : '';
            $t     = rtrim($raw);

            // 空行：过滤时丢弃（否则被滤掉的块会留下一片空行），不过滤时原样保留
            if ($t === '') {
                if ($pend) {
                    if (!$filtering) {
                        foreach ($pend as $p) {
                            $out .= $p;
                        }
                    }
                    $pend = [];
                    $infSeen = false;
                    $infMatch = false;
                }
                if (!$filtering) {
                    $out .= $raw . $delim;
                }
                continue;
            }

            // [mytv-token] hostsub：对每一行（含 # 行）做整体替换，与基线那个
            // 作用于整个正文的 preg_replace 等价；正则从基线的 #http://[^/]+/mytv\.php#
            // 放宽为 https?，否则上游用 https 写法的自有链接不会被归一到本站，
            // 认证开启后这些链接会一律 403。
            $line = $hostsub
                ? preg_replace('#https?://[^/]+/mytv\.php#i', $opts['path'], $raw)
                : $raw;

            if ($t[0] === '#') {
                // #EXTM3U 头部行：永远保留（它是列表头不是内容），只处理其中的属性
                if (stripos(ltrim($t), '#EXTM3U') === 0) {
                    if ($pend) {
                        if (!$filtering) {
                            foreach ($pend as $p) {
                                $out .= $p;
                            }
                        }
                        $pend = [];
                        $infSeen = false;
                        $infMatch = false;
                    }
                    $out .= mytv_rewrite_attrs($line, $opts) . $delim;
                    continue;
                }
                // 普通注释行：先攒着，等见到 URL 才能决定这一块去留
                $pend[] = mytv_rewrite_attrs($line, $opts) . $delim;
                if (stripos($t, '#EXTINF') === 0) {
                    $infSeen = true;
                    if (mytv_entry_matches([$line], $opts['kws'])) {
                        $infMatch = true;
                    }
                }
                continue;
            }

            // 资源行：一个条目块到此结束
            if (!$filtering || ($infSeen && $infMatch)) {
                foreach ($pend as $p) {
                    $out .= $p;
                }
                $out .= ($hostsub
                    ? mytv_stamp_own($line, $opts)
                    : mytv_rewrite_link($line, $opts, false)) . $delim;
            }
            $pend = [];
            $infSeen = false;
            $infMatch = false;
        }

        // 收尾：末尾悬空的注释块（只有 # 行、没有 URL）
        if ($pend && !$filtering) {
            foreach ($pend as $p) {
                $out .= $p;
            }
        }

        return $out;
    }
}
/* ===== mytv-token end ===== */

$request_url = isset($_GET['url']) ? urldecode($_GET['url']) : '';
$p = $_GET['p'] ?? '';

// [mytv-token] token 版新增的入参
$SUB    = isset($_GET['sub']) ? $_GET['sub'] : '';
$FILTER = isset($_GET['filter']) ? $_GET['filter'] : '';
$TOKEN  = (isset($_GET['token']) && is_string($_GET['token'])) ? $_GET['token'] : '';
$kws    = mytv_filter_keywords($FILTER);

// [mytv-token] 本站入口标识。$ENTRY_PATH 是盖章与 hostsub 的判据，必须精确到脚本本身。
// 用 SCRIPT_NAME 而不是 PHP_SELF：后者会把 PATH_INFO 也带上（如 /mytv.php/foo），
// 拿它拼出来的链接会 404。
$scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
    ? 'https'
    : 'http';

$ENTRY_PATH = $scheme . '://' . $_SERVER['HTTP_HOST'] . $_SERVER['SCRIPT_NAME'];
$OWN_HOST   = strtolower((string) parse_url('http://' . (isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : 'localhost'), PHP_URL_HOST));

// [mytv-token] 入口处一次性判定，取代按端点分级的矩阵：
// 单层稳定 token 模型下，p=m3u / sub= / url= / 裸访问都是同一条规则。
mytv_require_token();

// 可选域名白名单（支持带端口的域名/IP）
// [mytv-token] 从下方 url= 分支上移到此处：并入的 sub= 分支也要用同一份白名单，
// 上移后全文件只有这一处定义。
$allowed_domains = [
    'php.jdshipin.com',
    'cdn12.jdshipin.com',
    'o11.163189.xyz',
    'cdn.163189.xyz',
    'cdn2.163189.xyz',
    'cdn3.163189.xyz',
    'cdn5.163189.xyz',
    'cdn6.163189.xyz',
    'cdn9.163189.xyz',
    '127.0.0.1',        // 示例：本地IP
    '192.168.1.100'     // 示例：内网IP
];

// 是否启用域名检查（false 表示允许任何域名/IP）
$enable_domain_check = false;

//订阅m3u列表
if ($p === 'm3u') {

$m3uurl = "https://cdn.qd.je/mytv0.m3u";

// === 使用 cURL 彻底解决超时和拦截问题 ===
$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, $m3uurl);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);
curl_setopt($ch, CURLOPT_IPRESOLVE, CURL_IPRESOLVE_V4); // 强制使用 IPv4
curl_setopt($ch, CURLOPT_TIMEOUT, 10); // 10 秒超时，快速失败
curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 5); // [mytv-token] 连不上就别耗满 10 秒
curl_setopt($ch, CURLOPT_USERAGENT, 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'); // 伪装浏览器

$m3u = curl_exec($ch);
$curl_error = curl_error($ch);
$curl_errno = curl_errno($ch); // 获取 cURL 错误号
curl_close($ch);

// 如果抓取失败，返回 503 状态码
if ($m3u === false || $curl_errno !== 0) {
    // 使用 PHP 内置函数设置 HTTP 状态码为 503
    http_response_code(503); 
    
    // 可选：告诉客户端或 CDN 在 60 秒后重试（对 503 状态码的良好实践）
    // header("Retry-After: 60"); 
    
    die("M3U Fetch Error (503): " . $curl_error);
}

// [mytv-token] 原基线的 preg_replace + 输出，改为共用的分块改写器：
// filter 由此对 p=m3u 生效，且每条自有链接都盖上请求者自己那枚 token
// （hostsub 语义与基线的 #http://[^/]+/mytv\.php# -> $path 一致，见 mytv_rewrite_playlist）。
header("Content-Type: text/plain; charset=utf-8");

echo mytv_rewrite_playlist($m3u, [
    'mode'      => 'hostsub',
    'path'      => $ENTRY_PATH,
    'base_root' => '',
    'base_dir'  => '',
    'token'     => $TOKEN,
    'kws'       => $kws,
    'own_host'  => $OWN_HOST,
    'unwrap'    => MYTV_UNWRAP_REMOTE_PROXY,
]);
exit;
}

/* ===== mytv-token begin: sub= 分支 ===== */
// 订阅/播放列表代理：原 php/sub.php 的功能并入本文件（token 版不再部署 sub.php，
// 否则会留下一个无认证入口）。
if ($SUB !== '') {

    // sub 必须是完整的 http(s) 地址：后面要靠它的 scheme/host 算 base_root，
    // 相对路径既没法代理也没法拼链接。
    $sub_scheme = parse_url($SUB, PHP_URL_SCHEME);
    if ($sub_scheme !== 'http' && $sub_scheme !== 'https') {
        header("HTTP/1.1 400 Bad Request");
        die("错误：sub 必须是完整的 http(s) 地址。\n"
            . "用法: /mytv.php?token=<你的token>&sub=<编码后的URL>（命令行里整条链接要加引号，\n"
            . "否则 & 会被 shell 当成后台执行符、命令从 & 处截断）");
    }

    $sub_host      = mytv_url_host($SUB);
    $sub_port      = parse_url($SUB, PHP_URL_PORT);
    $sub_host_port = $sub_port ? ($sub_host . ':' . $sub_port) : $sub_host;

    // 自引用拒绝：?sub= 指向本站会每层占住一个 php-fpm worker，pm.max_children=1
    // 时第二层就永远等不到空闲 worker —— 整站死锁，连 403 都发不出去。
    if ($sub_host !== '' && $sub_host === $OWN_HOST) {
        header("HTTP/1.1 400 Bad Request");
        die("错误：sub 指向本站自身，会占满 PHP worker 导致整站不可用。");
    }

    // SSRF 白名单（与 url= 分支共用同一组变量）
    if ($enable_domain_check && !in_array($sub_host, $allowed_domains) && !in_array($sub_host_port, $allowed_domains)) {
        header("HTTP/1.1 403 Forbidden");
        die('非法请求的域名');
    }

    // 构造请求头（防上游防盗链）：除 host / accept-encoding / x-forwarded-for 外，
    // 原样透传客户端请求头（沿用 sub.php 的策略）
    $sub_headers = [];
    foreach (getallheaders() as $name => $value) {
        $low_name = strtolower($name);
        if ($low_name !== 'host' && $low_name !== 'accept-encoding' && $low_name !== 'x-forwarded-for') {
            $sub_headers[] = "$name: $value";
        }
    }
    $sub_headers[] = "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36";
    $sub_headers[] = "Referer: " . $sub_scheme . "://$sub_host_port/";
    $sub_headers[] = "Accept-Encoding: gzip, deflate";

    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $SUB);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($ch, CURLOPT_MAXREDIRS, 5);
    curl_setopt($ch, CURLOPT_TIMEOUT, 30);
    curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 5); // [mytv-token]
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
    curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);
    curl_setopt($ch, CURLOPT_HTTPHEADER, $sub_headers);
    curl_setopt($ch, CURLOPT_ENCODING, ""); // 自动解压 gzip

    $response = curl_exec($ch);
    $sub_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    if ($response === false) {
        header("HTTP/1.1 502 Bad Gateway");
        die("无法获取目标 URL 的内容");
    }
    http_response_code($sub_code);

    // 是否播放列表：看内容有没有 #EXTM3U，或路径是不是 .m3u/.m3u8
    // （只看 path 而不是整个 URL：查询串里出现 ".m3u8" 不代表响应就是播放列表）
    $sub_path_for_ext = parse_url($SUB, PHP_URL_PATH);
    $sub_is_m3u = (stripos($response, '#EXTM3U') !== false)
        || preg_match('/\.m3u8?$/i', is_string($sub_path_for_ext) ? $sub_path_for_ext : '');

    if ($sub_is_m3u) {
        $sub_base_root = $sub_scheme . '://' . $sub_host . ($sub_port ? ':' . $sub_port : '');
        $sub_path      = parse_url($SUB, PHP_URL_PATH);
        if (!is_string($sub_path) || $sub_path === '') {
            $sub_path = '/';
        }
        $sub_base_dir = (substr($sub_path, -1) === '/')
            ? $sub_base_root . $sub_path
            : $sub_base_root . dirname($sub_path) . '/';

        $response = mytv_rewrite_playlist($response, [
            'mode'      => 'wrap',
            'path'      => $ENTRY_PATH,
            'base_root' => $sub_base_root,
            'base_dir'  => $sub_base_dir,
            'token'     => $TOKEN,
            'kws'       => $kws,
            'own_host'  => $OWN_HOST,
            'unwrap'    => MYTV_UNWRAP_REMOTE_PROXY,
        ]);
    }
    // 不是播放列表就原样透传：filter 忽略，不改写也不盖章

    // ================= 智能 Content-Type 判断 =================
    // 常规浏览器直接看纯文本，避免白屏；播放器给标准 m3u MIME
    $user_agent = isset($_SERVER['HTTP_USER_AGENT']) ? $_SERVER['HTTP_USER_AGENT'] : '';
    $is_browser = preg_match('/(Mozilla|Chrome|Safari|Firefox|Edge|Opera)/i', $user_agent)
                  && !preg_match('/(IPTV|Player|Kodi|VLC|TiviMate|Dalvik|okhttp)/i', $user_agent);

    if ($is_browser || isset($_GET['debug'])) {
        header('Content-Type: text/plain; charset=utf-8');
    } else {
        header('Content-Type: application/vnd.apple.mpegurl');
        header('Content-Disposition: inline; filename=playlist.m3u8');
    }

    echo $response;
    exit;
}
/* ===== mytv-token end: sub= 分支 ===== */

if (empty($request_url) && empty($p) && empty($SUB)) {
    // 参数全空却还有别的 GET 参数 → 极大概率是 URL 里的 & 被截断了
    // （沿用 sub.php 的判断；token 版多出 token/filter 两个参数，所以先排除 sub）
    if (count($_GET) > 1) {
        header("HTTP/1.1 400 Bad Request");
        die("错误：URL 参数可能被截断。请确保对 <URL> 进行了 URL 编码（特别是 & 和 ? 符号），或者使用 curl 测试。");
    }
    die('缺少 url 参数');
}

$parsed_url = parse_url($request_url);
$host = $parsed_url['host'] ?? '';
$port = isset($parsed_url['port']) ? ':' . $parsed_url['port'] : '';

// 构建完整的主机标识（包含端口）用于白名单检查
$host_with_port = $host . $port;
$host_without_port = $host;

if ($enable_domain_check) {
    // 检查是否在白名单中（支持带端口或不带端口）
    $is_allowed = in_array($host_without_port, $allowed_domains) || 
                  in_array($host_with_port, $allowed_domains);
    
    if (!$is_allowed) {
        die('非法请求的域名');
    }
}

// [mytv-token] 自引用拒绝：?url= 指向本站会自己代理自己，每层占住一个 php-fpm
// worker，pm.max_children=1 时第二层就等不到 worker —— 整站死锁。
if ($host !== '' && strtolower($host) === $OWN_HOST) {
    header("HTTP/1.1 400 Bad Request");
    die("错误：url 指向本站自身，会占满 PHP worker 导致整站不可用。");
}

// =================== TS 文件 Range 支持 ===================
if (preg_match('/\.ts$/i', $parsed_url['path'])) {
    // 初始化 cURL
    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $request_url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_HEADER, false);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
    curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);
    curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 5); // [mytv-token]

    // 支持 Range 请求
    if (isset($_SERVER['HTTP_RANGE'])) {
        curl_setopt($ch, CURLOPT_HTTPHEADER, ["Range: " . $_SERVER['HTTP_RANGE']]);
        http_response_code(206); // 部分内容
    } else {
        http_response_code(200);
    }

    $ts_data = curl_exec($ch);
    $curl_error = curl_error($ch);
    curl_close($ch);

    if ($ts_data === false) {
        die("CURL ERROR: " . $curl_error);
    }

    header('Content-Type: video/MP2T');
    header('Content-Length: ' . strlen($ts_data));
    if (isset($_SERVER['HTTP_RANGE'])) {
        header('Accept-Ranges: bytes');
    }
    echo $ts_data;
    exit();
}

// =================== 普通 m3u8 代理 ===================
// [mytv-token] getallheaders / str_starts_with / str_contains 的兼容定义已上移到文件顶部
// （并入的 sub= 分支也依赖它们，而那段代码在本行之前执行）。

// 构造请求头
$headers = [];
foreach (getallheaders() as $name => $value) {
    if (strtolower($name) !== 'host') {
        $headers[] = "$name: $value";
    }
}

// 构建 Host 头，包含端口（如果有）
$host_header = $host;
if (isset($parsed_url['port'])) {
    $host_header .= ':' . $parsed_url['port'];
}
$headers[] = "Host: $host_header";

// 构建 Referer，包含端口（如果有）
$referer_host = $host;
if (isset($parsed_url['port'])) {
    $referer_host .= ':' . $parsed_url['port'];
}
$headers[] = "User-Agent: AppleCoreMedia/1.0.0.7B367 (iPad; U; CPU OS 4_3_3 like Mac OS X)";
$headers[] = "Referer: " . $parsed_url['scheme'] . "://$referer_host/";
$headers[] = "Accept-Encoding: gzip, deflate";

// 发起请求
$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, $request_url);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_HEADER, true);
curl_setopt($ch, CURLOPT_FOLLOWLOCATION, false);
curl_setopt($ch, CURLOPT_HTTPHEADER, $headers);
curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);
curl_setopt($ch, CURLOPT_ENCODING, "");
curl_setopt($ch, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
curl_setopt($ch, CURLOPT_CONNECTTIMEOUT, 5); // [mytv-token]

// 对于 IP 地址，可能需要禁用 SSL 主机验证
if (filter_var($host, FILTER_VALIDATE_IP)) {
    curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, 0);
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, file_get_contents('php://input'));
}

$response = curl_exec($ch);
$curl_error = curl_error($ch);
$http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$header_size = curl_getinfo($ch, CURLINFO_HEADER_SIZE);
curl_close($ch);

// 拆分头和主体
$headers_raw = substr($response, 0, $header_size);
$body = substr($response, $header_size);

// 解析头
$response_headers = [];
foreach (explode("\r\n", $headers_raw) as $line) {
    if (stripos($line, 'HTTP/') === 0) {
        $response_headers[] = $line;
        continue;
    }
    $parts = explode(': ', $line, 2);
    if (count($parts) === 2) {
        $response_headers[strtolower($parts[0])] = $parts[1];
    }
}

// 重定向处理
if (in_array($http_code, [301, 302, 303, 307, 308]) && isset($response_headers['location'])) {
    $location = $response_headers['location'];
    if (!parse_url($location, PHP_URL_SCHEME)) {
        $base = $parsed_url['scheme'] . '://' . $parsed_url['host'];
        if (isset($parsed_url['port'])) {
            $base .= ':' . $parsed_url['port'];
        }
        $location = $base . '/' . ltrim($location, '/');
    }
    // [mytv-token] 出站盖章①：302 的 Location 也要带上 token，
    // 否则客户端跟过去的第一跳立刻 403（播放器通常不会重试）
    header('Location: ' . mytv_stamp('mytv.php?url=' . urlencode($location), $TOKEN), true, $http_code);
    exit();
}

// 设置 content-type
if (isset($response_headers['content-type'])) {
    header('Content-Type: ' . $response_headers['content-type']);
}

// 设置状态码
http_response_code($http_code);

// 出错输出
if ($response === false) {
    die("CURL ERROR: " . $curl_error);
}

// =================== m3u8 代理 ===================
$is_m3u8 = false;
$content_type = $response_headers['content-type'] ?? '';

if (
    strpos($request_url, '.m3u8') !== false ||
    stripos($content_type, 'mpegurl') !== false ||
    stripos($content_type, 'application/x-mpegurl') !== false ||
    strpos(ltrim($body), '#EXTM3U') === 0
) {
    $is_m3u8 = true;
}

if ($is_m3u8) {
    // 构建基础 URL，包含端口
    $base_root = $parsed_url['scheme'] . '://' . $parsed_url['host'];
    if (isset($parsed_url['port'])) {
        $base_root .= ':' . $parsed_url['port'];
    }

    $path = $parsed_url['path'] ?? '/';
    if (substr($path, -1) === '/') {
        $base_dir = $base_root . $path;
    } else {
        $base_dir = $base_root . dirname($path) . '/';
    }

    // ================= m3u8 安全逐行解析 =================
    $lines = preg_split("/\r\n|\n|\r/", $body);
    $out   = [];

    // [mytv-token] 「已代理的行」盖章时用的判据集（见盖章②/④：只给自有链接盖章）
    $stamp_opts = [
        'path'     => $ENTRY_PATH,
        'own_host' => $OWN_HOST,
        'token'    => $TOKEN,
    ];

    foreach ($lines as $rawLine) {
        $line = rtrim($rawLine);

        if ($line === '') {
            $out[] = $rawLine;
            continue;
        }

        // 处理 URI="..." 行
        if ($line[0] === '#' && stripos($line, 'URI="') !== false) {
            $line = preg_replace_callback(
                '/URI="([^"]+)"/i',
                function ($m) use ($base_root, $base_dir, $TOKEN, $stamp_opts) {
                    $uri = $m[1];

                    // [mytv-token] 出站盖章②：已代理的行不能原样返回。上游或旧 playlist
                    // 里可能烙着已吊销的旧 token，必须剥旧盖新，否则二次分发后立刻 403。
                    // 只给自有链接盖章：别站的 mytv.php?url= 代理链接不需要我们的 token
                    // 也能用，给它盖章等于把凭据写进第三方服务器的访问日志。
                    //
                    // 判据用 mytv_is_proxy_link 而不是字面量 'mytv.php?url='：
                    // 本版盖章后是 mytv.php?token=…&url=…，token 在前面，字面量匹配不到，
                    // 自己发出去的链接回灌进来就会被当成普通相对路径、拼出坏链接。
                    $proxied = null;
                    if (mytv_is_proxy_link($uri, $proxied)) {
                        return 'URI="' . mytv_stamp_own($uri, $stamp_opts) . '"';
                    }

                    if (preg_match('#^https?://#i', $uri)) {
                        $url = $uri;
                    } elseif (str_starts_with($uri, '/')) {
                        $url = $base_root . $uri;
                    } else {
                        $url = $base_dir . $uri;
                    }

                    // [mytv-token] 出站盖章③
                    return 'URI="' . mytv_stamp('mytv.php?url=' . urlencode($url), $TOKEN) . '"';
                },
                $line
            );

            $out[] = $line;
            continue;
        }

        // 其它 EXT 行原样保留
        if ($line[0] === '#') {
            $out[] = $line;
            continue;
        }

        // 已代理的不重复处理（判据同盖章②：不能写字面量 'mytv.php?url='）
        $proxied = null;
        if (mytv_is_proxy_link($line, $proxied)) {
            // [mytv-token] 出站盖章④：改成剥旧盖新（基线这里是原样返回）。
            // 同样只给自有链接盖章，理由见盖章②。
            $out[] = mytv_stamp_own($line, $stamp_opts);
            continue;
        }

        // 普通资源行
        if (preg_match('#^https?://#i', $line)) {
            $url = $line;
        } elseif (str_starts_with($line, '/')) {
            $url = $base_root . $line;
        } else {
            $url = $base_dir . $line;
        }

        // [mytv-token] 出站盖章⑤
        $out[] = mytv_stamp('mytv.php?url=' . urlencode($url), $TOKEN);
    }

    $body = implode("\n", $out);
    header('Content-Disposition: inline; filename=index.m3u8');
}

echo $body;
?>
