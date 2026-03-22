---
name: weibo-assistant
description: 微博自动化助手。用于：登录微博（扫码）、查看消息/评论/点赞/热搜、定时推送微博动态。当用户说"登录微博"、"微博消息"、"微博热搜"、"谁给我点赞"、"微博动态"时使用。
metadata: { "openclaw": { "os": ["linux"], "emoji": "📱", "requires": { "bins": ["python3", "chromium"], "config": ["browser.enabled"] } } }
---

# 微博自动化助手

> 本技能通过 OpenClaw 浏览器（headless Chromium）操作微博**移动端网页**（m.weibo.cn），实现登录、信息抓取和定时推送。
>
> ⚠️ **重要**：必须使用移动端 `m.weibo.cn` 和 `passport.weibo.cn`，**绝对不要**使用 PC 端 `weibo.com` 或 `passport.weibo.com`——PC 端会检测到服务器 IP 为异常网络环境并拦截。

## 首次部署

如果是全新部署的 OpenClaw 机器，需要先运行安装脚本完成环境准备：

```bash
bash {baseDir}/scripts/setup.sh
```

该脚本会自动完成以下工作（**使用国内镜像加速，无需科学上网**）：

1. 安装 Chromium 运行所需的系统依赖（libnss3、libgbm 等）
2. 安装 Python 版 Playwright（提供 `playwright install` CLI）
3. 从 npmmirror 国内镜像下载 Chromium 和 Headless Shell
4. 创建 `/usr/bin/chromium` 软链接
5. 创建 Cookie 数据目录

安装完成后，还需手动配置 OpenClaw：

```bash
# 启用浏览器（编辑 ~/.openclaw/openclaw.json，添加 browser 配置）
openclaw config set browser.enabled true
openclaw config set browser.headless true
openclaw config set browser.noSandbox true

# 切换到 full 工具集（coding 模式不包含 browser 工具）
openclaw config set tools.profile full

# 重启生效
openclaw gateway restart
openclaw browser start
```

## 0) 前置条件

- 浏览器必须运行中：`openclaw browser status` 应显示 `running: true`
- 如果浏览器未运行：`openclaw browser start`
- Cookie 管理脚本：`{baseDir}/scripts/weibo_cookies.py`
- Cookie 存储位置：`~/.openclaw/data/weibo/cookies.json`

## 1) 登录流程（二维码扫码）

### 1.1 检查是否已登录

先检查是否有有效 Cookie：
```bash
python3 {baseDir}/scripts/weibo_cookies.py check
```

如果返回 `valid: true` 且 `hours_remaining > 1`，执行**Cookie 恢复流程**（跳到 1.4）。
如果返回 `valid: false` 或无 Cookie，执行**二维码登录流程**（继续 1.2）。

### 1.2 打开登录页并获取二维码

**步骤 1**：导航到微博移动端登录页（绕过 PC 端异常网络检测）
```
browser navigate https://passport.weibo.cn/signin/login?entry=mweibo&r=https%3A%2F%2Fm.weibo.cn%2F
```
等待 3 秒加载。该页面默认显示二维码扫码登录。

**步骤 2**：截取登录页截图（包含二维码）
```
browser screenshot --element '.flex-col.items-center.justify-center'
```
截图文件路径为 `MEDIA:~/.openclaw/media/browser/xxx.png`
> ⚠️ **必须使用 --element 参数截取二维码面板**，不要用不带参数的 browser screenshot（全屏截图太小看不清二维码）。如果元素选择器失败，可以用 `browser screenshot --element "img[src*=qr.weibo]"` 作为备选。

**步骤 3**：将截图发送给用户
把截图通过当前对话渠道发给用户，并附上提示：
> 📱 请用微博 APP 扫描上方二维码登录
> 打开微博手机APP → 我的页面 → 扫一扫
> 扫码后请回复"已扫码"，我会自动完成后续操作。

### 1.3 等待用户扫码并保存 Cookie

用户回复"已扫码"后：

**步骤 1**：等待页面跳转（登录成功后会跳转到微博首页）
```
browser wait --url m.weibo.cn --timeout 15000
```
如果超时，再截一次图让用户确认。

**步骤 2**：导航到微博移动端首页确保登录态生效
```
browser navigate https://m.weibo.cn/
```
等待 3 秒。

**步骤 3**：验证登录成功
```
browser snapshot --labels
```
查看页面中是否出现个人头像或用户昵称（而不是"登录/注册"按钮），确认已登录。

也可以用 JS 验证：
```
browser evaluate --fn '() => { return document.cookie.includes("SUB=") ? "logged_in" : "not_logged_in"; }'
```

**步骤 4**：保存 Cookie
```bash
openclaw browser cookies 2>/dev/null | grep -v '^\[plugins\]' | python3 {baseDir}/scripts/weibo_cookies.py save
```

**步骤 5**：通知用户
> ✅ 微博登录成功！Cookie 已保存，后续无需重复扫码。

### 1.4 Cookie 恢复流程（免扫码）

当已有有效 Cookie 时，直接恢复登录态：

**步骤 1**：加载已保存的 Cookie
```bash
python3 {baseDir}/scripts/weibo_cookies.py load
```

**步骤 2**：将 Cookie 逐个设置到浏览器
对于每个 cookie，使用：
```
browser cookies set --name <name> --value <value> --domain <domain> --path <path> [--secure] [--httponly]
```

> ⚠️ 关键 Cookie：`SUB`、`SUBP`、`XSRF-TOKEN`、`_T_WM` 必须设置。

**步骤 3**：刷新页面验证
```
browser navigate https://m.weibo.cn/
```
检查是否已登录。如果未登录（Cookie 已过期），提示用户重新扫码。

## 2) 信息抓取

> ⚠️ 所有抓取操作统一使用移动端 `m.weibo.cn`，不要使用 PC 端 `weibo.com`。

### 2.1 查看我的消息（私信/系统通知）

```
browser navigate https://m.weibo.cn/message
```
等待加载后：
```
browser snapshot --labels
```
提取页面中的消息列表，整理为：
- 📩 **新私信**：发送者 + 内容摘要
- 🔔 **系统通知**：内容 + 时间

如果 DOM 内容不够，可以通过 API 获取：
```
browser evaluate --fn '() => fetch("https://m.weibo.cn/api/msg/list?page=1").then(r=>r.json())'
```

### 2.2 查看我的评论

```
browser navigate https://m.weibo.cn/message/cmt
```
等待加载后提取评论列表。

也可以通过 API 获取：
```
browser evaluate --fn '() => fetch("https://m.weibo.cn/api/msg/cmt?page=1").then(r=>r.json())'
```

提取并整理：
- 💬 **新评论**：评论者 + 评论内容 + 对应微博摘要

### 2.3 查看谁给我点赞

```
browser navigate https://m.weibo.cn/message/attitude
```
等待加载后提取。

也可以通过 API 获取：
```
browser evaluate --fn '() => fetch("https://m.weibo.cn/api/msg/attitude?page=1").then(r=>r.json())'
```

提取：
- 👍 **新点赞**：点赞者 + 被点赞的微博摘要

### 2.4 查看微博热搜

```
browser evaluate --fn '() => fetch("https://m.weibo.cn/api/container/getIndex?containerid=106003type%3D25%26t%3D3%26disable_hot%3D1%26filter_type%3Drealtimehot").then(r=>r.json())'
```
提取热搜榜前 15 条：
- 🔥 **热搜 TOP15**：排名 + 标题 + 热度值

备选（直接访问热搜页面）：
```
browser navigate https://m.weibo.cn/p/106003type=25&t=3&disable_hot=1&filter_type=realtimehot
```

### 2.5 查看我的首页动态

```
browser navigate https://m.weibo.cn/
```
或通过 API 获取关注人最新动态：
```
browser evaluate --fn '() => fetch("https://m.weibo.cn/feed/friends?max_id=0").then(r=>r.json())'
```
提取首页前 5-10 条动态的：
- 发布者、内容摘要、互动数据（转发/评论/点赞）

## 3) 推送格式

所有推送统一使用以下格式模板：

```
📊 微博动态摘要（YYYY-MM-DD HH:MM）

🔥 热搜 TOP5：
1. [标题]（热度）
2. [标题]（热度）
...

📩 新消息（X条）：
· [发送者]: [内容摘要]

💬 新评论（X条）：
· [评论者] 评论了你的微博"[微博摘要]": [评论内容]

👍 新点赞（X个）：
· [点赞者] 赞了你的微博"[微博摘要]"

📝 首页热门动态：
· [博主]: [内容摘要]（转发X 评论X 赞X）
```

## 4) Cookie 有效性监控

每次执行任务前，先检查 Cookie 有效性：
```bash
python3 {baseDir}/scripts/weibo_cookies.py check
```

- 如果 `valid: true` 且 `hours_remaining > 24`：正常执行
- 如果 `valid: true` 且 `hours_remaining < 24`：执行任务 + 提醒用户"Cookie 即将过期，建议重新扫码"
- 如果 `valid: false`：停止任务，通知用户需要重新扫码登录

> **Cookie 有效期说明**：核心 Cookie `SUB` 有效期为 1 年，但 `ALF`（自动登录标记）仅 30 天。建议每月重新扫码一次确保所有 Cookie 保持新鲜。

## 5) 定时推送（可选）

安装完成后可配置定时推送任务：

```bash
# 每天早上 9 点推送
openclaw cron add --name weibo-morning --schedule "0 9 * * *" --message "请执行微博每日摘要推送：抓取热搜TOP10、我的新消息/评论/点赞、首页动态，按推送格式整理后发送给我。" --disabled

# 每天晚上 8 点推送
openclaw cron add --name weibo-evening --schedule "0 20 * * *" --message "请执行微博晚间摘要推送：抓取热搜TOP10、我的新消息/评论/点赞、首页动态，按推送格式整理后发送给我。" --disabled
```

首次扫码登录成功后，启用定时任务：
```bash
openclaw cron enable weibo-morning
openclaw cron enable weibo-evening
```

## 6) 常见问题

### 异常网络环境拦截
**绝对不要使用** PC 端 `weibo.com` 或 `passport.weibo.com` 的任何 URL。服务器 IP（云服务器）会被 PC 端微博识别为异常环境。**始终使用**移动端 `m.weibo.cn` 和 `passport.weibo.cn`。

### 二维码过期
微博二维码约 5 分钟过期。如果用户未及时扫码：
```
browser navigate https://passport.weibo.cn/signin/login?entry=mweibo&r=https%3A%2F%2Fm.weibo.cn%2F
```
重新加载获取新二维码。

### 页面加载失败
如果页面内容异常（空白/报错）：
1. 先 `browser screenshot` 截图查看
2. 尝试刷新：`browser navigate <当前URL>`
3. 如果持续失败，检查浏览器状态：`openclaw browser status`

### Cookie 注入后仍未登录
可能是 Cookie 不完整。清除后重新走扫码流程：
```
browser cookies clear
browser navigate https://passport.weibo.cn/signin/login?entry=mweibo&r=https%3A%2F%2Fm.weibo.cn%2F
```

### 环境依赖缺失
如果 `openclaw skills check` 显示 weibo-assistant 为 missing 状态，运行安装脚本：
```bash
bash {baseDir}/scripts/setup.sh
```
