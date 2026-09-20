<?php
/**
 * sub.php (终极优化版)
 * 解决浏览器白屏、URL参数截断问题
 */

// 兼容低版本 PHP 辅助函数
if (!function_exists('str_starts_with')) {
    function str_starts_with($haystack, $needle) {
        return $needle !== '' && strncmp($haystack, $needle, strlen($needle)) === 0;
    }
}
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

// 1. 获取目标 URL 参数 (防截断处理)
$request_url = isset($_GET['url']) ? urldecode($_GET['url']) : '';

if (empty($request_url)) {
    // 如果 url 为空，但存在其他 GET 参数，极大概率是 URL 中的 & 被截断了
    if (count($_GET) > 1) {
        header("HTTP/1.1 400 Bad Request");
        die("错误：URL 参数可能被截断。请确保在浏览器地址栏测试时，对 <URL> 进行了 URL 编码（特别是 & 和 ? 符号），或者使用 curl 测试。");
    }
    header("HTTP/1.1 400 Bad Request");
    die("缺少 url 参数。用法: sub.php?url=<编码后的URL>");
}

// 2. SSRF 安全校验 (按需开启)
$allowed_domains = [];
$enable_domain_check = false; 
$parsed_url = parse_url($request_url);
$host = $parsed_url['host'] ?? '';
$port = isset($parsed_url['port']) ? ':' . $parsed_url['port'] : '';

if ($enable_domain_check && !in_array($host, $allowed_domains) && !in_array($host . $port, $allowed_domains)) {
    header("HTTP/1.1 403 Forbidden");
    die('非法请求的域名');
}

// 3. 构造请求头 (防上游防盗链)
$headers = [];
foreach (getallheaders() as $name => $value) {
    $low_name = strtolower($name);
    if ($low_name !== 'host' && $low_name !== 'accept-encoding' && $low_name !== 'x-forwarded-for') {
        $headers[] = "$name: $value";
    }
}
$headers[] = "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36";
$headers[] = "Referer: " . ($parsed_url['scheme'] ?? 'http') . "://$host$port/";
$headers[] = "Accept-Encoding: gzip, deflate";

// 4. cURL 请求
$ch = curl_init();
curl_setopt($ch, CURLOPT_URL, $request_url);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
curl_setopt($ch, CURLOPT_MAXREDIRS, 5);
curl_setopt($ch, CURLOPT_TIMEOUT, 30);
curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);
curl_setopt($ch, CURLOPT_HTTPHEADER, $headers);
curl_setopt($ch, CURLOPT_ENCODING, ""); // 自动解压 gzip

$response = curl_exec($ch);
$http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($response === false) {
    header("HTTP/1.1 502 Bad Gateway");
    die("无法获取目标 URL 的内容");
}
http_response_code($http_code);

// 5. 构造代理前缀
$scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
$proxy_base = $scheme . '://' . $_SERVER['HTTP_HOST'];
$proxy_prefix = $proxy_base . '/mytv.php?url=';

// 6. 解析 m3u 内容
$is_m3u = (stripos($response, '#EXTM3U') !== false) || preg_match('/\.m3u8?$/i', $request_url);

if ($is_m3u) {
    $base_root = ($parsed_url['scheme'] ?? 'http') . '://' . $host . $port;
    $path = $parsed_url['path'] ?? '/';
    $base_dir = (substr($path, -1) === '/') ? $base_root . $path : $base_root . dirname($path) . '/';

    $lines = preg_split("/\r\n|\n|\r/", $response);
    $out = [];

    foreach ($lines as $rawLine) {
        $line = rtrim($rawLine);
        if ($line === '') { $out[] = $rawLine; continue; }

        // 处理 URI="..."
        if (str_starts_with($line, '#') && stripos($line, 'URI="') !== false) {
            $line = preg_replace_callback(
                '/URI="([^"]+)"/i',
                function ($m) use ($base_root, $base_dir, $proxy_prefix) {
                    $uri = $m[1];
                    if (strpos($uri, $proxy_prefix) !== false) return 'URI="' . $uri . '"';
                    if (preg_match('#^https?://#i', $uri)) $url = $uri;
                    elseif (str_starts_with($uri, '/')) $url = $base_root . $uri;
                    else $url = $base_dir . $uri;
                    return 'URI="' . $proxy_prefix . urlencode($url) . '"';
                },
                $line
            );
            $out[] = $line; continue;
        }

        if (str_starts_with($line, '#')) { $out[] = $line; continue; }
        if (strpos($line, $proxy_prefix) !== false) { $out[] = $line; continue; }

        if (preg_match('#^https?://#i', $line)) $url = $line;
        elseif (str_starts_with($line, '/')) $url = $base_root . $line;
        else $url = $base_dir . $line;
        
        $out[] = $proxy_prefix . urlencode($url);
    }
    $response = implode("\n", $out);
}

// ================= ⭐ 核心优化：智能 Content-Type 判断 =================
// 判断请求是否来自常规浏览器 (Chrome, Safari, Firefox 等)
// 如果来自浏览器，或者 URL 中带了 debug=1 参数，则输出纯文本，防止浏览器白屏
$user_agent = $_SERVER['HTTP_USER_AGENT'] ?? '';
$is_browser = preg_match('/(Mozilla|Chrome|Safari|Firefox|Edge|Opera)/i', $user_agent) 
              && !preg_match('/(IPTV|Player|Kodi|VLC|TiviMate|Dalvik|okhttp)/i', $user_agent);

if ($is_browser || isset($_GET['debug'])) {
    // 浏览器调试模式：输出纯文本，浏览器会直接显示代码，不会白屏
    header('Content-Type: text/plain; charset=utf-8');
} else {
    // 播放器模式：输出标准 m3u MIME 类型，确保 IPTV 软件能正确识别
    header('Content-Type: application/vnd.apple.mpegurl');
    header('Content-Disposition: inline; filename=playlist.m3u8');
}
// =======================================================================

echo $response;
?>
