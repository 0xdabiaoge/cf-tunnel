#!/bin/sh

# 自举逻辑：确保在 Alpine 上使用 Bash
if [ -z "$BASH_VERSION" ]; then
    if [ -f /etc/alpine-release ]; then
        # 检查是否已安装 bash
        if ! command -v bash >/dev/null 2>&1; then
            echo "正在为 Alpine 安装 Bash..."
            apk update && apk add --no-cache bash
        fi
    fi
    # 切换到 Bash 执行
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        echo "错误: 未找到 Bash，且无法自动安装。请手动安装 (apk add bash) 后重试。"
        exit 1
    fi
fi

# ============================================================================
# Cloudflare Tunnel 部署脚本
# 支持: Debian/Ubuntu, Alpine Linux
# 架构: amd64, arm64
# 作者: Auto-generated
# ============================================================================

# set -e  # 移除全局严格模式以提高交互稳定性

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CONFIG_DIR="/etc/cloudflared"
TOKEN_FILE="${CONFIG_DIR}/token"

# ============================================================================
# 工具函数
# ============================================================================

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用 sudo 或以 root 用户运行"
    fi
}

execute_dns_route() {
    local tunnel_name="$1"
    local hostname="$2"
    
    while true; do
        print_info "正在配置 DNS 记录 ($hostname -> $tunnel_name)..."
        
        # 捕获输出用于错误分析
        local output
        output=$(cloudflared tunnel route dns "$tunnel_name" "$hostname" 2>&1)
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            print_success "DNS 记录配置成功"
            return 0
        fi
        
        # 检查是否为 DNS 记录已存在错误 (Code 1003 或 text match)
        if echo "$output" | grep -qE "1003|already exists"; then
            echo ""
            print_error "DNS 记录冲突: 域名 $hostname 已存在 CNAME 记录"
            echo -e "${YELLOW}请前往 Cloudflare Dashboard (https://dash.cloudflare.com) 手动删除该域名的旧记录。${NC}"
            echo ""
            
            read -p "删除完成后，是否重试? [Y/n] (默认 Y): " retry
            retry=${retry:-Y}
            
            if [[ "$retry" =~ ^[Yy]$ ]]; then
                echo ""
                continue
            else
                print_warning "已放弃 DNS 配置"
                return 1
            fi
        else
            # 其他错误直接显示
            print_error "DNS 配置失败: $output"
            return 1
        fi
    done
}

# ============================================================================
# 系统检测
# ============================================================================

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_NAME="$NAME"
    elif [ -f /etc/alpine-release ]; then
        OS_ID="alpine"
        OS_NAME="Alpine Linux"
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"
        OS_NAME="Debian"
    else
        print_error "无法识别的操作系统"
        exit 1
    fi

    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop)
            OS_TYPE="debian"
            SERVICE_MANAGER="systemd"
            ;;
        alpine)
            OS_TYPE="alpine"
            SERVICE_MANAGER="openrc"
            ;;
        *)
            print_error "不支持的操作系统: $OS_ID"
            print_info "此脚本仅支持 Debian/Ubuntu 和 Alpine Linux"
            exit 1
            ;;
    esac

    print_info "检测到系统: $OS_NAME ($OS_TYPE)"
    
    # 再次确认服务管理器
    if [ "$OS_TYPE" = "debian" ] && ! command -v systemctl >/dev/null 2>&1; then
        print_warning "未检测到 systemd，将尝试使用 init.d (可能不完全支持)"
        SERVICE_MANAGER="sysv" # 脚本目前主要处理 systemd/openrc，这里仅做提示
    fi
    print_info "服务管理器: $SERVICE_MANAGER"
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ARCH_TYPE="amd64"
            ;;
        aarch64|arm64)
            ARCH_TYPE="arm64"
            ;;
        *)
            print_error "不支持的 CPU 架构: $ARCH"
            print_info "此脚本仅支持 amd64 和 arm64 架构"
            exit 1
            ;;
    esac
    print_info "检测到架构: $ARCH_TYPE"
}

check_cloudflared_installed() {
    if command -v cloudflared &> /dev/null; then
        return 0
    elif [ -f "$CLOUDFLARED_BIN" ]; then
        return 0
    else
        return 1
    fi
}

get_installed_version() {
    if check_cloudflared_installed; then
        cloudflared --version 2>/dev/null | head -n1 | awk '{print $3}' || echo "未知"
    else
        echo "未安装"
    fi
}

get_latest_version() {
    curl -s "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" | \
        grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || echo ""
}

# ============================================================================
# 安装功能
# ============================================================================

install_dependencies() {
    print_info "安装依赖..."
    
    if [ "$OS_TYPE" = "debian" ]; then
        apt-get update -qq
        apt-get install -y -qq curl wget ca-certificates
    elif [ "$OS_TYPE" = "alpine" ]; then
        apk update --quiet
        apk add --quiet curl wget ca-certificates
    fi
    
    print_success "依赖安装完成"
}

download_cloudflared() {
    local version="$1"
    local download_url=""
    local temp_file=""
    
    print_info "正在下载 cloudflared $version..."
    
    if [ "$OS_TYPE" = "debian" ]; then
        # Debian 使用 deb 包
        download_url="https://github.com/cloudflare/cloudflared/releases/download/${version}/cloudflared-linux-${ARCH_TYPE}.deb"
        temp_file="/tmp/cloudflared.deb"
        
        if ! curl -L -o "$temp_file" "$download_url" --progress-bar; then
            print_error "下载失败"
            return 1
        fi
        
        print_info "安装 deb 包..."
        dpkg -i "$temp_file" || apt-get install -f -y
        rm -f "$temp_file"
        
    elif [ "$OS_TYPE" = "alpine" ]; then
        # Alpine 使用二进制文件
        download_url="https://github.com/cloudflare/cloudflared/releases/download/${version}/cloudflared-linux-${ARCH_TYPE}"
        
        if ! curl -L -o "$CLOUDFLARED_BIN" "$download_url" --progress-bar; then
            print_error "下载失败"
            return 1
        fi
        
        chmod +x "$CLOUDFLARED_BIN"
    fi
    
    print_success "cloudflared 安装成功"
}

install_cloudflared() {
    echo ""
    print_info "========== 安装 cloudflared =========="
    
    if check_cloudflared_installed; then
        local installed_ver=$(get_installed_version)
        print_warning "cloudflared 已安装 (版本: $installed_ver)"
        read -p "是否重新安装? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "取消安装"
            return 0
        fi
    fi
    
    install_dependencies
    
    local latest_version=$(get_latest_version)
    if [ -z "$latest_version" ]; then
        print_error "无法获取最新版本信息"
        read -p "请手动输入版本号 (例如 2024.1.0): " latest_version
        if [ -z "$latest_version" ]; then
            print_error "版本号不能为空"
            return 1
        fi
    fi
    
    print_info "最新版本: $latest_version"
    download_cloudflared "$latest_version" || {
        print_error "下载失败，退出安装"
        return 1
    }
    
    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    
    print_success "安装完成!"
    print_info "版本: $(get_installed_version)"
}

# ============================================================================
# 认证配置
# ============================================================================

auth_menu() {
    echo ""
    print_info "========== 配置隧道认证 =========="
    
    if ! check_cloudflared_installed; then
        print_error "cloudflared 未安装，请先安装"
        return 1
    fi
    
    echo ""
    echo -e "${CYAN}请选择认证方式:${NC}"
    echo ""
    echo "  1. Tunnel Token (推荐)"
    echo "     - 从 Cloudflare Dashboard 复制 Token"
    echo "     - 适合已在 Dashboard 创建好 Tunnel 的用户"
    echo ""
    echo "  2. 浏览器授权登录"
    echo "     - 通过浏览器登录 Cloudflare 账户授权"
    echo "     - 适合首次配置或无头服务器"
    echo ""
    echo "  0. 返回主菜单"
    echo ""
    read -p "请选择 [0-2]: " choice
    
    case $choice in
        1) configure_token ;;
        2) configure_browser_login ;;
        0) return ;;
        *) print_error "无效选项" ;;
    esac
}

configure_token() {
    echo ""
    print_info "========== 配置 Tunnel Token =========="
    
    # 显示当前 Token 状态
    if [ -f "$TOKEN_FILE" ]; then
        print_warning "已存在 Token 配置"
        read -p "是否覆盖? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "取消配置"
            return 0
        fi
    fi
    
    echo ""
    print_info "请从 Cloudflare Dashboard 获取 Tunnel Token:"
    print_info "  1. 登录 Cloudflare Dashboard"
    print_info "  2. 进入 Zero Trust -> Networks -> Tunnels"
    print_info "  3. 创建或选择一个 Tunnel"
    print_info "  4. 复制 Token (格式: eyJ...)"
    echo ""
    
    read -p "请输入 Tunnel Token: " token
    
    if [ -z "$token" ]; then
        print_error "Token 不能为空"
        return 1
    fi
    
    # 验证 Token 格式 (基本检查)
    if [[ ! "$token" =~ ^eyJ ]]; then
        print_warning "Token 格式可能不正确 (应以 'eyJ' 开头)"
        read -p "是否继续? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    # 保存 Token
    mkdir -p "$CONFIG_DIR"
    echo "$token" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    
    print_success "Token 已保存"
    
    # 配置服务
    configure_service "$token"
}

configure_browser_login() {
    echo ""
    print_info "========== 浏览器授权登录 =========="
    echo ""
    
    # 检查是否已有证书
    local cert_file="$HOME/.cloudflared/cert.pem"
    if [ -f "$cert_file" ]; then
        print_warning "已存在登录证书: $cert_file"
        read -p "是否重新登录? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "取消登录"
            return 0
        fi
    fi
    
    echo ""
    print_info "即将启动浏览器授权流程..."
    print_info "cloudflared 会生成一个授权链接"
    echo ""
    print_warning "如果是无头服务器 (无浏览器):"
    echo "  1. 复制终端显示的 URL"
    echo "  2. 在本地电脑浏览器中打开该 URL"
    echo "  3. 登录 Cloudflare 并选择域名"
    echo "  4. 授权完成后，服务器会自动收到证书"
    echo ""
    
    read -p "按回车键开始授权..." _
    
    echo ""
    print_info "正在启动授权..."
    echo ""
    
    # 运行 cloudflared tunnel login
    if cloudflared tunnel login; then
        print_success "授权成功!"
        print_info "证书已保存到: $cert_file"
        echo ""
        
        # 询问是否创建隧道
        read -p "是否现在创建新的 Tunnel? [y/N]: " create_tunnel
        if [[ "$create_tunnel" =~ ^[Yy]$ ]]; then
            create_new_tunnel
        fi
    else
        print_error "授权失败，请重试"
        return 1
    fi
}

create_new_tunnel() {
    echo ""
    print_info "========== 创建新 Tunnel =========="
    echo ""
    
    read -p "请输入 Tunnel 名称: " tunnel_name
    
    if [ -z "$tunnel_name" ]; then
        print_error "名称不能为空"
        return 1
    fi
    
    print_info "正在创建 Tunnel: $tunnel_name"
    
    if cloudflared tunnel create "$tunnel_name"; then
        print_success "Tunnel 创建成功!"
        echo ""
        
        # 获取 Tunnel ID
        local tunnel_id=$(cloudflared tunnel list | grep "$tunnel_name" | awk '{print $1}')
        
        if [ -n "$tunnel_id" ]; then
            print_info "Tunnel ID: $tunnel_id"
            print_info "Tunnel 名称: $tunnel_name"
            echo ""
            
            # 创建配置文件
            read -p "是否创建配置文件? [y/N]: " create_config
            if [[ "$create_config" =~ ^[Yy]$ ]]; then
                create_tunnel_config "$tunnel_id" "$tunnel_name"
            fi
        fi
    else
        print_error "创建失败，请检查是否已存在同名 Tunnel"
        return 1
    fi
}

create_tunnel_config() {
    local tunnel_id="$1"
    local tunnel_name="$2"
    
    echo ""
    print_info "========== 配置 Tunnel =========="
    echo ""
    
    local config_file="$CONFIG_DIR/config.yml"
    mkdir -p "$CONFIG_DIR"
    
    # 获取 credentials 文件路径
    local cred_file="$HOME/.cloudflared/${tunnel_id}.json"
    
    if [ ! -f "$cred_file" ]; then
        print_warning "未找到 credentials 文件"
        cred_file=""
    fi
    
    # 询问入口配置
    echo "请配置第一个入口 (ingress):"
    read -p "  域名 (如 app.example.com): " hostname
    read -p "  本地服务 (如 http://localhost:8080 或直接输入端口号): " service
    
    if [ -z "$hostname" ] || [ -z "$service" ]; then
        print_error "域名和服务不能为空"
        return 1
    fi
    
    # 服务地址格式验证和自动补全
    if [[ "$service" =~ ^[0-9]+$ ]]; then
        # 如果只输入了端口号，自动补全为 http://localhost:端口
        service="http://localhost:$service"
        print_info "已自动补全服务地址: $service"
    elif [[ ! "$service" =~ ^(http|https|tcp|ssh|rdp|unix):// ]]; then
        print_warning "服务地址格式可能不正确"
        print_info "正确格式示例: http://localhost:8080, ssh://localhost:22"
        read -p "是否继续? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    # 生成配置文件
    cat > "$config_file" << EOF
tunnel: ${tunnel_id}
credentials-file: ${cred_file:-/root/.cloudflared/${tunnel_id}.json}

ingress:
  - hostname: ${hostname}
    service: ${service}
  - service: http_status:404
EOF
    
    print_success "配置文件已创建: $config_file"
    echo ""
    print_info "配置内容:"
    cat "$config_file"
    echo ""
    
    # 配置 DNS
    read -p "是否为 $hostname 配置 DNS 记录? [y/N]: " setup_dns
    if [[ "$setup_dns" =~ ^[Yy]$ ]]; then
    if [[ "$setup_dns" =~ ^[Yy]$ ]]; then
        execute_dns_route "$tunnel_name" "$hostname"
    fi
    fi
    
    # 配置服务
    echo ""
    read -p "是否配置为系统服务并启动? [y/N]: " setup_service
    if [[ "$setup_service" =~ ^[Yy]$ ]]; then
        configure_tunnel_service
    fi
}

configure_tunnel_service() {
    print_info "配置系统服务..."
    
    local config_file="$CONFIG_DIR/config.yml"
    
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        # 使用 cloudflared 配置文件方式
        cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --config ${config_file} run
Restart=on-failure
RestartSec=5
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable cloudflared
        systemctl start cloudflared || true
        
        sleep 2
        
        if systemctl is-active --quiet cloudflared; then
            print_success "服务已启动并设置为开机自启"
        else
            print_error "服务启动失败，请检查日志: journalctl -u cloudflared"
            echo ""
            print_info "尝试手动运行以查看详细错误:"
            echo "  cloudflared tunnel --config ${config_file} run"
        fi
        
    elif [ "$SERVICE_MANAGER" = "openrc" ]; then
        cat > /etc/init.d/cloudflared << EOF
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate --config ${config_file} run"
command_background=true
pidfile="/run/\${name}.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --file --owner root:root --mode 0644 "\$output_log"
    checkpath --file --owner root:root --mode 0644 "\$error_log"
}
EOF
        
        chmod +x /etc/init.d/cloudflared
        rc-update add cloudflared default
        rc-service cloudflared start || true
        
        sleep 2
        
        if rc-service cloudflared status | grep -q "started"; then
            print_success "服务已启动并设置为开机自启"
        else
            print_error "服务启动失败，请检查日志: /var/log/cloudflared.log"
        fi
    fi
}

list_tunnels() {
    echo ""
    print_info "========== 已有 Tunnels =========="
    echo ""
    
    if [ -f "$HOME/.cloudflared/cert.pem" ]; then
        cloudflared tunnel list || print_warning "无法获取 Tunnel 列表"
    else
        print_warning "未登录，请先使用浏览器授权登录"
    fi
    
    echo ""
    read -p "按回车键继续..."
}

# ============================================================================
# 域名/入口管理
# ============================================================================

hostname_menu() {
    echo ""
    print_info "========== 域名管理 =========="
    
    if ! check_cloudflared_installed; then
        print_error "cloudflared 未安装"
        return 1
    fi
    
    echo ""
    echo -e "${CYAN}请选择配置方式:${NC}"
    echo ""
    echo "  1. Dashboard 配置 (Tunnel Token 用户)"
    echo "     - 在 Cloudflare 网页上可视化配置"
    echo ""
    echo "  2. 配置文件管理 (浏览器授权用户)"
    echo "     - 添加/查看/删除 ingress 规则"
    echo ""
    echo "  3. 添加 DNS 路由"
    echo "     - 为子域名创建 CNAME 记录"
    echo ""
    echo "  0. 返回主菜单"
    echo ""
    read -p "请选择 [0-3]: " choice
    
    case $choice in
        1) show_dashboard_guide ;;
        2) ingress_menu ;;
        3) add_dns_route ;;
        0) return ;;
        *) print_error "无效选项" ;;
    esac
}

show_dashboard_guide() {
    echo ""
    print_info "========== Dashboard 配置指南 =========="
    echo ""
    echo -e "${CYAN}如果您使用 Tunnel Token 方式，请在 Dashboard 配置域名：${NC}"
    echo ""
    echo "  1. 打开 https://one.dash.cloudflare.com"
    echo "  2. 点击 Networks → Tunnels"
    echo "  3. 点击您的隧道名称"
    echo "  4. 选择 'Public Hostname' 标签"
    echo "  5. 点击 'Add a public hostname'"
    echo ""
    echo "  配置示例："
    echo "  ┌─────────────────────────────────────────────────────┐"
    echo "  │ Subdomain: app          Domain: example.com         │"
    echo "  │                                                     │"
    echo "  │ Service Type: HTTP      URL: localhost:3000         │"
    echo "  └─────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${YELLOW}常用服务类型：${NC}"
    echo "  HTTP   - http://localhost:端口   (Web 服务)"
    echo "  HTTPS  - https://localhost:端口  (加密 Web)"
    echo "  SSH    - ssh://localhost:22      (SSH 服务)"
    echo "  RDP    - rdp://localhost:3389    (远程桌面)"
    echo "  TCP    - tcp://localhost:端口    (通用 TCP)"
    echo ""
    read -p "按回车键继续..."
}

ingress_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}========== 配置文件管理 ==========${NC}"
        echo ""
        echo "  1. 查看当前配置"
        echo "  2. 添加入口规则"
        echo "  3. 重新生成配置"
        echo "  4. 验证配置"
        echo "  0. 返回"
        echo ""
        read -p "请选择 [0-4]: " choice
        
        case $choice in
            1) view_config ;;
            2) add_ingress ;;
            3) regenerate_config ;;
            4) validate_config ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
    done
}

view_config() {
    echo ""
    local config_file="$CONFIG_DIR/config.yml"
    
    if [ -f "$config_file" ]; then
        print_info "当前配置文件: $config_file"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────${NC}"
        cat "$config_file"
        echo -e "${CYAN}────────────────────────────────────────${NC}"
    else
        print_warning "配置文件不存在: $config_file"
        print_info "如果您使用 Tunnel Token，配置在 Dashboard 管理"
    fi
    
    echo ""
    read -p "按回车键继续..."
}

add_ingress() {
    echo ""
    print_info "========== 添加入口规则 =========="
    echo ""
    
    local config_file="$CONFIG_DIR/config.yml"
    
    # 检查配置文件是否存在
    if [ ! -f "$config_file" ]; then
        print_warning "配置文件不存在，请先创建隧道"
        read -p "按回车键继续..."
        return 1
    fi
    
    # 获取域名
    read -p "请输入完整域名 (如 app.example.com): " hostname
    if [ -z "$hostname" ]; then
        print_error "域名不能为空"
        return 1
    fi
    
    # 选择服务类型
    echo ""
    echo "选择服务类型："
    echo "  1. HTTP  (http://localhost:端口)"
    echo "  2. HTTPS (https://localhost:端口)"
    echo "  3. SSH   (ssh://localhost:22)"
    echo "  4. TCP   (tcp://localhost:端口)"
    echo "  5. 自定义"
    echo ""
    read -p "请选择 [1-5]: " type_choice
    
    local service=""
    case $type_choice in
        1)
            read -p "请输入端口号: " port
            service="http://localhost:$port"
            ;;
        2)
            read -p "请输入端口号: " port
            service="https://localhost:$port"
            ;;
        3)
            service="ssh://localhost:22"
            ;;
        4)
            read -p "请输入端口号: " port
            service="tcp://localhost:$port"
            ;;
        5)
            read -p "请输入完整服务地址: " service
            ;;
        *)
            print_error "无效选项"
            return 1
            ;;
    esac
    
    if [ -z "$service" ]; then
        print_error "服务地址不能为空"
        return 1
    fi
    
    # 备份原配置
    cp "$config_file" "${config_file}.bak"
    
    # 在最后一行 (- service: http_status:404) 之前插入新规则
    # 使用 sed 在包含 "http_status:404" 的行之前插入
    local new_rule="  - hostname: ${hostname}\n    service: ${service}"
    
    if grep -q "http_status:404" "$config_file"; then
        sed -i "/http_status:404/i\\  - hostname: ${hostname}\\n    service: ${service}" "$config_file"
    else
        # 如果没有默认规则，追加到文件末尾
        echo "" >> "$config_file"
        echo "  - hostname: ${hostname}" >> "$config_file"
        echo "    service: ${service}" >> "$config_file"
    fi
    
    print_success "规则已添加!"
    echo ""
    print_info "新增规则："
    echo "  域名: $hostname"
    echo "  服务: $service"
    echo ""
    
    # 询问是否添加 DNS 路由
    read -p "是否为 $hostname 添加 DNS 路由? [y/N]: " add_dns
    if [[ "$add_dns" =~ ^[Yy]$ ]]; then
        local tunnel_name=$(grep "^tunnel:" "$config_file" | awk '{print $2}')
        if [ -n "$tunnel_name" ]; then
        if [ -n "$tunnel_name" ]; then
            execute_dns_route "$tunnel_name" "$hostname"
        fi
        fi
    fi
    
    # 询问是否重启服务
    read -p "是否重启服务使配置生效? [y/N]: " restart
    if [[ "$restart" =~ ^[Yy]$ ]]; then
        service_restart
    fi
}

regenerate_config() {
    echo ""
    print_info "========== 重新生成配置文件 =========="
    echo ""
    
    local config_file="$CONFIG_DIR/config.yml"
    
    # 检查是否有证书
    if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
        print_error "未登录，请先使用浏览器授权登录"
        read -p "按回车键继续..."
        return 1
    fi
    
    # 获取隧道列表
    echo "可用的 Tunnels："
    cloudflared tunnel list 2>/dev/null || {
        print_error "无法获取隧道列表"
        return 1
    }
    echo ""
    
    read -p "请输入要配置的 Tunnel ID 或名称: " tunnel_id
    if [ -z "$tunnel_id" ]; then
        print_error "Tunnel ID 不能为空"
        return 1
    fi
    
    # 查找 credentials 文件
    local cred_file=$(find "$HOME/.cloudflared" -name "*.json" 2>/dev/null | head -1)
    
    # 备份旧配置
    if [ -f "$config_file" ]; then
        cp "$config_file" "${config_file}.bak.$(date +%Y%m%d%H%M%S)"
        print_info "旧配置已备份"
    fi
    
    mkdir -p "$CONFIG_DIR"
    
    echo "现在配置入口规则 (ingress)："
    echo ""
    
    # 创建配置文件头部
    cat > "$config_file" << EOF
tunnel: ${tunnel_id}
credentials-file: ${cred_file:-$HOME/.cloudflared/${tunnel_id}.json}

ingress:
EOF
    
    # 循环添加规则
    while true; do
        read -p "添加域名 (留空结束): " hostname
        if [ -z "$hostname" ]; then
            break
        fi
        
        read -p "  本地服务地址 (如 http://localhost:8080): " service
        if [ -z "$service" ]; then
            print_warning "跳过此规则"
            continue
        fi
        
        echo "  - hostname: ${hostname}" >> "$config_file"
        echo "    service: ${service}" >> "$config_file"
        
        print_success "已添加: $hostname -> $service"
        echo ""
    done
    
    # 添加默认规则
    echo "  - service: http_status:404" >> "$config_file"
    
    echo ""
    print_success "配置文件已生成!"
    echo ""
    print_info "配置内容："
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    cat "$config_file"
    echo -e "${CYAN}────────────────────────────────────────${NC}"
    
    echo ""
    read -p "按回车键继续..."
}

validate_config() {
    echo ""
    print_info "========== 验证配置 =========="
    echo ""
    
    local config_file="$CONFIG_DIR/config.yml"
    
    if [ ! -f "$config_file" ]; then
        print_warning "配置文件不存在"
        read -p "按回车键继续..."
        return 1
    fi
    
    print_info "正在验证配置..."
    echo ""
    
    if cloudflared tunnel ingress validate --config "$config_file" 2>&1; then
        print_success "配置验证通过!"
    else
        print_error "配置验证失败，请检查配置文件"
    fi
    
    echo ""
    read -p "按回车键继续..."
}

add_dns_route() {
    echo ""
    print_info "========== 添加 DNS 路由 =========="
    echo ""
    
    # 检查是否登录
    if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
        print_warning "未登录，此功能需要浏览器授权登录"
        print_info "如果您使用 Token 方式，请在 Dashboard 配置域名"
        read -p "按回车键继续..."
        return 1
    fi
    
    # 显示隧道列表
    echo "可用的 Tunnels："
    cloudflared tunnel list 2>/dev/null || {
        print_error "无法获取隧道列表"
        return 1
    }
    echo ""
    
    read -p "请输入 Tunnel 名称: " tunnel_name
    if [ -z "$tunnel_name" ]; then
        print_error "名称不能为空"
        return 1
    fi
    
    read -p "请输入要路由的域名 (如 app.example.com): " hostname
    if [ -z "$hostname" ]; then
        print_error "域名不能为空"
        return 1
    fi
    
    execute_dns_route "$tunnel_name" "$hostname"
    
    echo ""
    read -p "按回车键继续..."
}

configure_service() {
    local token="$1"
    
    print_info "配置系统服务..."
    
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        configure_systemd_service "$token"
    elif [ "$SERVICE_MANAGER" = "openrc" ]; then
        configure_openrc_service "$token"
    fi
}

configure_systemd_service() {
    local token="$1"
    
    # 停止现有服务
    systemctl stop cloudflared 2>/dev/null || true
    
    # 使用官方方式安装服务
    cloudflared service install "$token" 2>/dev/null || {
        # 如果官方命令失败，手动创建服务文件
        print_warning "官方安装命令失败，尝试手动配置..."
        
        cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${token}
Restart=on-failure
RestartSec=5
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    }
    
    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl start cloudflared || true
    
    sleep 2
    
    if systemctl is-active --quiet cloudflared; then
        print_success "服务已启动并设置为开机自启"
    else
        print_error "服务启动失败，请检查日志: journalctl -u cloudflared"
    fi
}

configure_openrc_service() {
    local token="$1"
    
    # 停止现有服务
    rc-service cloudflared stop 2>/dev/null || true
    
    # 创建 OpenRC 服务脚本
    cat > /etc/init.d/cloudflared << 'EOF'
#!/sbin/openrc-run

name="cloudflared"
description="Cloudflare Tunnel"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate run --token $(cat /etc/cloudflared/token)"
command_background=true
pidfile="/run/${name}.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --file --owner root:root --mode 0644 "$output_log"
    checkpath --file --owner root:root --mode 0644 "$error_log"
}
EOF
    
    chmod +x /etc/init.d/cloudflared
    
    rc-update add cloudflared default
    rc-service cloudflared start || true
    
    sleep 2
    
    if rc-service cloudflared status | grep -q "started"; then
        print_success "服务已启动并设置为开机自启"
    else
        print_error "服务启动失败，请检查日志: /var/log/cloudflared.log"
    fi
}

# ============================================================================
# 服务管理
# ============================================================================

service_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}========== 服务管理 ==========${NC}"
        echo "1. 启动服务"
        echo "2. 停止服务"
        echo "3. 重启服务"
        echo "4. 查看服务状态"
        echo "5. 启用开机自启"
        echo "6. 禁用开机自启"
        echo "0. 返回主菜单"
        echo ""
        read -p "请选择操作 [0-6]: " choice
        
        case $choice in
            1) service_start ;;
            2) service_stop ;;
            3) service_restart ;;
            4) service_status ;;
            5) service_enable ;;
            6) service_disable ;;
            0) return ;;
            *) print_error "无效选项" ;;
        esac
    done
}

service_start() {
    print_info "启动服务..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl start cloudflared && print_success "服务已启动" || print_error "启动失败"
    else
        rc-service cloudflared start && print_success "服务已启动" || print_error "启动失败"
    fi
}

service_stop() {
    print_info "停止服务..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl stop cloudflared && print_success "服务已停止" || print_error "停止失败"
    else
        rc-service cloudflared stop && print_success "服务已停止" || print_error "停止失败"
    fi
}

service_restart() {
    print_info "重启服务..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl restart cloudflared && print_success "服务已重启" || print_error "重启失败"
    else
        rc-service cloudflared restart && print_success "服务已重启" || print_error "重启失败"
    fi
}

service_status() {
    echo ""
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl status cloudflared --no-pager || true
    else
        rc-service cloudflared status || true
    fi
}

service_enable() {
    print_info "启用开机自启..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl enable cloudflared && print_success "已启用开机自启" || print_error "操作失败"
    else
        rc-update add cloudflared default && print_success "已启用开机自启" || print_error "操作失败"
    fi
}

service_disable() {
    print_info "禁用开机自启..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl disable cloudflared && print_success "已禁用开机自启" || print_error "操作失败"
    else
        rc-update del cloudflared default && print_success "已禁用开机自启" || print_error "操作失败"
    fi
}

# ============================================================================
# 查看状态
# ============================================================================

show_status() {
    echo ""
    print_info "========== 系统状态 =========="
    echo ""
    
    echo -e "${CYAN}系统信息:${NC}"
    echo "  操作系统: $OS_NAME ($OS_TYPE)"
    echo "  CPU 架构: $ARCH_TYPE"
    echo "  服务管理: $SERVICE_MANAGER"
    echo ""
    
    echo -e "${CYAN}cloudflared 状态:${NC}"
    if check_cloudflared_installed; then
        echo "  安装状态: 已安装"
        echo "  当前版本: $(get_installed_version)"
        echo "  最新版本: $(get_latest_version)"
    else
        echo "  安装状态: 未安装"
    fi
    echo ""
    
    echo -e "${CYAN}Token 配置:${NC}"
    if [ -f "$TOKEN_FILE" ]; then
        local token_preview=$(head -c 20 "$TOKEN_FILE")...
        echo "  状态: 已配置"
        echo "  Token: ${token_preview}"
    else
        echo "  状态: 未配置"
    fi
    echo ""
    
    echo -e "${CYAN}服务状态:${NC}"
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        if systemctl is-active --quiet cloudflared 2>/dev/null; then
            echo -e "  运行状态: ${GREEN}运行中${NC}"
        else
            echo -e "  运行状态: ${RED}未运行${NC}"
        fi
        if systemctl is-enabled --quiet cloudflared 2>/dev/null; then
            echo -e "  开机自启: ${GREEN}已启用${NC}"
        else
            echo -e "  开机自启: ${YELLOW}未启用${NC}"
        fi
    else
        if rc-service cloudflared status 2>/dev/null | grep -q "started"; then
            echo -e "  运行状态: ${GREEN}运行中${NC}"
        else
            echo -e "  运行状态: ${RED}未运行${NC}"
        fi
        if rc-update show default 2>/dev/null | grep -q cloudflared; then
            echo -e "  开机自启: ${GREEN}已启用${NC}"
        else
            echo -e "  开机自启: ${YELLOW}未启用${NC}"
        fi
    fi
    
    echo ""
    read -p "按回车键继续..."
}

# ============================================================================
# 更新功能
# ============================================================================

update_cloudflared() {
    echo ""
    print_info "========== 更新 cloudflared =========="
    
    if ! check_cloudflared_installed; then
        print_error "cloudflared 未安装"
        return 1
    fi
    
    local current_version=$(get_installed_version)
    local latest_version=$(get_latest_version)
    
    print_info "当前版本: $current_version"
    print_info "最新版本: $latest_version"
    
    if [ "$current_version" = "$latest_version" ]; then
        print_success "已是最新版本，无需更新"
        return 0
    fi
    
    read -p "是否更新到最新版本? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "取消更新"
        return 0
    fi
    
    # 停止服务
    print_info "停止服务..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl stop cloudflared 2>/dev/null || true
    else
        rc-service cloudflared stop 2>/dev/null || true
    fi
    
    # 下载新版本
    download_cloudflared "$latest_version" || {
        print_error "下载失败，尝试重启旧服务..."
        service_start
        return 1
    }
    
    # 启动服务
    print_info "重新启动服务..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl start cloudflared || true
    else
        rc-service cloudflared start || true
    fi
    
    print_success "更新完成!"
    print_info "新版本: $(get_installed_version)"
}

# ============================================================================
# 卸载功能
# ============================================================================

uninstall_cloudflared() {
    echo ""
    print_info "========== 卸载 cloudflared =========="
    
    if ! check_cloudflared_installed; then
        print_warning "cloudflared 未安装"
        # 即使未安装，也可能需要清理残留文件和脚本本身
    fi
    
    echo ""
    print_warning "此操作将执行彻底清理:"
    echo "  1. 停止并移除 cloudflared 系统服务"
    echo "  2. 删除 cloudflared 主程序"
    echo "  3. 删除 所有配置文件、证书和日志 (/etc/cloudflared, ~/.cloudflared, /var/log/cloudflared*)"
    echo "  4. 删除 本脚本文件自身"
    echo ""
    print_error "警告：此操作不可逆！您的所有隧道配置都将丢失。"
    echo ""
    
    read -p "确定要彻底卸载吗? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "取消卸载"
        return 0
    fi

    # 0. 尝试删除云端隧道 (必须在删除程序前进行)
    print_info "检查云端隧道配置..."
    local config_file="$CONFIG_DIR/config.yml"
    local cert_file="$HOME/.cloudflared/cert.pem"
    local tunnel_id=""

    # 尝试从配置文件获取 Tunnel ID
    if [ -f "$config_file" ]; then
        tunnel_id=$(grep "^tunnel:" "$config_file" | awk '{print $2}' | tr -d ' "')
    fi

    if [ -n "$tunnel_id" ] && [ -f "$cert_file" ]; then
        print_info "发现本地配置的 Tunnel ID: $tunnel_id"
        print_warning "是否同时删除 Cloudflare 账号中的这个隧道?"
        echo "注意: 这将使该隧道永久失效。"
        read -p "确认删除云端隧道? [y/N]: " del_remote
        
        if [[ "$del_remote" =~ ^[Yy]$ ]]; then
            print_info "正在尝试删除云端隧道..."
            if cloudflared tunnel delete -f "$tunnel_id"; then
                print_success "云端隧道已删除"
            else
                print_error "删除失败 (可能是网络问题或权限不足)"
            fi
        else
            print_info "跳过删除云端隧道"
        fi
    elif [ -n "$tunnel_id" ]; then
        # 有 ID 但没有证书 (Token 模式)
        print_warning "提示: 检测到 Tunnel ID ($tunnel_id)，但未发现管理证书 (cert.pem)"
        print_info "您似乎通过 Token 方式运行，无法通过脚本自动删除云端隧道。"
        print_info "请登录 Cloudflare Dashboard 手动删除该隧道。"
    fi

    echo ""
    
    # 1. 停止并禁用服务
    print_info "正在停止服务..."
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        systemctl stop cloudflared 2>/dev/null || true
        systemctl disable cloudflared 2>/dev/null || true
        
        # 尝试使用官方卸载命令
        cloudflared service uninstall 2>/dev/null || true
        
        # 强制删除服务文件
        rm -f /etc/systemd/system/cloudflared.service
        rm -f /etc/systemd/system/cloudflared@.service
        systemctl daemon-reload
    else
        rc-service cloudflared stop 2>/dev/null || true
        rc-update del cloudflared default 2>/dev/null || true
        rm -f /etc/init.d/cloudflared
    fi
    
    # 2. 删除程序
    print_info "删除主程序..."
    if [ "$OS_TYPE" = "debian" ]; then
        dpkg -r cloudflared 2>/dev/null || true
    fi
    # 再次确保二进制文件被删除
    rm -f "$CLOUDFLARED_BIN"
    rm -f /usr/bin/cloudflared
    rm -f /usr/local/bin/cloudflared
    
    # 3. 删除所有相关文件
    print_info "清理配置文件和日志..."
    rm -rf "$CONFIG_DIR"
    rm -rf "$HOME/.cloudflared"
    rm -rf /root/.cloudflared
    rm -f /var/log/cloudflared.log
    rm -f /var/log/cloudflared.error.log
    
    # 4. 删除脚本自身
    print_info "正在删除脚本自身..."
    local script_path=$(readlink -f "$0")
    
    print_success "卸载和清理完成!"
    echo "再见。"
    
    # 删除脚本文件
    if [ -f "$script_path" ]; then
        rm -f "$script_path"
    fi
    
    # 退出脚本
    exit 0
}

# ============================================================================
# 查看日志
# ============================================================================

view_logs() {
    echo ""
    print_info "========== 查看日志 =========="
    
    if [ "$SERVICE_MANAGER" = "systemd" ]; then
        echo "按 q 退出日志查看"
        echo ""
        journalctl -u cloudflared -n 50 --no-pager
    else
        if [ -f /var/log/cloudflared.log ]; then
            tail -n 50 /var/log/cloudflared.log
        else
            print_warning "日志文件不存在"
        fi
    fi
    
    echo ""
    read -p "按回车键继续..."
}

# ============================================================================
# 主菜单
# ============================================================================

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║           Cloudflare Tunnel 部署管理脚本                      ║"
    echo "║                                                               ║"
    echo "║           支持: Debian/Ubuntu, Alpine Linux                   ║"
    echo "║           架构: amd64, arm64                                  ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main_menu() {
    while true; do
        show_banner
        
        # 显示快速状态
        echo -e "${PURPLE}系统: ${NC}$OS_NAME | ${PURPLE}架构: ${NC}$ARCH_TYPE"
        if check_cloudflared_installed; then
            echo -e "${PURPLE}cloudflared: ${NC}$(get_installed_version)"
        else
            echo -e "${PURPLE}cloudflared: ${NC}${RED}未安装${NC}"
        fi
        echo ""
        
        echo "════════════════════════════════════════"
        echo "  1. 安装 cloudflared"
        echo "  2. 配置隧道认证"
        echo "  3. 域名管理"
        echo "  4. 查看 Tunnel 列表"
        echo "  5. 服务管理"
        echo "  6. 查看状态"
        echo "  7. 更新 cloudflared"
        echo "  8. 查看日志"
        echo "  9. 卸载 cloudflared"
        echo "════════════════════════════════════════"
        echo "  0. 退出"
        echo ""
        read -p "请选择操作 [0-9]: " choice
        
        case $choice in
            1) install_cloudflared ;;
            2) auth_menu ;;
            3) hostname_menu ;;
            4) list_tunnels ;;
            5) service_menu ;;
            6) show_status ;;
            7) update_cloudflared ;;
            8) view_logs ;;
            9) uninstall_cloudflared ;;
            0) 
                echo ""
                print_info "感谢使用，再见!"
                exit 0
                ;;
            *) print_error "无效选项" ;;
        esac
        
        echo ""
        read -p "按回车键继续..."
    done
}

# ============================================================================
# 脚本入口
# ============================================================================

main() {
    check_root
    detect_os
    detect_arch
    main_menu
}

main "$@"
