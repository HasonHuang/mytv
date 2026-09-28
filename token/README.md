# mytv token 版（PHP 全实现）

给 `php/mytv.php` 加上 **token 认证**（默认开启）与 **订阅过滤**（`filter=`）的版本。
**不改动仓库里任何现有文件**，全部内容在 `token/` 目录内。

```
token/
├── mytv.php      # 应用文件（fork 自 php/mytv.php，并吸收了 php/sub.php 的功能）
├── install.sh    # 一键部署（委托主安装器 + token 化）
└── README.md     # 本文档
```

部署后在服务器上只有两个产物：

```
/var/www/html/mytv.php     # root:root 0644，与仓库文件逐字节一致
/etc/mytv/tokens.php       # root:<php-fpm 组> 0640，凭据表（只有哈希）
```

没有 cron、没有数据表、没有密钥文件、没有额外的 nginx 配置、没有 reload 脚本。

---

## 1. token 模型（先读这段）

**单层稳定 token**：一枚 token 可以访问全部端点（`?p=m3u`、`?sub=`、`?url=`），
**不过期、不轮换、无临时 token**。判定就是一次 `isset($tokens[sha256(你的token)])`。

服务器上**只保存 sha256 哈希**，不存明文。所以：

- 明文丢了只能重新生成一枚（哈希不可逆）；
- 泄露了就**从 `tokens.php` 里删掉那一行**，立即失效，不牵连别人。

### ⚠️ playlist 链接等同于凭据

`p=m3u` / `sub=` 输出里的每条自有链接都会被盖上**请求者自己那枚 token**，
这样播放器取子链接、取 EPG 时才不会再被 403 拦住。代价是：

> **转发一份 playlist，等于把该 token 的全部权限（含整份订阅）永久交出去**，
> 直到你手工删掉那一行。

因此建议：**每人/每设备一枚 token + 一个有意义的标签**。谁泄露了就删谁那一行，
其他人不受影响。标签只用于让你知道该删哪行（不参与判定，可以随便写）。

### 失效方向（fail closed）

| 情况 | 行为 |
|---|---|
| `tokens.php` 缺失 / 不可读 / 语法错 / 返回值不是数组 | **503** + 自解释提示。绝不裸奔放行 |
| `'auth' => true` 但 `tokens` 数组为空 | **503**（还没签发任何凭据） |
| token 不匹配 / 没带 token | **403** |
| `'auth' => false` | 完全放行，且**不盖章**（行为与无认证版逐字节一致） |

503 与 403 严格区分：**503 = 管理员配置错了**（去修 `tokens.php`），**403 = 访问者没凭据**。

---

## 2. 安装

```sh
# 全新安装（Debian / Ubuntu / Alpine）
curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/token/token/install.sh | MYTV_REF=token sh
```

装完会**只打印一次**明文 token，请立刻保存。之后：

```sh
curl -i 'http://<服务器IP>/mytv.php?p=m3u&token=<你的token>'
```

### 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `MYTV_REF` | `token` | 拉取的文件版本。建议固定到 tag/commit 以保证可复现 |
| `MYTV_SKIP_BASE` | 空 | 设为 `1` 跳过阶段 1（基础环境已装好的机器） |
| `MYTV_TOKEN` | `1` | 设为 `0` 只做阶段 1 = 等价主脚本，站点无认证（应急退路） |
| `SHA_MYTV_PHP` | 空 | `token/mytv.php` 的 sha256，设置后强制校验 |

### 回退到无认证版

```sh
MYTV_REF=main sh -c "$(curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/main/php/install.sh)"
```

`/etc/mytv/tokens.php` 留着无害（回退后没人再读它）。

### 手动部署（不跑 install.sh）

```sh
install -o root -g root -m 0644 token/mytv.php /var/www/html/mytv.php
rm -f /var/www/html/sub.php                     # 否则留下一个无认证入口
mkdir -p /etc/mytv && chown root:<php-fpm组> /etc/mytv && chmod 0710 /etc/mytv
# 生成一枚 token 的哈希
printf '%s' '你的token' | sha256sum
# 按下面的模板写好 /etc/mytv/tokens.php
chown root:<php-fpm组> /etc/mytv/tokens.php && chmod 0640 /etc/mytv/tokens.php
```

---

## 3. 凭据表 `/etc/mytv/tokens.php`

```php
<?php
// 改完即生效（opcache 默认 2s 内）。
return [
    'auth'   => true,          // 总开关：false = 完全放行且不盖章（与无认证版行为一致）
    'tokens' => [
        // 键 = sha256(token) 的 hex，值 = 人类可读标签（仅供辨认，不参与判定）
        '3a5f9c…（64 位十六进制）' => '我的订阅',
        '9c1142…'                => '客厅电视',
    ],
];
```

- **加人**：`printf '%s' '新token' | sha256sum` → 把哈希粘进数组，值随便写个标签。
- **封人**：删掉对应那一行即可，立即生效。
- token 本身**大小写敏感**（PHP 字节比较）。建议用 8~40 位的低位 ASCII；`install.sh` 生成的是 20 位十六进制。
- ⚠️ **别把 `auth` 设成 `true` 却留空数组**——那会让整站 503（这是有意的 fail closed）。

> **为什么配置不写在 `mytv.php` 里？** 因为那样 `install.sh` 就得用 `sed` 往源码里注入哈希，
> 部署文件不再与仓库一致（SHA 校验失效），每次升级还得用 `awk` 把旧配置抽出来覆盖回去。
> 放到 `/etc/mytv/tokens.php` 后升级天然安全，而且**开关不在 docroot 里**——
> `mytv.php` 是 root:root 0644、`tokens.php` 是 root:root 0640，
> php-fpm 即使被攻破也改不了认证开关、加不了自己的 token。

---

## 4. `filter=` 订阅过滤

```
http://<服务器>/mytv.php?p=m3u&filter=翡翠台,凤凰中文&token=<你的token>
http://<服务器>/mytv.php?sub=<编码后的上游m3u地址>&filter=翡翠台&token=<你的token>
```

**`p=m3u` 与 `sub=` 都支持**。

| 规则 | 说明 |
|---|---|
| 语法 | 英文逗号分隔多个关键字，**容忍全角逗号 `，`** |
| 匹配对象 | `#EXTINF` 行的**节目名**（属性区之后、逗号之后那段），并**兼匹配 `tvg-name` 属性** |
| 匹配方式 | **子串匹配**，大小写不敏感（`stripos`，二进制安全，中文正确，**不依赖 mbstring**） |
| 多关键字 | 逻辑 **OR**：命中任意一个就保留 |
| 整块去留 | 条目块（`#EXTINF` 等 `#` 行 + 紧随的 URL 行）**同去同留**，不会产出孤行或错配 |
| 无命中 | 返回 **200**，内容只剩 `#EXTM3U` 头（空列表不报错） |
| 上限 | 最多 20 个关键字，每个超过 64 字节截断（防病态输入） |
| 不支持 | 正则、锚定、排除语法（`-关键字`）、按 `group-title` 匹配 |

`#EXTM3U` 头部行**永远保留**（它是列表头不是内容），其中的 `url-tvg=` / `x-tvg-url=` 属性
若指向代理链接会被一并归一、盖章，否则 EPG 拉取会 403、节目单全空。

### 真实示例

```
# 只看翡翠台与凤凰中文
http://<服务器>/mytv.php?sub=http%3A%2F%2F<上游>%2Fmytv.m3u&filter=%E7%BF%A1%E7%BF%A0%E5%8F%B0,%E5%87%A4%E5%87%B0%E4%B8%AD%E6%96%87&token=<你的token>
http://<服务器>/mytv.php?p=m3u&filter=%E7%BF%A1%E7%BF%A0%E5%8F%B0&token=<你的token>

# 输出（每条自有链接都带上了你自己那枚 token，头部 url-tvg 也已盖章）
#EXTM3U url-tvg="http://<服务器>/mytv.php?url=https%3A%2F%2Fepg…&token=<你的token>" catchup="append" …
#EXTINF:-1 tvg-name="翡翠台" group-title="mytv",翡翠台4K(字幕)
http://<服务器>/mytv.php?url=https%3A%2F%2Fcdn3.indevs.in%2Fstream%2Ftvb%2Ffct4k%2F&token=<你的token>
```

注意 `filter=凤凰` 是**子串**匹配，会同时命中「凤凰中文」和「凤凰资讯」。

---

## 5. 从旧的 `sub.php` 迁移

token 版不部署 `sub.php`（功能已并入 `mytv.php?sub=`）：

```
旧：/sub.php?url=<编码后的上游地址>
新：/mytv.php?sub=<编码后的上游地址>&token=<你的token>
```

如果还有老客户端在用旧地址，可以在 `/var/www/html/sub.php` 放一个**跳转存根**
（它本身不含认证逻辑，只是 302 到 `mytv.php`，所以仍然受 token 保护）：

```php
<?php
$q = 'mytv.php?sub=' . urlencode(isset($_GET['url']) ? $_GET['url'] : '');
if (!empty($_GET['token'])) { $q .= '&token=' . urlencode($_GET['token']); }
header('Location: ' . $q, true, 302);
```

---

## 6. 行为细节与开关

### `$MYTV_UNWRAP_REMOTE_PROXY`（`token/mytv.php` 顶部，默认 `true`）

上游 playlist 里的资源行常常长这样：`http://别站/mytv.php?url=<真实源>`。默认行为是
**把内层真实地址解包出来，重建成"本站单跳"链接**，理由是：

- 不套娃（否则每播一次都多一跳）；
- 不依赖别人的服务器（对方关机你也跟着挂）；
- 别站的代理链接**不需要我们的 token 也能用**，所以**不给它盖章**——避免把凭据写进
  第三方服务器的访问日志。

设成 `false` 则退回 `sub.php` 的老行为：把别站代理链接**原样再包一层**。

### 盖章只给"自有链接"

只有**自有链接**会被盖上 token：

- `p=m3u`（hostsub）模式下，只有归一到本站入口后的链接才盖章，**第三方直连 URL 原样保留、不加 token**；
- `sub=` 模式下，第三方**直连** URL 会被包装成本站代理链接（token 落在**我们的**链接上，第三方拿不到），
  而 `#EXTM3U` 的 `url-tvg` / `catchup-source` 这类属性只改写"本来就是代理形态"的链接，
  纯第三方直连的 EPG 地址不动、不盖章；
- `url=` 路径下「已代理就原样返回」的两处同样只对自有链接剥旧盖新。

把凭据直接送给第三方源站是纯粹的泄露，所以**任何情况下都不会把 token 拼到别人的域名上**。

### `catchup-source` 里的 `${...}` 模板保持原样

形如 `catchup-source="…playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"` 的属性**不做改写**：
模板要留给播放器替换，一旦被 urlencode 成 `%24%7B…%7D` 播放器就认不出模板、时移播放会失效。
这类链接通常指向无需认证的第三方代理，保持原样反而可用。

### 自引用会被拒绝（400）

`?sub=` / `?url=` 指向本站自身会返回 400。因为每一层都会占住一个 php-fpm worker，
而 `pm.max_children=1` 时第二层永远等不到空闲 worker——整站死锁，连错误页都发不出去。

---

## 7. 开启后的三条自检

```sh
curl -s -o /dev/null -w '%{http_code}\n' 'http://<服务器>/mytv.php'                      # 期望 403
curl -s -o /dev/null -w '%{http_code}\n' 'http://<服务器>/mytv.php?token=<你的token>'   # 期望 200
curl -s 'http://<服务器>/mytv.php?p=m3u&token=<你的token>' | head -3                    # 期望看到 #EXTM3U
```

---

## 8. 故障排查

| 现象 | 原因与处理 |
|---|---|
| 所有请求 **403** | 哈希粘错、或 token 大小写不符。`printf '%s' '你的token' \| sha256sum` 重新对一遍 |
| 整站 **503** | `tokens.php` 缺失/权限不对/有语法错误/数组为空。`ls -l /etc/mytv/tokens.php`（应 0640 root:<php-fpm组>）、`ls -ld /etc/mytv`（应 0710），再用 `php -r 'var_dump(include "/etc/mytv/tokens.php");'` 看输出。若配了 `open_basedir`，需要包含 `/etc/mytv` |
| playlist 里**没有** `token=` | `'auth'` 是 `false`（那是完全放行模式）；或者你改了 `mytv.php` 但没同步 |
| 频道能播但 **EPG 空** | 头部 `url-tvg` 未盖章——确认用的是本版本的 `mytv.php` |
| 403 后要等一会儿才好 | 见下面的 opcache 说明 |
| 改 `tokens.php` **不生效** | 等 2 秒（opcache 校验间隔）；若环境关掉了 `opcache.validate_timestamps`，需要 `systemctl reload php<版本>-fpm` |
| Alpine 上 502 | 确认 `/etc/nginx/nginx.conf` 里 `include /etc/nginx/http.d/*.conf;` 没被注释掉 |

---

## 9. 已知问题与限制（只记录，本版不修）

- **凭据永不过期，且被印进 playlist**：这是本版最大的取舍。转发 playlist = 永久交出该 token 的全部权限，
  只能靠人工删行吊销。缓解：每人/每设备一枚 + 标签、删行即时生效、本文档首屏的警告。
- **opcache 生效延迟**：`tokens.php` 的改动默认 2 秒内生效（`opcache.revalidate_freq`）。
  关掉 `validate_timestamps` 的环境必须 reload php-fpm，**此时吊销不是即时的**。
  同理，升级替换 `mytv.php` 后，最多 2 秒内仍可能执行旧脚本。
- **重跑安装时有一个短暂的无认证窗口**：阶段 1 会先部署一份无认证的 `php/mytv.php`，
  阶段 2 随即覆盖。窗口只有几秒（主安装器在最后一步才部署 PHP 文件），但重跑请安排在维护窗口。
- **`url=` 路径判断"是否播放列表"看的是 URL**：URL 里含 `.m3u8` 就按播放列表逐行改写，
  哪怕上游返回的是错误页（这是基线行为，本版未改；`sub=` 分支已改为只看 path）。
- **`?url=` 参数会被双重解码**：基线里是 `urldecode($_GET['url'])`，而 `$_GET` 已被 PHP 解码过一次。
  内层 URL 本身含 `%` 序列时可能被解坏（基线行为，本版未改）。
- **`filter` 是子串匹配**：无正则、无锚定、无排除语法。上游若把真名放在 `group-title` 而不是
  `tvg-name`/显示名里，就匹配不到。
- **临时/稳定 token 都不构成 SSRF 闭环**：`?url=` 能代理任意地址这一事实没有改变。见下。
- **fork 漂移**：`token/mytv.php` 是 `php/mytv.php` 的副本，上游修 bug 不会自动跟进。同步方法见第 10 节。
- **手改 `mytv.php` 的自定义会在升级时丢失**（如 `$enable_domain_check`、上游地址）——
  这是主安装器一贯的行为，token 版未加重也未减轻。改动尽量放 `tokens.php`，或提 PR。

### 与主仓版本的关系（同步方法）

新增内容全部包在 `===== mytv-token begin/end =====` 标记里，对基线的修改点都带 `// [mytv-token]` 注释：

```sh
git show main:php/mytv.php > /tmp/base.php
# 标记块之外的差异 = 上游漂移，应能逐一对应到那几个改动点
diff /tmp/base.php token/mytv.php | grep -v 'mytv-token' | less
```

### SSRF 三段话

1. `mytv.php` 可以代理任意 `?url=`，**这个事实没有改变**；
2. token 挡的是全网扫描器和白嫖，但**任何拿到一枚 token 的人，在你删掉那一行之前，
   都能永久拿它当开放代理用**；
3. 真要收紧：把 `mytv.php` 里的 `$enable_domain_check` 打开并维护域名白名单，
   再配合 `php-site.conf` 里的 `limit_req` 与 `allow/deny`。
   **默认开启认证后所有扫描请求都会打到 PHP 进程，所以强烈建议启用 `limit_req`**。

---

## 10. 仓库里的其它陈旧/无关内容（本版未动）

- `README.md:14` 里"请把 nginx.conf 第 69 行的 mytv123 修改为你自己的 token"——行号与内容已陈旧。
- `README.md:172-174` 与 `php/install.sh:454` 提到的 `60s` 超时，实际配置里是 `120s`。
- `nginx/nginx.conf` 里的 token `map` 属于反代版，PHP 版用不到。
- **`nginx/token/auth_tokens.example.conf` 与本方案无关**，是历史遗留的示例文件，token 版不使用它。
