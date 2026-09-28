# mytv PHP 版 token 认证方案（v7：单层稳定 token · 双端点过滤 · 极简两文件）

> **v2** 推翻 v1 的"nginx map + PHP 权威判定"混合架构 → PHP 全实现，nginx 零改动。
> **v3** 主仓现有文件零改动，token 版全部内容放新目录 `token/`，自带独立 `install.sh`。
> **v4** 开关与稳定 token 收进 PHP 配置块，删掉 enforce/stable_tokens/env 三个数据文件与管理子命令。
> **v5** `sub=` 并入 `mytv.php`（不再部署 sub.php）；临时 token 改 HMAC 时间窗（无状态）→ 移除 cron 与轮换脚本；`install.sh` 委托主安装器而非 fork。
> **v6** `$MYTV_AUTH` 默认开启；`sub=` 输出全量盖章（含 `#EXTM3U` 头部 `url-tvg=`）；`sub=` 新增 `filter=A,B`。
> **v7（本版）**
> ① **`p=m3u` 也支持 `filter`**（与 `sub=` 共用同一套分块解析/过滤/改写器）；
> ② **放弃临时 token，全部改用稳定 token** → HMAC/secret/时间窗/`MYTV_TEMP_*`/"盖章即续命"/"换 secret 全撤销"/时钟跳变风险/`hash_hmac`+`intdiv` 依赖 **全部删除**；
> ③ **稳定 token 数组移出源码，放 `/etc/mytv/tokens.php`**（`return [...]`）→ `mytv.php` 与仓库文件**逐字节一致**，install.sh 里的 `sed` 注入与 `awk` 配置块跨升级保留机制**整体删除**，且开关不再位于 docroot（Web 层改不到）；
> ④ **盖章 = 请求者自己那枚 token**（明文来自 `$_GET['token']`，全哈希存储不变，零额外配置）→ 单层模型，**端点矩阵消失**（任何端点都只要求"一枚有效 token"），且"拿不到 token 可盖 → 503"的 fail-closed 分支不再存在。
>
> 最终形态：**仓库 3 个文件（`mytv.php` / `install.sh` / `README.md`），服务器 2 个产物（`mytv.php` + `/etc/mytv/tokens.php`）。零后台进程、零 cron、零数据表、零密钥、零 reload、零 sed/awk 注入。**

## Context

现状：`php/mytv.php` + `php/sub.php` 由 `nginx/{debian,alpine}/php-site.conf` 解析，**完全没有认证**——任何知道地址的人都能用 `?url=` 把服务器当开放代理、用 `?p=m3u` 取整份订阅。仓库历史上的 token 只存在于反代版 `nginx/nginx.conf`（单一硬编码 `"mytv123"`）。

目标：给 PHP 版加上 token 认证（**默认开启**）与订阅过滤能力。不改动主仓任何现有文件；install.sh 生成一枚稳定 token 并唯一一次打印；重跑主 `php/install.sh` 即回退无认证版。

### 已确认的决策
| 项 | 结论 |
|---|---|
| **布局** | 新目录 `token/`，主仓现有文件**零改动**（含未跟踪的 `nginx/token/auth_tokens.example.conf`，保留并在 token/README 标注为无关旧物） |
| **认证实现层** | PHP 全实现，nginx 配置零改动（站点配置仍用主仓 `nginx/{debian,alpine}/php-site.conf` 原样） |
| **应用文件** | 只有 `mytv.php` 一个；`sub=` 逻辑并入其中；**不部署 `sub.php`**（老链接迁移到 `?sub=`，README 附可选 2 行兼容存根） |
| **token 模型** | **单层稳定 token**：一枚 token 可访问全部端点；无临时 token、无过期、无轮换。吊销 = 从数组里删一行（即时生效） |
| **配置位置** | `/etc/mytv/tokens.php`（`return ['auth'=>…, 'tokens'=>[…]]`，0640 root:\<phpgroup\>）。`mytv.php` 里只有一行常量 `$MYTV_TOKENS_FILE`，**永不需要编辑** → 应用文件与仓库逐字节一致 |
| **token 存储形态** | 数组键 = `sha256(token)` 的 hex，值 = **人类可读标签**（如 `'客厅电视'`，仅用于管理员辨认，不参与判定）。全哈希、无明文 |
| **默认开关** | `'auth' => true`（**默认开启**，secure by default）。tokens.php 缺失/不可读/语法错/非数组 → **503 + 自解释提示**（配置错误，区别于 403 未授权），绝不裸奔 |
| **端点规则** | 单层 → **无矩阵**：`auth=true` 时任何请求都必须带一枚有效 token（`p=m3u`/`sub=`/`url=`/裸访问一视同仁）；`auth=false` → 完全放行，行为与现状逐字节一致（且**不盖章**） |
| **playlist 盖章** | `p=m3u` 与 `sub=` 输出中的**每条自有链接**都盖**请求者自己那枚 token**（明文取自 `$_GET['token']`）：资源行、`URI="…"` 属性、已代理行（剥旧盖新）、**`#EXTM3U` 头部的 `url-tvg=`/`x-tvg-url=` 属性**（不盖则 EPG 拉取 403、节目单全空）。第三方直连 URL 不盖（等于把凭据送给源站） |
| **过滤** | `filter=A,B`（英文逗号分隔，容忍全角 `，`）：按**节目名称**子串匹配，任一命中即保留；大小写不敏感（`stripos` 字节匹配，CJK 安全，**不依赖 mbstring**）；**`p=m3u` 与 `sub=` 都支持** |
| 安装器 | `token/install.sh`：阶段 1 委托主 `php/install.sh`（幂等），阶段 2 token 化（~60 行）；`MYTV_SKIP_BASE=1` 跳过阶段 1；`MYTV_TOKEN=0` 只做阶段 1 |
| 回退路径 | 重跑 `MYTV_REF=main sh php/install.sh`（覆盖回无认证版；tokens.php 留着无害，回退即彻底） |
| 文档 | `token/README.md` 独立成篇（含 tokens.php 模板，不另设 example 文件），主 README 不动 |
| 日志脱敏 | 不做，README 提示 access.log 会含 token |

---

## v7 的两项取舍（诚实记录）

### 放弃临时 token 的代价
v6 的临时 token（HMAC 时间窗、TTL 12h）存在的唯一理由是：**playlist 会被到处转发，印在里面的凭据应当会自己过期**。改成单层稳定 token 后：
- playlist 里印的是**请求者自己那枚永久凭据**，转发出去 = 把该用户的全部权限（含 `p=m3u`/`sub=` 订阅）永久交出去，**直到你手工删掉那一行**。
- 缓解：① 每人/每设备一枚 + 标签，泄露后能定位并单独吊销，不牵连他人；② 删行即时生效（无需 reload/无需等服务动作）；③ README 首屏写明"playlist 链接等同凭据，不要公开分享"。
- 换来的收益：secret 文件、时间窗算术、25 窗口并存、错峰轮换、"盖章即续命"、时钟跳变语义、`hash_hmac`/`intdiv` 依赖、以及"secret 丢失 = 全部临时 token 失效"这条故障模式——**全部消失**；盖章逻辑退化为"把请求里那枚 token 原样印进去"，不可能失败。
- 若将来要恢复"可转发的播放凭据"分层：把数组值从标签字符串改成 `['level'=>1,'name'=>'…']`，helper 恢复 `need` 判定即可（一处改动，设计已留在 git 历史的 v6）。

### 配置移出源码的收益（回答"放 PHP 数组里是否合适"）
**数组是合适的数据结构**（条目几条到几十条，`include` 一次、O(1) 键查找、无解析代码、无格式错误风险、改完 2 秒生效）；**放在 `mytv.php` 源码里不合适**：
1. install.sh 必须 `sed` 注入生成的哈希 → 部署文件不再与仓库一致（SHA 校验/`diff` 失效）；
2. 每次升级必须 `awk` 抽出旧文件的配置块覆盖回来，否则用户的 token 被打回占位符（默认开启认证后 = 直接锁死）；
3. 改 token 就是在改应用代码，手滑能改坏站点；备份文件还落在 docroot 里。
移到 `/etc/mytv/tokens.php` 后：以上三条全部消失，且**开关（`auth`）不再位于 docroot**——`mytv.php` 是 root:root 0644、`tokens.php` 是 root:root 0640，**php-fpm 被攻破也改不了认证开关、加不了自己的 token**（v6 把 `$MYTV_AUTH` 放在 docroot 源码里时做不到这一点）。代价只有一个 0640 文件，而它同时替代了 v6 的 docroot 备份产物。

---

## 认证链路

```
客户端 ──?p=m3u&filter=翡翠台&token=<稳定>──▶ mytv.php: sha256(token) 命中 tokens 数组 → 放行
                                   └─ 抓上游 → 分块过滤 → 每条自有链接盖"请求者自己那枚" token
客户端 ──?sub=<远端m3u>&filter=A,B&token=<稳定>──▶ 同上（含头部 url-tvg 盖章、第三方代理行解包成单跳）
客户端 ──?url=<m3u8>&token=<稳定>──▶ 命中 → 放行；重写子链接时**剥旧盖新**（换掉上游/旧playlist 里的 token 参数）
（无 cron、无表、无密钥、无 reload：token 是人工签发的稳定值，判定就是一次数组键查找）
```

**开关与失效语义**：`auth=false` → 完全放行且不盖章（与现状逐字节一致）；`auth=true` 而 tokens.php 缺失/不可读/`include` 抛错/返回非数组 → **503 + 提示**（fail closed）；`auth=true` 而数组为空 → 同样 503（未签发任何凭据）。改 tokens.php 后 opcache 默认 2s 内生效。

## 配置模型（/etc/mytv/tokens.php，0640 root:\<phpgroup\>）

```php
<?php
// 由 token/install.sh 生成；手动部署照抄本模板。改完即生效（opcache 默认 2s）。
return [
    'auth'   => true,          // 总开关：false = 完全放行（与无认证版行为一致）
    'tokens' => [
        // 键 = sha256(token) 的 hex（生成: printf '%s' '你的token' | sha256sum）
        // 值 = 人类可读标签，仅供管理员辨认（吊销时知道删哪行），不参与判定
        '3a5f9c…' => '我的订阅',
        '9c1142…' => '客厅电视',
        // token 约束：小写 [a-z0-9]、长度 8~40；大小写敏感（PHP 字节比较）
    ],
];
```
`mytv.php` 里只有 `$MYTV_TOKENS_FILE = '/etc/mytv/tokens.php';` 一行常量，永不需要编辑。

## 部署物全集

```
服务器上：
  /var/www/html/mytv.php     ← root:root 0644，与仓库 token/mytv.php 逐字节一致（sha256 可比对）
  /etc/mytv/tokens.php       ← root:root 0640，目录 0710 root:<phpgroup>
  （nginx 站点配置 = 主仓 php-site.conf 原样；无 sub.php、无 cron、无 secret、无数据表）
仓库里：
  token/{mytv.php, install.sh, README.md}
```

---

## 文件改动清单

### 1. `token/mytv.php`（fork 自 `php/mytv.php`，唯一应用文件）
**顶部插入配置常量 + helper**，用 `===== mytv-token begin/end =====` 标记包裹（同步上游时整块搬移）：

```php
/* ===== mytv-token begin ===== */
$MYTV_TOKENS_FILE = '/etc/mytv/tokens.php';   // 唯一需要知道的配置入口（永不需要编辑本文件）
/* helper（function_exists 守卫）：mytv_cfg / mytv_auth_on / mytv_misconfigured /
   mytv_token_ok / mytv_require_token / mytv_deny / mytv_stamp /
   mytv_filter_keywords / mytv_entry_matches / mytv_rewrite_playlist */
/* ===== mytv-token end ===== */
```

helper 语义：
- `mytv_cfg()`：静态缓存一次读取——`try { $c = include $MYTV_TOKENS_FILE; } catch (\Throwable $e) { $c = false; }`；`is_array($c) ? $c : false`。（`include` 一个语法错误的文件在 PHP7+ 抛 `ParseError`，可捕获 → 不会白屏 500。）
- `mytv_auth_on()`：`mytv_cfg()` 为数组且 `!empty($c['auth'])`。
- `mytv_misconfigured()`：`auth` 开而 cfg 读取失败 / `tokens` 非数组或为空 → **503** + 单行提示（"认证已开启但 /etc/mytv/tokens.php 缺失/不可读/为空"）+ exit。**与 403 区分：这是管理员配置错误，不是攻击者未授权。**
- `mytv_token_ok($tok)`：`$tok !== '' && isset($c['tokens'][hash('sha256', $tok)])`。**O(1) 键查找**（被查的是用户输入的 sha256，哈希表时序不泄露可用信息——攻击者没有原像就无法利用）。
- `mytv_require_token()`：`mytv_misconfigured()` 先行，再 `auth_on && !mytv_token_ok($_GET['token'] ?? '') → mytv_deny()`。
- `mytv_deny()`：403 + 单行说明 + exit。
- `mytv_stamp($url, $tok)`：`auth_on` 且 `$tok !== ''` 时，**先剥离该 URL 已有的 `token=` 参数再追加**（防重复盖章、防沿用已吊销的旧值）；`auth=false` 时**原样返回不盖章**（保证与现状逐字节一致）。
- `mytv_filter_keywords($raw)`：按 `,` 拆分（**容忍全角 `，`**）→ `trim` → 去空去重；上限 20 个、每个 ≤ 64 字节（超限截断，防病理输入）；空输入 → `[]`（不过滤）。
- `mytv_entry_matches($block, $kws)`：`$kws` 空 → true；否则取块内 `#EXTINF` 行的**名称**（最后一个逗号之后的部分）与 `tvg-name="…"` 属性值，任一 `stripos(名称, kw) !== false` 即 true。**不用 mbstring**：`stripos` 二进制安全，UTF-8 多字节（≥0x80）不参与大小写折叠，中文子串匹配正确、ASCII 大小写不敏感。
- `mytv_rewrite_playlist($body, $opts)`：**`p=m3u` 与 `sub=` 共用**的分块解析 + 过滤 + 改写 + 盖章器。`$opts`：`mode`（`hostsub` = p=m3u 的"替换 host"语义 / `wrap` = sub= 的"包装成本站代理"语义）、`path`（本站入口前缀，来自 `SCRIPT_NAME`）、`base_root`/`base_dir`（wrap 模式解析相对路径用）、`token`（请求者自己那枚）、`kws`（过滤关键字）。行为：
  - `#EXTM3U` 头部行**永远保留**（是列表头不是内容），但其中 `url-tvg="…"`/`x-tvg-url="…"` 属性里的**自有链接同样剥旧盖新**；
  - 其余按"条目块"处理：连续 `#` 行 + 紧随的一行 URL = 一块，`filter` 生效时整块去留（**EXTINF 与其 URL 同去同留**，否则产出孤行或错配）；块内无 `#EXTINF`（无名称可匹配）→ 过滤时丢弃；
  - `hostsub` 模式（p=m3u）：沿用基线语义 `#http://[^/]+/mytv\.php#` → `$path`（单跳直达），然后 `mytv_stamp()`；非自有链接不动、不盖章；
  - `wrap` 模式（sub=）：`URI="…"` 属性与资源行分别处理；相对路径按 `base_root`/`base_dir` 解析为绝对 → 包成 `mytv.php?url=<encoded>` → `mytv_stamp()`；**已是本站代理的行剥旧盖新**（不能原样返回）；**是别站 `mytv.php?url=` 的行**（用户示例正是这种形态）→ **解包内层 url 重建为本站单跳**再盖章，避免双跳套娃与依赖他人服务器；该行为由 `$MYTV_UNWRAP_REMOTE_PROXY`（默认 true，配置常量）控制，设 false 退回"原样包一层"（stock sub.php 行为）。

对基线的改动点（行号按 `php/mytv.php` 现版，实现以 fork 后为准）：
1. 顶部（第 6 行后）取 `$SUB = $_GET['sub'] ?? ''`、`$FILTER = $_GET['filter'] ?? ''`、`$TOKEN = $_GET['token'] ?? ''`、`$kws = mytv_filter_keywords($FILTER)`。
2. **入口处一次判定**（取代 v6 的端点矩阵——单层模型下所有端点同规则）：在第 9 行 `p=m3u` 分支**之前**插入 `mytv_require_token();`。这一处即覆盖 `p=m3u`、`sub=`、`url=`、裸访问与任何未知参数组合。
3. `p=m3u` 分支：抓取逻辑（基线 18-44 行）不动；**替换基线 46-54 行**的 `preg_replace`+输出为 `echo mytv_rewrite_playlist($m3u, ['mode'=>'hostsub', 'path'=>$path, 'token'=>$TOKEN, 'kws'=>$kws]);`（`filter` 由此对 `p=m3u` 生效）。
4. 第 58 行 `if (empty($request_url) && empty($p))` **之前**插入 `sub=` 分支：吸收 `php/sub.php` 的 51-152 行（防链头 → cURL `FOLLOWLOCATION`/`MAXREDIRS 5`/`TIMEOUT 30` → `#EXTM3U` 或 `.m3u8?` 判定 → 浏览器 UA 决定 Content-Type），playlist 改写统一交给 `mytv_rewrite_playlist(…, ['mode'=>'wrap', …])`；非 playlist 响应原样透传（`filter` 忽略、不改写不盖章）；`filter` 无命中 → 仅输出 `#EXTM3U` 头 + 200（空列表不报错）。
5. `url=` 路径的出站盖章共 **4 处**：基线 242（302 Location）、317（`URI="`）、347（资源行）+ **305 / 333 两处"已代理就原样返回"改成"剥旧盖新"**（`mytv_stamp`）。
6. `sub=` / `url=` 入口加**自引用拒绝**（目标 host 与 `HTTP_HOST` 忽略大小写相等即 400）：`?sub=` 指向本站会每层占一个 php-fpm worker，`pm.max_children=1` 时 2 层死锁整站。顺带给各 cURL 补 `CURLOPT_CONNECTTIMEOUT 5`。
7. `$path` 改用 `$_SERVER['SCRIPT_NAME']` 而非 `PHP_SELF`（第 15 行）：`PHP_SELF` 带 `PATH_INFO`，而 `$path` 是盖章与 hostsub 的判据。

### 2. `token/install.sh`（~60 行，不 fork 主脚本）
`#!/bin/sh` + `set -e`。环境变量：`MYTV_REF`（默认 **token** 分支）、`MYTV_SKIP_BASE=1`（跳过阶段 1）、`MYTV_TOKEN=0`（只做阶段 1 = 等价主脚本，token/mytv.php 404 时的应急退路）、`SHA_MYTV_PHP`（**部署文件与仓库逐字节一致，SHA 校验现在覆盖最终产物**）。
- **阶段 1（基础安装，委托）**：`curl -fsSL "$REPO_RAW/php/install.sh" | MYTV_REF="$MYTV_REF" sh`（主脚本幂等：装 nginx/php-fpm、写 fpm 地址、装站点 conf 含备份与 `nginx -t` 回滚、部署 PHP、自检）。
- **阶段 2（token 化，v7 大幅缩短——无 sed 注入、无 awk 保留、无备份、无 secret、无 cron）**：
  1. `fetch token/mytv.php → /var/www/html/mytv.php`（自带精简版 fetch ~25 行：`.`前缀临时文件 + `<?php` 头校验 + 可选 SHA + 原子 mv），部署为 **root:root 0644**（偏离主脚本的 chown web 属主，有意为之：PHP 只需读，堵死"Web 层改写认证逻辑"）。**配置在别处，覆盖安装天然安全，无需备份。**
  2. `rm -f /var/www/html/sub.php`（token 版不提供；阶段 1 刚部署的那份必须清掉，否则留下一个无认证入口）。
  3. `mkdir -p /etc/mytv`（0710 root:\<phpgroup\>；组名探测 `stat -c %G /var/www/html/mytv.php`，失败按 OS 取 www-data/nginx）；**幂等生成 `/etc/mytv/tokens.php`**（已存在且 `php -r 'var_dump(is_array(include …));'` 为真 → 绝不改动、绝不重复打印）：生成 20 hex 随机 token（熵源 `/proc/sys/kernel/random/uuid` > `dd + od -tx1` > `sha256sum` 混熵，不依赖 openssl）→ 写入 `'auth'=>true` + 该 token 的 sha256（标签 `'install-generated'`）→ `chmod 0640` → **唯一一次打印明文**（提示"立刻保存，服务器只存哈希，丢了只能重新生成"）。
  4. **自检（token 感知）**：裸请求 `curl /mytv.php` **期望 403**；`curl "/mytv.php?token=<刚生成的>"` **期望 200**（返回"缺少 url 参数"页，不触外网、最便宜的通过性探针）；503 → tokens.php 未生成成功/权限不对（打印排查提示）；502/504 → 沿用主脚本的 fpm 地址口径提示。
  5. 横幅：稳定 token（若本次生成）、tokens.php 路径与"加人/封人"一行示例（`printf '%s' 'token' | sha256sum` → 编辑数组）、`filter=` 用法示例、回退方法、**强烈建议**打开 php-site.conf 的 `limit_req`、SSRF 三段口径。

### 3. `token/README.md`（独立文档，主 README 不动；tokens.php 模板内嵌于此，不另设 example 文件）
内容：token 模型一段（单层稳定 token、无过期、**playlist 链接等同凭据**）、**默认开启**语义（install 装完即可用、token 只打印一次；手动部署未建 tokens.php = 全站 503 且提示自解释）、tokens.php 模板与字段说明、加人/封人流程（sha256 生成 + 删行即吊销 + 大小写敏感 + opcache 2s 生效 + `validate_timestamps=0` 的用户需 reload fpm）、**`filter=` 用法专节**（语法、匹配规则=EXTINF 名称兼 tvg-name 子串、大小写不敏感、多关键字 OR、全角逗号容忍、无命中=空列表 200、`p=m3u` 与 `sub=` 都支持、20 个/64 字节上限、无正则/无排除语法），示例用用户给的真实形态：
```
# 只看翡翠台与凤凰中文
http://<服务器>/mytv.php?sub=http%3A%2F%2F<上游>%2Fmytv.m3u&filter=%E7%BF%A1%E7%BF%A0%E5%8F%B0,%E5%87%A4%E5%87%B0%E4%B8%AD%E6%96%87&token=<你的token>
http://<服务器>/mytv.php?p=m3u&filter=%E7%BF%A1%E7%BF%A0%E5%8F%B0&token=<你的token>
# 输出（自有链接都带上你自己那枚 token，头部 url-tvg 也已盖章）：
#EXTM3U url-tvg="http://<服务器>/mytv.php?url=https%3A%2F%2Fepg…&token=<你的token>" …
#EXTINF:-1 tvg-name="翡翠台" group-title="mytv",翡翠台4K(字幕)
http://<服务器>/mytv.php?url=https%3A%2F%2Fcdn3.indevs.in%2Fstream%2Ftvb%2Ffct4k%2F&token=<你的token>
```
另含：`?sub=` 迁移指引（老 `sub.php?url=X` → `mytv.php?sub=X`）与可选 2 行兼容存根、`$MYTV_UNWRAP_REMOTE_PROXY` 开关说明、手动部署等价命令全套（不跑 install.sh 的纯手工路径）、开启后 3 条 curl 自检、故障排查（全 403 → 哈希粘错/大小写不符；全站 503 → tokens.php 缺失或权限不对；playlist 没 token → `auth` 为 false；EPG 无节目单 → 头部 url-tvg 未盖章的旧版本）、**与主仓版本的关系与同步方法**（标记块外 diff = 上游漂移）。
已知问题小节（只记录不修）：主 README:14 硬编码行号、`README.md:172-174`/`install.sh:454` 的 60s vs 120s 陈旧值、`nginx/nginx.conf` 死码 map、`nginx/token/auth_tokens.example.conf` 为无关旧物。
**SSRF 三段式口径**：(a) `?url=` 可代理任意地址这一事实未变；(b) token 挡的是全网扫描器/白嫖，但**任何拿到一枚 token 的人永久可用它做开放代理，直到你删掉那一行**；(c) 真收紧：`mytv.php:63-96` 的 `$enable_domain_check` 域名白名单 + `limit_req` + allow/deny。

### 4. 现有文件：**零改动**
`php/*`（含 `sub.php`、`install.sh`）、`README.md`、`nginx/**` 全部原样。

---

## 验证

```sh
# 0) 静态与单元验证（无 cron、无表、无密钥、无 nginx）
docker run --rm -v $PWD:/w -w /w php:8.3-cli php -l token/mytv.php
docker run --rm -v $PWD:/w -w /w alpine:3.20   php -l token/mytv.php   # 确认无 mbstring 依赖
docker run --rm -v $PWD:/w -w /w debian:bookworm-slim dash -n token/install.sh
# 过滤/匹配单测（php -r 直接调 helper）：
#   '翡翠台,凤凰中文' → 2 个关键字；'翡翠台，凤凰中文'（全角）→ 同；' a , ,b ' → [a,b]；>20 个 → 截断
#   '…tvg-name="翡翠台" …,翡翠台4K(字幕)' 对 '翡翠台' → true；对 '凤凰' → false
#   'TVB Jade' 对 'tvb' → true（ASCII 大小写不敏感）
#   tokens.php 语法错误 → mytv_cfg() 返回 false（不 500 白屏）；返回非数组 → 同

# 1) curl 断言矩阵（主仓 php-site.conf 原样 + nginx:1.26 + php:8.3-fpm；
#    部署 token/mytv.php 原样 + tokens.php 内含 S1、S2 两枚）
code() { curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 "$1"; }
code .../mytv.php                          # 403  deny-by-default（默认开启）
code .../mytv.php?token=S1                 # 200  通过认证（"缺少 url 参数"页，不触外网）
code .../mytv.php?url=x                    # 403
code .../mytv.php?url=x&token=S1           # ≠403
code .../mytv.php?url=x&token=wrong        # 403
code .../mytv.php?p=m3u&token=S1           # 200，body 每条自有链接都含 &token=S1
code .../mytv.php?%70=m3u&token=wrong      # 403  键名编码：$_GET 解码后仍是 m3u，无 token 照拒
code .../mytv.php?url=x&token=S1&p=m3u     # ≠403  单层模型：任何端点同一规则（对照 v6 的 403）
code .../sub.php?url=x                     # 404  token 版不部署 sub.php（迁移断言）
# 盖章 = 请求者自己那枚（v7 核心断言）：
curl ".../mytv.php?p=m3u&token=S1" | grep -c "token=$S1"   # >0
curl ".../mytv.php?p=m3u&token=S1" | grep -c "token=$S2"   # 0
curl ".../mytv.php?p=m3u&token=S2" | grep -c "token=$S2"   # >0
# 吊销即时生效：从 tokens.php 删掉 S2 → 立刻 curl 带 S2 的 playlist 链接 → 403（无 reload、无等待）
# auth=false：所有端点放行且 body 内**不含任何 token= 参数**（与现状逐字节一致）
# fail closed：mv tokens.php /tmp → 任意端点 503（含提示文案）；tokens.php 写入语法错误 → 503 而非 500

# 1b) filter（本地 fixture 复刻用户示例：#EXTM3U 带 url-tvg、两条目 tvg-name+名称、
#     URL 形如 http://other.host/mytv.php?url=<真实源>）—— p=m3u 与 sub= 各跑一遍
f() { curl -s ".../mytv.php?$1&token=S1"; }
f "sub=<fixture>&filter=翡翠台"            # 只剩翡翠台块（EXTINF+URL 成对），凤凰中文整块消失
f "sub=<fixture>&filter=翡翠台,凤凰中文"   # 两条都在
f "sub=<fixture>&filter=翡翠台，凤凰中文"  # 全角逗号等价
f "sub=<fixture>&filter=凤凰"              # 子串匹配：命中"凤凰中文"
f "sub=<fixture>&filter=CCTV"              # 200 且只有 #EXTM3U 头（空结果不报错）
f "sub=<fixture>&filter=翡翠台" | grep -c 'token='        # ≥2：头部 url-tvg + 资源行都盖了章
f "sub=<fixture>" | grep -c 'other.host/mytv.php'         # 0：第三方代理已解包成单跳
f "p=m3u&filter=翡翠台"                    # p=m3u 同样生效（v7 新增；上游 fixture 用本地替身）
# 断言：过滤后每个保留块的 EXTINF 与其 URL 行数一一对应（无孤行）
# 断言：$MYTV_UNWRAP_REMOTE_PROXY=false 时退回"原样包一层"（对照 stock sub.php）
# + 端到端：sub= 返回的第一条链接直接 curl → ≠403
# + 自引用：.../mytv.php?sub=<本站URL>&token=S1 → 400，且 pm.max_children=1 下不 hang

# 2) 安装流程
#   全新容器：MYTV_REF=token sh token/install.sh
#     → 断言：横幅打印了 20 hex token；mytv.php 属主 root:root 0644 且 **sha256 与仓库文件相同**
#     → 断言：sub.php 已删除；/etc/mytv/tokens.php 存在 0640 且含 'auth' => true 与一枚哈希
#     → 断言：裸访问 403、带打印 token 访问 200
#   往 tokens.php 加第二枚 token 后重跑 install.sh
#     → 断言：tokens.php **完全未被改动**、第二枚仍可用、未重复打印 token（幂等）
#   MYTV_SKIP_BASE=1 …（已定制 conf 的机器）→ 断言 conf 未被重取
#   MYTV_TOKEN=0 … → 断言只做了阶段 1（等价主脚本，站点无认证）
#   回退：MYTV_REF=main sh php/install.sh → 断言恢复无认证行为（sub.php 回来了）
```

---

## 已知风险（写进 token/README，不在本次解决）

- **凭据永不过期且被印进 playlist（v7 的主要取舍）**：转发一份 playlist = 永久交出该 token 的全部权限（含订阅），只能靠人工删行吊销。缓解：每人/每设备一枚 + 标签便于定位；删行即时生效；README 首屏警告"playlist 链接等同凭据"。要恢复"可转发的播放凭据"需回到 v6 的分层设计（git 历史里有完整方案）。
- **fork 漂移（唯一剩下的漂移面）**：`token/mytv.php` 是 `php/mytv.php` 的副本（并吸收了 sub.php 的逻辑），上游修 bug 不会自动跟进。缓解：新增块全部 `===== mytv-token begin/end =====` 标记；README 固化同步流程（标记块外的 diff = 上游漂移，改动点集中 7 处可重放）。**tokens.php 不受升级影响**（配置已移出源码，这是 v7 相对 v6 的实质改善）。
- **手改 mytv.php 的自定义会在升级时丢失**（如 `$enable_domain_check`、上游地址）——这是主安装器一贯的行为，token 版未加重也未减轻；README 提示改动尽量放 tokens.php 或提 PR。
- **`filter` 是子串匹配**：`filter=凤凰` 会命中"凤凰中文""凤凰资讯"；无正则、无锚定、无排除语法。名称取自 `#EXTINF` 最后一个逗号之后，兼匹配 `tvg-name`；上游若把真名放在别处（如 `group-title`）则匹配不到。
- **第三方代理解包的行为变更**：`$MYTV_UNWRAP_REMOTE_PROXY=true`（默认）把别站 `mytv.php?url=X` 解包为本站单跳；若内层链接依赖第三方代理的特殊请求头，语义会变。可设 false 退回旧行为。
- **垃圾流量会唤醒 PHP worker**（放弃 nginx 门的已知代价）：正常扫描量下每次拒绝仅几毫秒；洪水对策是 `limit_req`。**默认开启认证后所有扫描请求都会打到 PHP**，README 把 `limit_req` 列为强烈建议。劣势场景：`pm.max_children=1` 且唯一 worker 被慢传输占用时，无凭据请求排队等 fastcgi。
- **临时/稳定 token 都不构成 SSRF 闭环**：`?url=` 可代理任意地址这一事实未变；token 只挡白嫖与扫描器。真收紧靠 `$enable_domain_check` + `limit_req` + allow/deny。
- php-fpm 被攻破：偷不到 token（只存哈希）、**改不了 `auth` 开关也加不了自己的 token**（tokens.php 是 root:root 0640，PHP 无写权；mytv.php 是 root:root 0644），但能读到请求里的明文 token 并直接滥用代理——这与"无认证版被攻破"没有区别。
- tokens.php 丢失/损坏 = 全站 503（fail closed）：重建文件即恢复；这是唯一与凭据相关的故障模式，恢复是一条命令。
- Debian `ProtectSystem=full` 下 `/etc` 可读；`open_basedir` 需含 `/etc/mytv`。SELinux 未验证。
- 改 tokens.php 的生效延迟依赖 opcache 时间戳校验（默认 2s）；关掉 `validate_timestamps` 的环境需 reload php-fpm（README 写明，**吊销因此可能不是即时的**）。
- 开启认证后真 403 会让部分播放器判频道失效并停止重试；建议先在自己设备验证一整晚再发给别人。

## 实施顺序
1. `token/mytv.php`：fork + 标记块（配置常量 + helper，含 `mytv_rewrite_playlist` 双模式/分块过滤/头部属性盖章）+ 入口一次判定 + **p=m3u 接入 filter** + 并入 sub= 分支 + 4 处 url= 盖章 + 自引用拒绝 + CONNECTTIMEOUT + SCRIPT_NAME
2. `php -l`（debian + alpine 双镜像）+ helper 单测（第 0 节，不需要 nginx）
3. `token/install.sh`：委托阶段 1 + 阶段 2（fetch → root:root 0644 → 删 sub.php → 幂等生成 tokens.php → token 感知自检 → 横幅）
4. docker 跑完整断言矩阵（含盖章归属、吊销即时性、1b 的 filter 双端点组）+ 安装/幂等/回退实测
5. `token/README.md`（含 tokens.php 模板与 filter 专节）
