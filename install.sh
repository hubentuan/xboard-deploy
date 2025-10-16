#!/bin/bash

# XBoard-Distro 持久化部署脚本 - 数据保护增强版
# 作者: oldfriendme (修复版)
# 修复: 彻底解决数据丢失问题，init 命令仅重置管理员

set -e

# 配置变量
CONTAINER_NAME="xboard-distro"
IMAGE_NAME="xboard-distro:v1"
DATA_ROOT="/opt/xboard-distro"
WEB_PORT="19999"        # XBoard 面板端口
REALITY_PORT="29443"    # REALITY 协议端口（避免冲突）
HY2_PORT="29444"        # Hysteria2 端口（避免冲突）

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否为 root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# 检查 Docker 是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi
    print_info "Docker 已安装: $(docker --version)"
}

# 检查端口占用
check_ports() {
    print_step "检查端口占用情况..."
    
    local ports=("${WEB_PORT}" "${REALITY_PORT}" "${HY2_PORT}")
    local occupied=false
    
    for port in "${ports[@]}"; do
        if netstat -tuln 2>/dev/null | grep -q ":${port} " || ss -tuln 2>/dev/null | grep -q ":${port} "; then
            print_warn "端口 ${port} 已被占用"
            netstat -tulpn 2>/dev/null | grep ":${port} " || ss -tulpn 2>/dev/null | grep ":${port} "
            occupied=true
        else
            print_info "端口 ${port} 可用"
        fi
    done
    
    if [ "$occupied" = true ]; then
        print_error "存在端口冲突，请修改脚本中的端口配置或停止占用端口的服务"
        exit 1
    fi
}

# 创建持久化目录
create_data_dirs() {
    print_step "创建持久化数据目录..."
    
    # 创建所有需要持久化的目录
    mkdir -p ${DATA_ROOT}/{mysql,xboard,xrayr,caddy,oauth2,certs,logs,config}
    
    # 设置权限
    chmod -R 755 ${DATA_ROOT}
    
    print_info "数据目录创建完成: ${DATA_ROOT}"
    ls -lh ${DATA_ROOT}
}

# 设置防火墙
setup_firewall() {
    print_step "配置防火墙端口..."
    
    # 检查防火墙
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        print_info "检测到 UFW 防火墙，开放端口..."
        ufw allow ${WEB_PORT}/tcp comment 'XBoard Panel'
        ufw allow ${REALITY_PORT}/tcp comment 'REALITY'
        ufw allow ${HY2_PORT}/udp comment 'Hysteria2'
        print_info "UFW 规则已添加"
    elif command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        print_info "检测到 Firewalld，开放端口..."
        firewall-cmd --permanent --add-port=${WEB_PORT}/tcp
        firewall-cmd --permanent --add-port=${REALITY_PORT}/tcp
        firewall-cmd --permanent --add-port=${HY2_PORT}/udp
        firewall-cmd --reload
        print_info "Firewalld 规则已添加"
    else
        print_warn "未检测到活动的防火墙，跳过防火墙配置"
        print_warn "如有防火墙，请手动开放端口: ${WEB_PORT}, ${REALITY_PORT}, ${HY2_PORT}/udp"
    fi
}

# 停止并删除旧容器
remove_old_container() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_step "发现旧容器，正在停止并删除..."
        docker stop ${CONTAINER_NAME} 2>/dev/null || true
        docker rm ${CONTAINER_NAME} 2>/dev/null || true
        print_info "旧容器已删除"
    else
        print_info "未发现旧容器"
    fi
}

# 启动容器（使用数据卷）
start_container() {
    print_step "启动 XBoard-Distro 容器..."
    
    docker run -d \
        --name ${CONTAINER_NAME} \
        --restart unless-stopped \
        -p ${WEB_PORT}:16443 \
        -p ${REALITY_PORT}:443 \
        -p ${HY2_PORT}:4443/udp \
        -v ${DATA_ROOT}/mysql:/var/lib/mysql \
        -v ${DATA_ROOT}/xboard:/www/xboard \
        -v ${DATA_ROOT}/xrayr:/etc/XrayR \
        -v ${DATA_ROOT}/caddy:/etc/caddy \
        -v ${DATA_ROOT}/oauth2:/home/oauth2 \
        -v ${DATA_ROOT}/certs:/root/.caddy \
        -v ${DATA_ROOT}/logs:/var/log \
        -v ${DATA_ROOT}/config:/opt/config \
        ${IMAGE_NAME} /sbin/init
    
    print_info "容器启动成功，等待系统服务初始化..."
    sleep 8
    
    # 检查容器状态
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "容器运行正常"
    else
        print_error "容器启动失败，查看日志:"
        docker logs ${CONTAINER_NAME}
        exit 1
    fi
}

# 检查数据库是否已初始化
check_database_initialized() {
    local db_init_marker="${DATA_ROOT}/mysql/xboard"
    
    if [ -d "${db_init_marker}" ] && [ "$(ls -A ${db_init_marker} 2>/dev/null)" ]; then
        print_info "检测到已存在的数据库数据"
        return 0  # 数据库已初始化
    else
        print_info "未检测到数据库数据，这是首次部署"
        return 1  # 数据库未初始化
    fi
}

# 等待 MySQL 启动
wait_for_mysql() {
    print_step "等待 MySQL 服务启动..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker exec ${CONTAINER_NAME} mysqladmin ping -h localhost --silent 2>/dev/null; then
            print_info "MySQL 服务已就绪"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done
    
    print_error "MySQL 启动超时"
    return 1
}

# 检查数据库表是否存在
check_database_tables() {
    # 检查关键表是否存在（users 表）
    local table_count=$(docker exec ${CONTAINER_NAME} mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='xboard' AND table_name='users';" 2>/dev/null || echo "0")
    
    if [ "$table_count" -gt 0 ]; then
        return 0  # 表存在
    else
        return 1  # 表不存在
    fi
}

# 初始化服务（仅首次）
init_service() {
    local init_flag="${DATA_ROOT}/.initialized"
    
    # 等待 MySQL 启动
    wait_for_mysql || exit 1
    
    # 检查数据库是否已初始化（检查数据库表，不仅仅是文件）
    if check_database_initialized && check_database_tables; then
        print_warn "=========================================="
        print_warn "检测到已存在的数据库和表结构"
        print_warn "=========================================="
        print_info "跳过 php service init，保护现有数据"
        print_info "直接启动服务，使用现有数据库"
        
        # 只启动服务，绝不执行 init
        print_step "启动 XBoard 服务（使用现有数据）..."
        docker exec ${CONTAINER_NAME} php service start
        
        if [ -f "${init_flag}" ]; then
            print_info "数据库初始化时间: $(grep '初始化时间' ${init_flag})"
        fi
        
        # 验证数据库中的用户数
        local user_count=$(docker exec ${CONTAINER_NAME} mysql -N -e "SELECT COUNT(*) FROM xboard.users;" 2>/dev/null || echo "0")
        print_info "数据库中现有用户数: ${user_count}"
        
        return 0
    fi
    
    # 首次部署 - 执行完整初始化
    print_step "首次部署，初始化 XBoard 服务..."
    echo ""
    echo "=========================================="
    echo "即将显示管理员账号信息，请务必保存！"
    echo "=========================================="
    sleep 2
    
    # 注意：php service init 会初始化数据库和创建管理员
    # 这个命令只在首次部署时执行
    docker exec -it ${CONTAINER_NAME} php service init
    
    # 创建初始化标记
    touch ${init_flag}
    echo "初始化时间: $(date)" > ${init_flag}
    echo "WEB_PORT=${WEB_PORT}" >> ${init_flag}
    echo "REALITY_PORT=${REALITY_PORT}" >> ${init_flag}
    echo "HY2_PORT=${HY2_PORT}" >> ${init_flag}
    echo "数据库已初始化" >> ${init_flag}
    
    echo ""
    print_info "初始化完成！重要信息已显示，请妥善保存！"
    echo ""
}

# 重置管理员密码（不影响用户数据）
reset_admin() {
    print_warn "=========================================="
    print_warn "重置管理员账号"
    print_warn "=========================================="
    print_warn "此操作将重置管理员密码和后台路径"
    print_warn "但不会影响用户数据、订阅、节点等信息"
    echo ""
    read -p "确认重置管理员? (输入 yes 继续): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "取消重置操作"
        return 0
    fi
    
    print_step "执行管理员重置..."
    
    # 使用专门的管理员重置命令（如果存在）
    # 如果没有专门的命令，需要手动操作数据库
    if docker exec ${CONTAINER_NAME} php service --help 2>/dev/null | grep -q "reset-admin"; then
        docker exec -it ${CONTAINER_NAME} php service reset-admin
    else
        print_warn "未找到 reset-admin 命令"
        print_info "请使用以下方法手动重置："
        echo ""
        echo "方法1: 进入容器手动重置"
        echo "  docker exec -it ${CONTAINER_NAME} /bin/ash"
        echo "  cd /www/xboard"
        echo "  php artisan admin:reset"
        echo ""
        echo "方法2: 直接操作数据库"
        echo "  docker exec -it ${CONTAINER_NAME} mysql xboard"
        echo "  UPDATE users SET password=MD5('新密码') WHERE id=1;"
        echo ""
    fi
}

# 配置 OAuth2
configure_oauth2() {
    local oauth_config="${DATA_ROOT}/oauth2/func.php"
    
    print_step "配置 OAuth2 参数..."
    
    # 等待文件生成
    sleep 2
    
    if [ ! -f "${oauth_config}" ]; then
        print_warn "OAuth2 配置文件不存在，稍后可手动配置"
        print_info "配置文件路径: ${oauth_config}"
        return 0
    fi
    
    # 检查是否已配置
    if grep -q "CLIENT_ID = '[^']'" ${oauth_config} 2>/dev/null; then
        print_info "OAuth2 已配置，跳过"
        return 0
    fi
    
    echo ""
    echo "请输入 OAuth2 配置信息（直接回车跳过）："
    read -p "Client ID: " client_id
    read -p "Client Secret: " client_secret
    
    if [ -n "$client_id" ] && [ -n "$client_secret" ]; then
        docker exec ${CONTAINER_NAME} sed -i \
            "s/\$CLIENT_ID = '.*'/\$CLIENT_ID = '${client_id}'/" \
            /home/oauth2/func.php
        
        docker exec ${CONTAINER_NAME} sed -i \
            "s/\$CLIENT_SECRET = '.*'/\$CLIENT_SECRET = '${client_secret}'/" \
            /home/oauth2/func.php
        
        print_info "OAuth2 配置更新成功"
    else
        print_warn "跳过 OAuth2 配置，稍后可手动配置"
        print_info "配置方法: docker exec -it ${CONTAINER_NAME} vi /home/oauth2/func.php"
    fi
}

# 启动服务（非首次部署时使用）
start_services() {
    print_step "检查数据库状态并启动服务..."
    
    # 等待 MySQL 启动
    wait_for_mysql || exit 1
    
    # 检查是否有现有数据
    if check_database_tables; then
        local user_count=$(docker exec ${CONTAINER_NAME} mysql -N -e "SELECT COUNT(*) FROM xboard.users;" 2>/dev/null || echo "0")
        print_info "检测到现有数据库，用户数: ${user_count}"
        print_info "直接启动服务，不执行初始化"
    else
        print_warn "警告: 数据库表不存在！"
        print_warn "如果这不是首次部署，数据可能已损坏"
        print_warn "建议使用备份恢复: $0 restore <备份文件>"
    fi
    
    docker exec ${CONTAINER_NAME} php service start
    
    print_info "等待服务完全启动..."
    sleep 5
    
    # 验证服务状态
    if docker exec ${CONTAINER_NAME} ps aux | grep -v grep | grep -q caddy; then
        print_info "✓ Caddy 服务运行正常"
    else
        print_warn "✗ Caddy 服务可能未启动"
    fi
    
    if docker exec ${CONTAINER_NAME} ps aux | grep -v grep | grep -q mysqld; then
        print_info "✓ MySQL 服务运行正常"
    else
        print_warn "✗ MySQL 服务可能未启动"
    fi
    
    print_info "服务启动完成！"
}

# 显示访问信息
show_access_info() {
    local ip=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "YOUR_SERVER_IP")
    
    echo ""
    echo "=========================================="
    echo -e "${GREEN}✓ XBoard-Distro 部署完成！${NC}"
    echo "=========================================="
    echo ""
    echo -e "${BLUE}访问地址:${NC}"
    echo "  面板地址:  https://${ip}:${WEB_PORT}"
    echo "  OAuth登录: https://${ip}:${WEB_PORT}/oauth_auto_login"
    echo "  后台管理:  https://${ip}:${WEB_PORT}/{admin_path}"
    echo ""
    echo -e "${BLUE}端口映射:${NC}"
    echo "  ${WEB_PORT} -> 16443    (XBoard 面板)"
    echo "  ${REALITY_PORT} -> 443  (REALITY 协议)"
    echo "  ${HY2_PORT} -> 4443/udp (Hysteria2 协议)"
    echo ""
    echo -e "${BLUE}数据持久化:${NC}"
    echo "  根目录: ${DATA_ROOT}"
    echo "  MySQL:  ${DATA_ROOT}/mysql     (数据库文件)"
    echo "  XBoard: ${DATA_ROOT}/xboard    (网站文件)"
    echo "  XrayR:  ${DATA_ROOT}/xrayr     (节点配置)"
    echo "  OAuth2: ${DATA_ROOT}/oauth2    (OAuth配置)"
    echo "  Caddy:  ${DATA_ROOT}/caddy     (Web服务器配置)"
    echo "  Certs:  ${DATA_ROOT}/certs     (SSL证书)"
    echo "  Logs:   ${DATA_ROOT}/logs      (日志文件)"
    echo ""
    echo -e "${BLUE}管理命令:${NC}"
    echo "  查看状态: $0 status"
    echo "  进入容器: docker exec -it ${CONTAINER_NAME} /bin/ash"
    echo "  查看日志: docker logs -f ${CONTAINER_NAME}"
    echo "  重启容器: docker restart ${CONTAINER_NAME}"
    echo "  停止容器: docker stop ${CONTAINER_NAME}"
    echo "  启动服务: docker exec ${CONTAINER_NAME} php service start"
    echo "  停止服务: docker exec ${CONTAINER_NAME} php service stop"
    echo "  重置管理员: $0 reset-admin"
    echo ""
    echo -e "${BLUE}备份与恢复:${NC}"
    echo "  备份数据: $0 backup"
    echo "  恢复数据: $0 restore <备份文件>"
    echo ""
    echo -e "${YELLOW}重要提示:${NC}"
    echo "  1. 所有数据已持久化到 ${DATA_ROOT}"
    echo "  2. 删除容器不会丢失任何用户数据"
    echo "  3. 重新部署使用: $0 redeploy (保留所有数据)"
    echo "  4. 仅重置管理员: $0 reset-admin (不影响用户)"
    echo "  5. 定期备份数据: $0 backup"
    echo "  6. 后台路径请查看首次初始化时的输出"
    echo "=========================================="
    echo ""
}

# 备份数据
backup_data() {
    local backup_dir="/opt/xboard-backups"
    local backup_file="${backup_dir}/xboard-$(date +%Y%m%d-%H%M%S).tar.gz"
    
    print_step "备份数据到 ${backup_file}..."
    
    mkdir -p ${backup_dir}
    
    # 如果容器在运行，先停止服务
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "停止服务以确保数据一致性..."
        docker exec ${CONTAINER_NAME} php service stop 2>/dev/null || true
        sleep 3
    fi
    
    print_info "打包数据中..."
    tar -czf ${backup_file} -C ${DATA_ROOT} . 2>/dev/null
    
    # 重启服务
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "重新启动服务..."
        docker exec ${CONTAINER_NAME} php service start
    fi
    
    print_info "备份完成: ${backup_file}"
    print_info "备份大小: $(du -h ${backup_file} | cut -f1)"
    
    # 列出所有备份
    echo ""
    echo "现有备份文件:"
    ls -lh ${backup_dir}/*.tar.gz 2>/dev/null || echo "  无"
    
    # 清理超过7天的旧备份
    find ${backup_dir} -name "xboard-*.tar.gz" -mtime +7 -delete 2>/dev/null || true
}

# 恢复数据
restore_data() {
    if [ -z "$1" ]; then
        print_error "请指定备份文件路径"
        echo ""
        echo "用法: $0 restore /path/to/backup.tar.gz"
        echo ""
        echo "可用的备份文件:"
        ls -lh /opt/xboard-backups/*.tar.gz 2>/dev/null || echo "  无"
        exit 1
    fi
    
    local backup_file="$1"
    
    if [ ! -f "${backup_file}" ]; then
        print_error "备份文件不存在: ${backup_file}"
        exit 1
    fi
    
    print_warn "=========================================="
    print_warn "数据恢复操作"
    print_warn "=========================================="
    print_warn "即将恢复数据，这将覆盖现有所有数据！"
    print_warn "包括：用户数据、订阅、节点配置等"
    echo ""
    read -p "确认继续? (输入 YES 继续): " confirm
    
    if [ "$confirm" != "YES" ]; then
        print_info "取消恢复操作"
        exit 0
    fi
    
    remove_old_container
    
    print_step "恢复数据中..."
    rm -rf ${DATA_ROOT}/*
    tar -xzf ${backup_file} -C ${DATA_ROOT}
    
    print_info "数据恢复完成，正在启动容器..."
}

# 显示状态
show_status() {
    echo "=========================================="
    echo "XBoard-Distro 运行状态"
    echo "=========================================="
    echo ""
    
    # 容器状态
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${GREEN}✓ 容器状态: 运行中${NC}"
        docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        
        echo ""
        echo "服务状态:"
        docker exec ${CONTAINER_NAME} ps aux | grep -E "caddy|mysqld|XrayR" | grep -v grep || echo "  无法获取服务状态"
        
        # 数据库连接测试
        echo ""
        if docker exec ${CONTAINER_NAME} mysqladmin ping -h localhost --silent 2>/dev/null; then
            echo -e "${GREEN}✓ MySQL 连接: 正常${NC}"
            
            # 显示数据库信息
            local user_count=$(docker exec ${CONTAINER_NAME} mysql -N -e "SELECT COUNT(*) FROM xboard.users WHERE id > 0;" 2>/dev/null || echo "0")
            local admin_count=$(docker exec ${CONTAINER_NAME} mysql -N -e "SELECT COUNT(*) FROM xboard.users WHERE is_admin = 1;" 2>/dev/null || echo "0")
            local order_count=$(docker exec ${CONTAINER_NAME} mysql -N -e "SELECT COUNT(*) FROM xboard.orders;" 2>/dev/null || echo "0")
            
            echo "  总用户数: ${user_count}"
            echo "  管理员数: ${admin_count}"
            echo "  订单数: ${order_count}"
        else
            echo -e "${RED}✗ MySQL 连接: 失败${NC}"
        fi
    else
        echo -e "${RED}✗ 容器状态: 未运行${NC}"
        if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            echo "  容器已停止，使用 '$0 start' 启动"
        else
            echo "  容器不存在，使用 '$0 deploy' 部署"
        fi
    fi
    
    echo ""
    echo "=========================================="
    echo "数据持久化状态"
    echo "=========================================="
    
    if [ -d "${DATA_ROOT}" ]; then
        echo "数据根目录: ${DATA_ROOT}"
        echo ""
        du -sh ${DATA_ROOT}/* 2>/dev/null | while read size path; do
            local name=$(basename $path)
            printf "  %-10s %s\n" "$name:" "$size"
        done
        
        # 检查数据库文件
        echo ""
        if [ -d "${DATA_ROOT}/mysql/xboard" ]; then
            echo -e "${GREEN}✓ 数据库文件: 存在${NC}"
            local db_size=$(du -sh ${DATA_ROOT}/mysql 2>/dev/null | cut -f1)
            echo "  数据库大小: ${db_size}"
            
            # 列出数据库文件
            local table_count=$(find ${DATA_ROOT}/mysql/xboard -name "*.ibd" 2>/dev/null | wc -l)
            echo "  表文件数: ${table_count}"
        else
            echo -e "${YELLOW}✗ 数据库文件: 不存在${NC}"
        fi
        
        # 检查初始化标记
        echo ""
        if [ -f "${DATA_ROOT}/.initialized" ]; then
            echo "初始化信息:"
            cat ${DATA_ROOT}/.initialized | sed 's/^/  /'
        fi
    else
        echo -e "${RED}✗ 数据目录不存在${NC}"
    fi
    
    echo ""
    echo "=========================================="
}

# 验证数据完整性
verify_data() {
    print_step "验证数据完整性..."
    echo ""
    
    # 检查容器
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_error "容器未运行，无法验证数据"
        exit 1
    fi
    
    # 检查数据库连接
    if ! docker exec ${CONTAINER_NAME} mysqladmin ping -h localhost --silent 2>/dev/null; then
        print_error "MySQL 未运行或无法连接"
        exit 1
    fi
    
    print_info "数据库连接正常"
    
    # 检查关键表
    local tables=("users" "orders" "plans" "servers" "nodes")
    echo ""
    echo "检查数据库表:"
    
    for table in "${tables[@]}"; do
        local exists=$(docker exec ${CONTAINER_NAME} mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='xboard' AND table_name='${table}';" 2>/dev/null || echo "0")
        
        if [ "$exists" = "1" ]; then
            local count=$(docker exec ${CONTAINER_NAME} mysql -N -e "SELECT COUNT(*) FROM xboard.${table};" 2>/dev/null || echo "0")
            echo -e "  ${GREEN}✓${NC} ${table}: ${count} 条记录"
        else
            echo -e "  ${RED}✗${NC} ${table}: 表不存在"
        fi
    done
    
    # 检查管理员
    echo ""
    echo "管理员账号:"
    docker exec ${CONTAINER_NAME} mysql -N -e "SELECT id, email, is_admin FROM xboard.users WHERE is_admin = 1 LIMIT 5;" 2>/dev/null | while read id email is_admin; do
        echo "  ID: ${id}, Email: ${email}"
    done
    
    echo ""
    print_info "数据验证完成"
}

# 主函数
main() {
    case "${1:-deploy}" in
        deploy)
            echo "=========================================="
            echo "XBoard-Distro 完整部署"
            echo "=========================================="
            check_root
            check_docker
            check_ports
            create_data_dirs
            setup_firewall
            remove_old_container
            start_container
            init_service  # 会自动判断是否首次部署
            configure_oauth2
            show_access_info
            ;;
        redeploy)
            echo "=========================================="
            echo "XBoard-Distro 重新部署"
            echo "=========================================="
            print_warn "注意: 此操作会删除容器但保留所有数据"
            print_info "如果数据库已存在，将跳过初始化"
            echo ""
            read -p "确认继续? (回车继续，Ctrl+C 取消): " confirm
            check_root
            check_docker
            check_ports
            remove_old_container
            start_container
            # 智能判断是否需要初始化
            init_service
            show_access_info
            ;;
        reset-admin)
            check_root
            if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
                print_error "容器未运行，请先启动容器"
                exit 1
            fi
            reset_admin
            ;;
        backup)
            backup_data
            ;;
        restore)
            restore_data "$2"
            start_container
            start_services
            show_access_info
            ;;
        status)
            show_status
            ;;
        stop)
            print_info "停止容器..."
            docker exec ${CONTAINER_NAME} php service stop 2>/dev/null || true
            sleep 2
            docker stop ${CONTAINER_NAME}
            print_info "容器已停止"
            ;;
        start)
            print_info "启动容器..."
            docker start ${CONTAINER_NAME}
            sleep 5
            docker exec ${CONTAINER_NAME} php service start
            print_info "容器已启动"
            show_access_info
            ;;
        restart)
            print_info "重启容器..."
            docker exec ${CONTAINER_NAME} php service stop 2>/dev/null || true
            sleep 2
            docker restart ${CONTAINER_NAME}
            sleep 5
            docker exec ${CONTAINER_NAME} php service start
            print_info "容器已重启"
            ;;
        logs)
            docker logs -f ${CONTAINER_NAME}
            ;;
        shell)
            print_info "进入容器 shell..."
            docker exec -it ${CONTAINER_NAME} /bin/ash
            ;;
        *)
            echo "XBoard-Distro 部署脚本 - 数据保护增强版"
            echo ""
            echo "用法: $0 {命令}"
            echo ""
            echo "部署命令:"
            echo "  deploy       - 首次完整部署（自动检测是否需要初始化）"
            echo "  redeploy     - 重新部署（保留所有现有数据）"
            echo ""
            echo "管理命令:"
            echo "  status       - 查看运行状态和数据情况"
            echo "  start        - 启动容器和服务"
            echo "  stop         - 停止容器和服务"
            echo "  restart      - 重启容器和服务"
            echo "  reset-admin  - 仅重置管理员（不影响用户数据）"
            echo ""
            echo "数据命令:"
            echo "  backup       - 备份所有数据"
            echo "  restore      - 恢复数据（需指定备份文件）"
            echo ""
            echo "调试命令:"
            echo "  logs         - 查看实时日志"
            echo "  shell        - 进入容器 shell"
            echo ""
            echo "重要说明:"
            echo "  • 所有用户数据、订阅、节点配置均持久化"
            echo "  • 删除容器不会丢失任何数据"
            echo "  • redeploy 会保留所有现有数据"
            echo "  • reset-admin 仅重置管理员，不影响用户"
            echo "  • 定期使用 backup 命令备份数据"
            echo ""
            echo "示例:"
            echo "  $0 deploy                           # 首次部署"
            echo "  $0 redeploy                         # 重新部署（保留数据）"
            echo "  $0 reset-admin                      # 重置管理员密码"
            echo "  $0 backup                           # 备份数据"
            echo "  $0 restore /path/to/backup.tar.gz   # 恢复数据"
            echo "  $0 status                           # 查看状态"
            exit 1
            ;;
    esac
}

main "$@"
