# mytv token 版

给 `php/mytv.php` 加上 **token 认证**（默认开启）与 **订阅过滤**（`filter=`）的版本。

- `token/mytv.php` — 应用文件（fork 自 `php/mytv.php`，并吸收了 `php/sub.php` 的功能）
- `token/install.sh` — 一键部署
- `token/NOTES.md` — 维护者笔记（设计取舍、已知限制、同步上游的方法）

**不改动仓库里任何现有文件**，全部内容在 `token/` 目录内。

---

## 一、安装

```sh
# token 分支合并进 main 之前
curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/token/token/install.sh | sh

# 合并进 main 之后：同一个脚本，只换路径
curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/main/token/install.sh | sh
```

脚本会装好 nginx + php-fpm、写好站点配置、部署应用、生成凭据表，并自检。
装完会**只打印一次**明文 token，请立刻保存——服务器上只存它的 sha256 哈希，丢了只能重新生成。

认证默认开启，不用指定别的变量；`MYTV_REF` 也不用管（脚本自己挑能用的版本）。

### 环境变量（一般都用不上）

| 变量 | 默认 | 说明 |
|---|---|---|
| `MYTV_TOKEN` | `1` | 设 `0` = 只做基础安装、站点无认证（应急退路） |
| `MYTV_SKIP_BASE` | 空 | 设 `1` 跳过基础环境安装（环境已装好的机器） |
| `MYTV_REF` | `main` | 指定版本；填 tag 或 commit 可固定部署版本 |
| `SHA_MYTV_PHP` | 空 | 应用文件的 sha256，设了就强制校验 |

### 依赖

全部由安装脚本自动装好，手工部署时只需要：`nginx`、`php-fpm`（PHP ≥ 7.0）、`php-curl`、`curl`。

**不需要**：数据库、redis、composer、node、cron、`openssl` 命令行、mbstring。

### 部署产物

| 路径 | 权限 | 说明 |
|---|---|---|
| `/var/www/html/mytv.php` | `root:root 0644` | 应用文件，与仓库文件逐字节一致（可 sha256 比对） |
| `/etc/mytv/tokens.php` | `root:<php-fpm组> 0640`，目录 `0710` | 凭据表，只存哈希 |

完整的文件清单（用了仓库里哪些文件、手工部署怎么做）见 [NOTES.md](NOTES.md#4-依赖与用到的全部文件)。

---

## 二、怎么用

**token 放在最前面**，后面才是别的参数：

```
# 整份订阅
http://<服务器>/mytv.php?token=<你的token>&p=m3u

# 只看翡翠台与凤凰中文（子串匹配、大小写不敏感，英文或全角逗号分隔）
http://<服务器>/mytv.php?token=<你的token>&p=m3u&filter=翡翠台,凤凰中文

# 代理一份上游订阅
http://<服务器>/mytv.php?token=<你的token>&sub=<编码后的上游地址>
```

把这串链接填进播放器即可。`filter` 对 `p=m3u` 和 `sub=` 都生效；一个关键字都没命中时返回空列表
（仍是 200，不报错）。匹配规则（子串、大小写、全角逗号、上限…）见
[NOTES.md](NOTES.md#6-filter-的完整规则)。

> ⚠️ **输出里每条链接都会被盖上你自己那枚 token**——播放器取子链接、拉 EPG 时才不会再被 403 拦住。
> 代价是：**转发一份 playlist 等于把这枚 token 的权限交出去**，直到你从 `tokens.php` 里删掉那一行。
> 建议**每人/每设备一枚 token**，谁泄露删谁那一行。

### 命令行自检

```sh
curl -s -o /dev/null -w '%{http_code}\n' 'http://<服务器>/mytv.php'                     # 期望 403
curl -s -o /dev/null -w '%{http_code}\n' 'http://<服务器>/mytv.php?token=<你的token>'  # 期望 200
```

⚠️ 命令行里链接**必须用引号包住**：`&` 在 shell 中是后台执行符，不加引号会从 `&` 处断成两条命令，
实际发出去的请求里根本没有 token（必然 403），回车后还会看到 `[1]+ Done`。
浏览器地址栏不需要引号，复制的链接直接贴进去即可。

---

## 三、凭据管理 `/etc/mytv/tokens.php`

```php
<?php
return [
    'auth'   => true,          // 总开关：false = 完全放行（等价无认证版）
    'tokens' => [
        // 键 = sha256(token) 的 64 位十六进制，值 = 标签（只为辨认，不参与判定）
        '3a5f9c…' => '我的手机',
        '9c1142…' => '客厅电视',
    ],
];
```

- **加人**：`printf '%s' '新token' | sha256sum` → 把输出的哈希粘进数组，值随便写个标签。
- **封人**：删掉对应那一行，**立即生效**（无需 reload、无需重启）。
- 只存哈希不存明文；token 大小写敏感，建议 8~40 位的低位 ASCII（安装脚本生成的是 20 位十六进制）。
- ⚠️ 别把 `auth` 设成 `true` 却留空数组——那会让整站 503（有意为之：宁可拒绝也不裸奔放行）。

---

## 四、出问题先看这里

| 现象 | 原因 / 处理 |
|---|---|
| 带了 token 仍 **403**，还冒出 `[1]+ Done` | 链接没加引号，`&` 被 shell 吃掉了（见上一节的警告） |
| 所有请求 **403** | 看正文第一行：`需要有效的 token` = 请求里没带（多半是引号问题）；`token 无效` = 带了但对不上，用 `printf '%s' '你的token' \| sha256sum` 重新核对（大小写敏感），或刚改完 `tokens.php` 不到 2 秒 |
| 整站 **503** | `tokens.php` 缺失 / 权限不对 / 语法错 / 数组为空。`ls -l /etc/mytv/tokens.php`（应 `0640 root:<php-fpm组>`）、`ls -ld /etc/mytv`（应 `0710`） |
| 频道能播但 **EPG 空** | 用的是旧版 `mytv.php`（头部 `url-tvg` 没盖章），重跑一次安装脚本 |
| 改 `tokens.php` **不生效** | 等 2 秒（opcache 的校验间隔默认 2s） |
| Alpine 上 **502** | 确认 `/etc/nginx/nginx.conf` 里的 `include /etc/nginx/http.d/*.conf;` 没被注释掉 |

403 的正文只有一两句话、不给路径和命令，这是**故意的**——不把服务器信息回给访问者。
（503 是管理员配置错误，提示里会带排查命令。）

### 回退到无认证版

```sh
curl -fsSL https://raw.githubusercontent.com/HasonHuang/mytv/main/php/install.sh | sh
```

`/etc/mytv/tokens.php` 留着无害（回退后没人再读它）。

---

## 五、维护者

- 设计文档：`docs/plans/01-auth-token.md`
- 实现取舍、已知限制、SSRF 边界、与上游 `php/mytv.php` 的同步方法：[NOTES.md](NOTES.md)
