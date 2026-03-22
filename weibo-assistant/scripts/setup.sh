#!/usr/bin/env bash
# ============================================================================
# 微博自动化助手 — 环境安装脚本
# 适用于：Ubuntu 22.04+ / Debian 12+（其他 Linux 发行版需自行调整包名）
# 用途：在全新 OpenClaw 部署机上一键安装 Playwright + Chromium 运行环境
# 特点：全部使用国内镜像（npmmirror），无需科学上网
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 配置区（可根据实际情况修改）
# ---------------------------------------------------------------------------

# Playwright 对应的 Chromium 版本和 revision
# 查询方式：安装 playwright 后运行 `playwright install --dry-run` 或查看
# https://github.com/nicennnnnnnlee/playwright-browser-info
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

# Cookie 数据目录
COOKIE_DIR="${HOME}/.openclaw/data/weibo"

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

check_command() {
    command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Step 1: 安装系统依赖（Chromium 运行所需的共享库）
# ---------------------------------------------------------------------------

install_system_deps() {
    info "Step 1/4: 安装 Chromium 运行所需的系统依赖..."

    # 检测包管理器
    if check_command apt-get; then
        # apt-get update 允许部分源失败（如失效的 PPA），不阻塞安装流程
        sudo apt-get update -qq 2>&1 || warn "apt-get update 部分源失败（不影响安装，可稍后手动清理失效的 PPA）"
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
    else
        fail "不支持的系统：未找到 apt-get。请手动安装 Chromium 所需的系统依赖。"
    fi

    ok "系统依赖安装完成"
}

# ---------------------------------------------------------------------------
# Step 2: 安装 Python 版 Playwright
# ---------------------------------------------------------------------------

install_playwright() {
    info "Step 2/4: 安装 Python 版 Playwright..."

    if check_command playwright; then
        local current_version
        current_version=$(playwright --version 2>/dev/null | grep -oP '[\d.]+' || echo "unknown")
        ok "Playwright 已安装（版本: ${current_version}），跳过"
        return 0
    fi

    if ! check_command pip3; then
        info "  pip3 未找到，先安装 python3-pip..."
        sudo apt-get install -y -qq python3-pip python3-full || \
            fail "无法安装 pip3。请手动运行: sudo apt-get install python3-pip"
    fi

    # Ubuntu 24.04+ 默认启用 PEP 668（externally-managed-environment），
    # 禁止 pip 直接安装全局包。在服务器部署场景下，使用 --break-system-packages 绕过。
    pip3 install playwright --quiet 2>/dev/null || {
        warn "pip3 受 PEP 668 限制，使用 --break-system-packages 安装..."
        pip3 install playwright --quiet --break-system-packages
    }

    # 确认 playwright 命令可用（可能安装到 ~/.local/bin，需要刷新 PATH）
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
    info "Step 3/4: 从国内镜像下载并安装 Chromium..."

    # 检查是否已安装
    if [ -f "${CHROMIUM_DIR}/INSTALLATION_COMPLETE" ] && \
       [ -f "${HEADLESS_DIR}/INSTALLATION_COMPLETE" ] && \
       [ -x "${CHROMIUM_DIR}/chrome-linux64/chrome" ]; then
        local installed_version
        installed_version=$("${CHROMIUM_DIR}/chrome-linux64/chrome" --version 2>/dev/null || echo "unknown")
        ok "Chromium 已安装（${installed_version}），跳过"
        return 0
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    # 下载 Chromium
    info "  下载 Chrome for Testing ${CHROME_VERSION}（国内镜像: npmmirror）..."
    wget -q --show-progress -O "${tmp_dir}/chrome-linux64.zip" "${CHROME_URL}" || \
        fail "Chromium 下载失败。请检查网络连接或镜像地址。"

    # 下载 Headless Shell
    info "  下载 Chrome Headless Shell..."
    wget -q --show-progress -O "${tmp_dir}/chrome-headless-shell-linux64.zip" "${HEADLESS_SHELL_URL}" || \
        fail "Headless Shell 下载失败。"

    # 解压
    info "  解压到 Playwright 缓存目录..."
    mkdir -p "${CHROMIUM_DIR}" "${HEADLESS_DIR}"
    unzip -q -o "${tmp_dir}/chrome-linux64.zip" -d "${CHROMIUM_DIR}/"
    unzip -q -o "${tmp_dir}/chrome-headless-shell-linux64.zip" -d "${HEADLESS_DIR}/"

    # 写入安装标记（Playwright 依靠此文件判断是否已安装）
    echo "${CHROMIUM_REVISION}" > "${CHROMIUM_DIR}/INSTALLATION_COMPLETE"
    echo "${CHROMIUM_REVISION}" > "${HEADLESS_DIR}/INSTALLATION_COMPLETE"

    # 设置执行权限
    chmod +x "${CHROMIUM_DIR}/chrome-linux64/chrome"
    chmod +x "${HEADLESS_DIR}/chrome-headless-shell-linux64/chrome-headless-shell"

    # 创建软链接（OpenClaw 在 /usr/bin/chromium 等固定路径搜索浏览器）
    info "  创建 /usr/bin/chromium 软链接..."
    sudo ln -sf "${CHROMIUM_DIR}/chrome-linux64/chrome" /usr/bin/chromium

    # 清理临时文件
    rm -rf "${tmp_dir}"

    # 验证
    local version
    version=$(/usr/bin/chromium --version 2>/dev/null || echo "验证失败")
    ok "Chromium 安装完成（${version}）"
}

# ---------------------------------------------------------------------------
# Step 4: 创建数据目录
# ---------------------------------------------------------------------------

setup_data_dirs() {
    info "Step 4/4: 创建数据目录..."
    mkdir -p "${COOKIE_DIR}"
    ok "Cookie 数据目录: ${COOKIE_DIR}"
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------

print_summary() {
    echo ""
    echo "============================================"
    echo "  微博自动化助手 — 环境安装完成"
    echo "============================================"
    echo ""
    echo "  Chromium:    $(chromium --version 2>/dev/null || echo 'N/A')"
    echo "  Playwright:  $(playwright --version 2>/dev/null || echo 'N/A')"
    echo "  缓存目录:    ${PW_CACHE}/"
    echo "  数据目录:    ${COOKIE_DIR}/"
    echo ""
    echo "  接下来请手动配置 OpenClaw："
    echo ""
    echo "    # 启用浏览器（headless 无头模式）"
    echo "    openclaw config set browser.enabled true"
    echo "    openclaw config set browser.headless true"
    echo "    openclaw config set browser.noSandbox true"
    echo ""
    echo "    # 设置默认 profile 为 openclaw（非 chrome 扩展模式）"
    echo "    openclaw config set browser.defaultProfile openclaw"
    echo ""
    echo "    # 注意：profile 的 color 和 cdpPort 必须同时写入，"
    echo "    # 无法通过 openclaw config set 逐个设置，需直接编辑配置文件："
    echo '    python3 -c "'
    echo "    import json, pathlib"
    echo "    p = pathlib.Path.home() / '.openclaw/openclaw.json'"
    echo "    cfg = json.loads(p.read_text())"
    echo "    cfg.setdefault('browser', {}).setdefault('profiles', {})['openclaw'] = {'color': '#4A90D9', 'cdpPort': 18800}"
    echo "    p.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))"
    echo "    print('browser profile openclaw 已写入')"
    echo '    "'
    echo ""
    echo "    # 切换到 full 工具集（coding 模式不含 browser 工具）"
    echo "    openclaw config set tools.profile full"
    echo ""
    echo "    # 重启生效"
    echo "    openclaw gateway restart"
    echo "    openclaw browser start"
    echo ""
    echo "  然后在企业微信中对 OpenClaw 说「登录微博」即可开始。"
    echo "============================================"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

main() {
    echo ""
    info "微博自动化助手 — 环境安装脚本"
    info "镜像源: npmmirror（国内加速）"
    echo ""

    install_system_deps
    install_playwright
    install_chromium
    setup_data_dirs
    print_summary
}

main "$@"
