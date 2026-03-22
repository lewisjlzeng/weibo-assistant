# 微博自动化助手（weibo-assistant）

OpenClaw 技能包。通过 Headless Chromium 操作微博移动端网页，实现扫码登录、消息/评论/点赞/热搜抓取和定时推送。

## 功能

- **扫码登录**：移动端二维码登录（绕过 PC 端反爬），Cookie 自动持久化
- **信息抓取**：私信、评论、点赞、热搜 TOP、首页动态
- **定时推送**：可配置 cron 任务，定时将微博摘要推送到企业微信等渠道
- **Cookie 管理**：自动检查有效性，过期前提醒重新扫码

## 系统要求

- **操作系统**：Ubuntu 22.04+ / Debian 12+（其他 Linux 发行版需自行调整系统依赖包名）
- **OpenClaw**：2026.3.x 或更新版本
- **Python**：3.10+
- **网络**：安装脚本使用国内镜像（npmmirror），无需科学上网

## 快速部署

### 1. 将 skill 复制到 OpenClaw 工作区

```bash
# 方式一：直接复制整个目录
cp -r weibo-assistant ~/.openclaw/workspace/skills/

# 方式二：如果通过 git 获取
git clone <repo-url>
cp -r weibo-assistant ~/.openclaw/workspace/skills/
```

### 2. 运行安装脚本

```bash
bash ~/.openclaw/workspace/skills/weibo-assistant/scripts/setup.sh
```

安装脚本会自动完成：
- 安装 Chromium 运行所需的系统共享库（libnss3、libgbm 等）
- 安装 Python 版 Playwright（提供浏览器管理 CLI）
- 从 **npmmirror 国内镜像**下载 Chrome for Testing + Headless Shell
- 创建 `/usr/bin/chromium` 软链接
- 创建 Cookie 数据目录

> 全部使用国内镜像，下载速度通常在 20MB/s+，整体安装过程约 1-2 分钟。

### 3. 配置 OpenClaw

```bash
# 启用浏览器（headless 无头模式）
openclaw config set browser.enabled true
openclaw config set browser.headless true
openclaw config set browser.noSandbox true

# 设置默认 profile 为 openclaw（非 Chrome 扩展模式，适用于无桌面的服务器）
openclaw config set browser.defaultProfile openclaw

# 注意：profile 的 color 和 cdpPort 必须同时存在才能通过验证，
# 无法通过 openclaw config set 逐个设置，需直接编辑配置文件：
python3 -c "
import json, pathlib
p = pathlib.Path.home() / '.openclaw/openclaw.json'
cfg = json.loads(p.read_text())
cfg.setdefault('browser', {}).setdefault('profiles', {})['openclaw'] = {'color': '#4A90D9', 'cdpPort': 18800}
p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))
print('browser profile openclaw 已写入')
"

# 切换到 full 工具集（coding 模式不包含 browser 工具）
openclaw config set tools.profile full

# 重启生效
openclaw gateway restart
openclaw browser start
```

### 4. 验证安装

```bash
# 检查 skill 是否被识别
openclaw skills list | grep weibo

# 检查浏览器状态
openclaw browser status
```

### 5. 首次登录

在企业微信（或其他已配置的渠道）中对 OpenClaw 说：

> 登录微博

Agent 会自动打开微博移动端登录页、截取二维码发给你。用微博 APP 扫码即可完成登录。

## 目录结构

```
weibo-assistant/
├── SKILL.md                      # 技能定义（OpenClaw 标准格式）
├── README.md                     # 本文件
└── scripts/
    ├── setup.sh                  # 环境安装脚本（国内镜像加速）
    └── weibo_cookies.py          # Cookie 管理工具
```

## Cookie 管理

Cookie 管理脚本提供四个命令：

```bash
# 检查 Cookie 是否有效
python3 scripts/weibo_cookies.py check

# 保存 Cookie（从 stdin 读取 JSON）
openclaw browser cookies | python3 scripts/weibo_cookies.py save

# 加载已保存的 Cookie
python3 scripts/weibo_cookies.py load

# 导出为 openclaw browser cookies set 命令格式
python3 scripts/weibo_cookies.py export
```

Cookie 存储位置：`~/.openclaw/data/weibo/cookies.json`

**有效期说明**：核心 Cookie `SUB` 有效期 1 年，但 `ALF`（自动登录标记）仅 30 天。建议每月重新扫码一次。

## 定时推送（可选）

```bash
# 每天早上 9 点推送
openclaw cron add --name weibo-morning --schedule "0 9 * * *" \
    --message "请执行微博每日摘要推送：抓取热搜TOP10、我的新消息/评论/点赞、首页动态，按推送格式整理后发送给我。"

# 每天晚上 8 点推送
openclaw cron add --name weibo-evening --schedule "0 20 * * *" \
    --message "请执行微博晚间摘要推送：抓取热搜TOP10、我的新消息/评论/点赞、首页动态，按推送格式整理后发送给我。"
```

## 注意事项

- **必须使用移动端**：所有微博 URL 统一使用 `m.weibo.cn`，不要使用 PC 端 `weibo.com`。PC 端会检测到云服务器 IP 并拦截。
- **不需要 GUI**：全程 Headless 模式运行，服务器不需要安装桌面环境。
- **安装脚本幂等**：重复运行不会重复安装已存在的组件。

## 版本信息

- Playwright: 1.58.x
- Chromium: 145.0.7632.6 (revision 1208)
- 国内镜像: registry.npmmirror.com
