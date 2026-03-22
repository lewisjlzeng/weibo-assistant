#!/usr/bin/env bash
# ============================================================================
# 微博自动化助手 — 一键安装脚本
# 适用于：Ubuntu 22.04+ / Debian 12+
# 用途：在 OpenClaw 部署机上一键完成「环境安装 + 配置 + 浏览器启动」
# 特点：全程自动化，无需人工干预；全部使用国内镜像（npmmirror）
# 使用：bash setup.sh
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 配置区（可根据实际情况修改）
# ---------------------------------------------------------------------------

# Playwright 对应的 Chromium 版本和 revision
CHROME_VERSION="145.0.7632.6"
CHROMIUM_REVISION="1208"

# 国内镜像地址（npmmirror）
MIRROR_BASE="https://registry.npmmirror.com/-/binary/chrome-for-testing"
CHROME_URL="${MIRROR_BASE}/${CHROME_VERSION}/linux64/chrome-linux64.zip"
HEADLESS_SHELL_URL="${MIRROR_BASE}/${CHROME_VERSION}/linux64/chrome-headless-shell-linux64.zip"

# Playwright 缓存目录
PW_CACHE="${HOME}/.cache/ms-playwright"
CHROMIUM_DIR="${PW_CACHE}/chromium-${CHROMIUM_REVISION}"
HEADLESS_DIR="${PW_CACHE}/chromium_headless_shell-${CHROMIUM_REVISION}"

# OpenClaw 相关路径
OPENCLAW_CONFIG="${HOME}/.openclaw/openclaw.json"
COOKIE_DIR="${HOME}/.openclaw/data/weibo"
CHROMIUM_BIN="/usr/bin/chromium"

# Headless Chromium systemd 服务配置
CDP_PORT=18800
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_NAME="openclaw-chromium-headless"
SERVICE_FILE="${SYSTEMD_USER_DIR}/${SERVICE_NAME}.service"

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }
skip()  { echo -e "\033[1;36m[SKIP]\033[0m  $*"; }

check_command() {
    command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------

preflight_check() {
    info "前置检查..."

    # 检查是否为 Linux
    if [[ "$(uname -s)" != "Linux" ]]; then
        fail "此脚本仅支持 Linux 系统（当前: $(uname -s)）"
    fi

    # 检查 OpenClaw 是否已安装
    if ! check_command openclaw; then
        fail "未检测到 openclaw 命令。请先安装 OpenClaw: https://docs.openclaw.ai/"
    fi

    # 检查 OpenClaw gateway 是否在运行
    if ! openclaw gateway status 2>/dev/null | grep -q "running"; then
        warn "OpenClaw gateway 未运行，稍后会尝试启动"
    fi

    # 检查 apt-get
    if ! check_command apt-get; then
        fail "不支持的系统：未找到 apt-get。仅支持 Ubuntu/Debian。"
    fi

    ok "前置检查通过"
}

# ---------------------------------------------------------------------------
# Step 1: 安装系统依赖
# ---------------------------------------------------------------------------

install_system_deps() {
    info "Step 1/6: 安装 Chromium 运行所需的系统依赖..."

    # apt-get update 允许部分源失败（如失效的 PPA），不阻塞安装流程
    sudo apt-get update -qq 2>&1 || warn "apt-get update 部分源失败（不影响安装）"

    sudo apt-get install -y -qq \
        libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 \
        libxcomposite1 libxrandr2 libgbm1 libpango-1.0-0 \
        libpangocairo-1.0-0 libasound2t64 libatspi2.0-0t64 \
        libxdamage1 libxshmfence1 \
        wget unzip 2>/dev/null || {
        # Ubuntu 22.04 及更早版本的包名不带 t64 后缀
        warn "t64 后缀包安装失败，尝试非 t64 版本（Ubuntu 22.04 兼容）..."
        sudo apt-get install -y -qq \
            libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
            libxcomposite1 libxrandr2 libgbm1 libpango-1.0-0 \
            libpangocairo-1.0-0 libasound2 libatspi2.0-0 \
            libxdamage1 libxshmfence1 \
            wget unzip
    }

    ok "系统依赖安装完成"
}

# ---------------------------------------------------------------------------
# Step 2: 安装 Python 版 Playwright
# ---------------------------------------------------------------------------

install_playwright() {
    info "Step 2/6: 安装 Python 版 Playwright..."

    if check_command playwright; then
        local current_version
        current_version=$(playwright --version 2>/dev/null | grep -oP '[\d.]+' || echo "unknown")
        skip "Playwright 已安装（版本: ${current_version}）"
        return 0
    fi

    if ! check_command pip3; then
        info "  pip3 未找到，先安装 python3-pip..."
        sudo apt-get install -y -qq python3-pip python3-full || \
            fail "无法安装 pip3。请手动运行: sudo apt-get install python3-pip"
    fi

    # Ubuntu 24.04+ 默认启用 PEP 668，禁止 pip 直接全局安装
    pip3 install playwright --quiet 2>/dev/null || {
        warn "pip3 受 PEP 668 限制，使用 --break-system-packages 安装..."
        pip3 install playwright --quiet --break-system-packages
    }

    # 确认 playwright 命令可用（可能安装到 ~/.local/bin）
    export PATH="${HOME}/.local/bin:${PATH}"
    if ! check_command playwright; then
        fail "Playwright 安装后未找到 playwright 命令。请检查 ~/.local/bin 是否在 PATH 中。"
    fi

    ok "Playwright 安装完成（版本: $(playwright --version 2>/dev/null)）"
}

# ---------------------------------------------------------------------------
# Step 3: 从国内镜像下载 Chromium
# ---------------------------------------------------------------------------

install_chromium() {
    info "Step 3/6: 从国内镜像下载并安装 Chromium..."

    # 检查是否已安装
    if [ -f "${CHROMIUM_DIR}/INSTALLATION_COMPLETE" ] && \
       [ -f "${HEADLESS_DIR}/INSTALLATION_COMPLETE" ] && \
       [ -x "${CHROMIUM_DIR}/chrome-linux64/chrome" ]; then
        local installed_version
        installed_version=$("${CHROMIUM_DIR}/chrome-linux64/chrome" --version 2>/dev/null || echo "unknown")
        skip "Chromium 已安装（${installed_version}）"
    else
        local tmp_dir
        tmp_dir=$(mktemp -d)

        info "  下载 Chrome for Testing ${CHROME_VERSION}（国内镜像: npmmirror）..."
        wget -q --show-progress -O "${tmp_dir}/chrome-linux64.zip" "${CHROME_URL}" || \
            fail "Chromium 下载失败。请检查网络连接或镜像地址。"

        info "  下载 Chrome Headless Shell..."
        wget -q --show-progress -O "${tmp_dir}/chrome-headless-shell-linux64.zip" "${HEADLESS_SHELL_URL}" || \
            fail "Headless Shell 下载失败。"

        info "  解压到 Playwright 缓存目录..."
        mkdir -p "${CHROMIUM_DIR}" "${HEADLESS_DIR}"
        unzip -q -o "${tmp_dir}/chrome-linux64.zip" -d "${CHROMIUM_DIR}/"
        unzip -q -o "${tmp_dir}/chrome-headless-shell-linux64.zip" -d "${HEADLESS_DIR}/"

        echo "${CHROMIUM_REVISION}" > "${CHROMIUM_DIR}/INSTALLATION_COMPLETE"
        echo "${CHROMIUM_REVISION}" > "${HEADLESS_DIR}/INSTALLATION_COMPLETE"

        chmod +x "${CHROMIUM_DIR}/chrome-linux64/chrome"
        chmod +x "${HEADLESS_DIR}/chrome-headless-shell-linux64/chrome-headless-shell"

        rm -rf "${tmp_dir}"
    fi

    # 创建/更新软链接
    info "  确保 ${CHROMIUM_BIN} 软链接存在..."
    sudo ln -sf "${CHROMIUM_DIR}/chrome-linux64/chrome" "${CHROMIUM_BIN}"

    local version
    version=$("${CHROMIUM_BIN}" --version 2>/dev/null || echo "验证失败")
    ok "Chromium 就绪（${version}）"
}

# ---------------------------------------------------------------------------
# Step 4: 创建数据目录
# ---------------------------------------------------------------------------

setup_data_dirs() {
    info "Step 4/6: 创建数据目录..."
    mkdir -p "${COOKIE_DIR}"
    ok "Cookie 数据目录: ${COOKIE_DIR}"
}

# ---------------------------------------------------------------------------
# Step 5: 配置 OpenClaw（全自动，无需人工操作）
# ---------------------------------------------------------------------------

configure_openclaw() {
    info "Step 5/6: 自动配置 OpenClaw..."

    if [ ! -f "${OPENCLAW_CONFIG}" ]; then
        fail "未找到 OpenClaw 配置文件: ${OPENCLAW_CONFIG}"
    fi

    # 使用 Python 直接修改配置文件（一次性写入，避免 openclaw config set 的验证问题）
    python3 << 'PYEOF'
import json, pathlib, sys

config_path = pathlib.Path.home() / ".openclaw/openclaw.json"
try:
    cfg = json.loads(config_path.read_text())
except Exception as e:
    print(f"  读取配置失败: {e}", file=sys.stderr)
    sys.exit(1)

changed = False

# --- browser 配置 ---
browser = cfg.setdefault("browser", {})

updates = {
    "enabled": True,
    "headless": True,
    "noSandbox": True,
}
for key, value in updates.items():
    if browser.get(key) != value:
        browser[key] = value
        changed = True
        print(f"  ✓ browser.{key} = {value}")
    else:
        print(f"  · browser.{key} = {value}（已是目标值）")

# 清理 profile 相关配置（直接 CDP 模式更稳定，不依赖 profile）
for key in ["defaultProfile", "profiles"]:
    if key in browser:
        del browser[key]
        changed = True
        print(f"  ✓ 移除 browser.{key}（使用直接 CDP 模式）")

# --- tools.profile ---
tools = cfg.setdefault("tools", {})
if tools.get("profile") != "full":
    tools["profile"] = "full"
    changed = True
    print("  ✓ tools.profile = full")
else:
    print("  · tools.profile = full（已是目标值）")

# --- 写入 ---
if changed:
    # 备份
    backup_path = config_path.with_suffix(".json.bak")
    backup_path.write_text(config_path.read_text())
    config_path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")
    print(f"  配置已更新（备份: {backup_path}）")
else:
    print("  配置无需更改，已是目标状态")
PYEOF

    ok "OpenClaw 配置完成"
}

# ---------------------------------------------------------------------------
# Step 6: 注册 Headless Chromium 服务并启动浏览器
# ---------------------------------------------------------------------------

setup_browser_service() {
    info "Step 6/6: 设置 Headless Chromium 服务并启动浏览器..."

    # --- 6a: 停止可能冲突的旧进程 ---
    # 杀掉可能残留的 Chromium CDP 进程
    if pgrep -f "remote-debugging-port=${CDP_PORT}" >/dev/null 2>&1; then
        info "  停止残留的 Chromium CDP 进程（端口 ${CDP_PORT}）..."
        pkill -f "remote-debugging-port=${CDP_PORT}" 2>/dev/null || true
        sleep 1
    fi

    # --- 6b: 创建 systemd user service ---
    mkdir -p "${SYSTEMD_USER_DIR}"
    cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=OpenClaw Headless Chromium (CDP port ${CDP_PORT})
After=network.target

[Service]
Type=simple
ExecStart=${CHROMIUM_BIN} \\
    --headless=new \\
    --no-sandbox \\
    --remote-debugging-port=${CDP_PORT} \\
    --remote-debugging-address=127.0.0.1 \\
    --disable-gpu \\
    --no-first-run \\
    --no-default-browser-check \\
    --disable-extensions \\
    --disable-background-networking \\
    --disable-sync \\
    --disable-translate \\
    --mute-audio \\
    --hide-scrollbars \\
    about:blank
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    info "  已写入 systemd 服务: ${SERVICE_FILE}"

    # --- 6c: 启动服务 ---
    systemctl --user daemon-reload
    systemctl --user enable "${SERVICE_NAME}.service" 2>/dev/null
    systemctl --user restart "${SERVICE_NAME}.service"
    info "  Chromium Headless 服务已启动"

    # --- 6d: 等待 CDP 端口就绪 ---
    info "  等待 CDP 端口 ${CDP_PORT} 就绪..."
    local retries=0
    local max_retries=15
    while [ $retries -lt $max_retries ]; do
        if curl -sf "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1; then
            break
        fi
        retries=$((retries + 1))
        sleep 1
    done

    if [ $retries -ge $max_retries ]; then
        warn "CDP 端口 ${CDP_PORT} 在 ${max_retries} 秒内未就绪"
        warn "请手动检查: systemctl --user status ${SERVICE_NAME}.service"
        return 1
    fi

    local chrome_version
    chrome_version=$(curl -sf "http://127.0.0.1:${CDP_PORT}/json/version" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Browser','unknown'))" 2>/dev/null || echo "unknown")
    ok "Chromium Headless 已就绪（${chrome_version}，CDP 端口 ${CDP_PORT}）"

    # --- 6e: 重启 OpenClaw gateway 使配置生效 ---
    info "  重启 OpenClaw gateway..."
    openclaw gateway restart 2>/dev/null || warn "gateway 重启失败，请手动运行: openclaw gateway restart"
    sleep 3

    # --- 6f: 启动 OpenClaw browser ---
    info "  启动 OpenClaw browser..."
    if openclaw browser start 2>/dev/null; then
        ok "OpenClaw browser 已启动"
    else
        # browser start 可能超时但实际已在工作，检查状态
        sleep 3
        if openclaw browser status 2>/dev/null | grep -qi "running"; then
            ok "OpenClaw browser 已启动（通过状态检查确认）"
        else
            warn "openclaw browser start 未成功，但 Chromium CDP 已在端口 ${CDP_PORT} 运行"
            warn "OpenClaw Agent 仍可通过 CDP 使用浏览器功能"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------

print_summary() {
    echo ""
    echo "============================================"
    echo "  微博自动化助手 — 安装完成 ✓"
    echo "============================================"
    echo ""
    echo "  Chromium:      $(${CHROMIUM_BIN} --version 2>/dev/null || echo 'N/A')"
    echo "  Playwright:    $(playwright --version 2>/dev/null || echo 'N/A')"
    echo "  CDP 端口:      ${CDP_PORT}"
    echo "  缓存目录:      ${PW_CACHE}/"
    echo "  Cookie 目录:   ${COOKIE_DIR}/"
    echo "  OpenClaw 配置: ${OPENCLAW_CONFIG}"
    echo ""
    echo "  浏览器服务:    ${SERVICE_NAME}.service"
    echo "    查看状态:    systemctl --user status ${SERVICE_NAME}"
    echo "    查看日志:    journalctl --user -u ${SERVICE_NAME} -f"
    echo ""
    echo "  下一步："
    echo "    在企业微信中对 OpenClaw 说「登录微博」即可开始！"
    echo ""
    echo "============================================"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

main() {
    echo ""
    echo "============================================"
    echo "  微博自动化助手 — 一键安装"
    echo "  镜像源: npmmirror（国内加速）"
    echo "============================================"
    echo ""

    preflight_check
    echo ""
    install_system_deps
    echo ""
    install_playwright
    echo ""
    install_chromium
    echo ""
    setup_data_dirs
    echo ""
    configure_openclaw
    echo ""
    setup_browser_service
    echo ""
    print_summary
}

main "$@"
