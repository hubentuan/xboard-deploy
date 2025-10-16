#!/bin/bash

# XBoard-Distro 持久化部署脚本 - 完全修复版
# 作者: 风萧萧兮 (终极修复版)
# 修复: 解决 MySQL 启动和命令路径问题

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
        --privileged \
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
    
    print_info "容器启动成功，等待系统服务完全初始化..."
    
    # 等待容器内的 init 系统完全启动
    local wait_time=0
    local max_wait=30
    echo -n "等待系统初始化"
    while [ $wait_time -lt $max_wait ]; do
        if docker exec ${CONTAINER_NAME} test -f /sbin/init 2>/dev/null; then
            # 检查 init 系统是否准备就绪
            if docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -v grep | grep -E 'init|systemd|openrc'" 2>/dev/null; then
                echo ""
                print_info "系统初始化完成 (${wait_time}秒)"
                break
            fi
        fi
        echo -n "."
        sleep 1
        wait_time=$((wait_time + 1))
    done
    
    # 额外等待服务启动
    print_info "等待系统服务启动..."
    sleep 10
    
    # 检查容器状态
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "容器运行正常"
    else
        print_error "容器启动失败，查看日志:"
        docker logs ${CONTAINER_NAME}
        exit 1
    fi
}

# 获取 MySQL 可执行文件路径
get_mysql_paths() {
    # 查找 MySQL 相关命令的实际路径
    local mysqld_path=$(docker exec ${CONTAINER_NAME} sh -c "find /usr -name mysqld 2>/dev/null | head -1" 2>/dev/null || echo "")
    local mysql_path=$(docker exec ${CONTAINER_NAME} sh -c "find /usr -name mysql 2>/dev/null | head -1" 2>/dev/null || echo "")
    local mysqladmin_path=$(docker exec ${CONTAINER_NAME} sh -c "find /usr -name mysqladmin 2>/dev/null | head -1" 2>/dev/null || echo "")
    
    if [ -z "$mysqld_path" ]; then
        mysqld_path=$(docker exec ${CONTAINER_NAME} sh -c "which mysqld 2>/dev/null || which mariadbd 2>/dev/null" || echo "")
    fi
    
    echo "MYSQLD_PATH=${mysqld_path}"
    echo "MYSQL_PATH=${mysql_path}"
    echo "MYSQLADMIN_PATH=${mysqladmin_path}"
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
    local max_attempts=90  # 增加到 90 次 (180秒)
    local attempt=0
    
    # 先获取 MySQL 路径
    print_info "查找 MySQL 可执行文件..."
    local paths=$(get_mysql_paths)
    eval "$paths"
    
    if [ -z "$MYSQLD_PATH" ]; then
        print_warn "未找到 mysqld，尝试其他方法..."
    else
        print_info "找到 mysqld: $MYSQLD_PATH"
    fi
    
    echo -n "正在等待 MySQL 启动"
    while [ $attempt -lt $max_attempts ]; do
        # 多种方式检查 MySQL 是否运行
        local mysql_running=false
        
        # 方法1: 检查进程
        if docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -v grep | grep -E 'mysqld|mariadbd'" 2>/dev/null; then
            mysql_running=true
        fi
        
        # 方法2: 尝试连接
        if [ -n "$MYSQLADMIN_PATH" ]; then
            if docker exec ${CONTAINER_NAME} sh -c "${MYSQLADMIN_PATH} ping -h localhost --silent" 2>/dev/null; then
                echo ""
                print_info "MySQL 服务已就绪 (耗时: $((attempt * 2)) 秒)"
                return 0
            fi
        else
            # 尝试使用默认路径
            if docker exec ${CONTAINER_NAME} sh -c "mysqladmin ping -h localhost --silent" 2>/dev/null || \
               docker exec ${CONTAINER_NAME} sh -c "/usr/bin/mysqladmin ping -h localhost --silent" 2>/dev/null; then
                echo ""
                print_info "MySQL 服务已就绪 (耗时: $((attempt * 2)) 秒)"
                return 0
            fi
        fi
        
        # 方法3: 检查端口
        if docker exec ${CONTAINER_NAME} sh -c "netstat -tuln 2>/dev/null | grep ':3306' || ss -tuln 2>/dev/null | grep ':3306'" 2>/dev/null; then
            mysql_running=true
        fi
        
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
        
        # 每 15 次显示提示
        if [ $((attempt % 15)) -eq 0 ]; then
            echo ""
            print_info "仍在等待 MySQL 启动... ($((attempt * 2))/$((max_attempts * 2)) 秒)"
            
            # 30秒后尝试手动启动
            if [ $attempt -eq 15 ]; then
                echo ""
                print_warn "MySQL 未自动启动，尝试手动启动..."
                manual_start_mysql
                echo -n "继续等待"
            fi
            
            # 60秒后显示诊断信息
            if [ $attempt -eq 30 ]; then
                echo ""
                print_warn "MySQL 启动时间较长，显示诊断信息:"
                echo "进程列表:"
                docker exec ${CONTAINER_NAME} ps aux | head -20
                echo ""
                echo "端口监听:"
                docker exec ${CONTAINER_NAME} sh -c "netstat -tuln 2>/dev/null || ss -tuln 2>/dev/null" | grep -E "3306|mysql"
                echo ""
                echo -n "继续等待"
            fi
        fi
    done
    
    echo ""
    print_error "MySQL 启动超时 (已等待 $((max_attempts * 2)) 秒)"
    
    # 显示详细错误信息
    echo ""
    print_warn "故障排除信息:"
    echo "1. 容器内进程:"
    docker exec ${CONTAINER_NAME} ps aux | grep -E "mysql|maria" | grep -v grep
    echo ""
    echo "2. 查找 MySQL 相关文件:"
    docker exec ${CONTAINER_NAME} sh -c "find /usr -name 'mysql*' -type f 2>/dev/null | head -10"
    echo ""
    echo "3. 系统服务状态:"
    docker exec ${CONTAINER_NAME} sh -c "rc-status 2>/dev/null || service --status-all 2>/dev/null || systemctl status 2>/dev/null | head -20"
    echo ""
    
    return 1
}

# 手动启动 MySQL
manual_start_mysql() {
    print_step "尝试手动启动 MySQL 服务..."
    
    # 检查容器是否运行
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_error "容器未运行"
        return 1
    fi
    
    # 获取 MySQL 路径
    local paths=$(get_mysql_paths)
    eval "$paths"
    
    # 检查 MySQL 是否已在运行
    if docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -v grep | grep -E 'mysqld|mariadbd'" 2>/dev/null; then
        print_info "MySQL 进程已存在"
        # 尝试连接测试
        if [ -n "$MYSQLADMIN_PATH" ]; then
            if docker exec ${CONTAINER_NAME} sh -c "${MYSQLADMIN_PATH} ping -h localhost --silent" 2>/dev/null; then
                print_info "MySQL 已在运行且可连接"
                return 0
            fi
        fi
    fi
    
    # 确保数据目录权限正确
    print_info "设置数据目录权限..."
    docker exec ${CONTAINER_NAME} sh -c "
        mkdir -p /var/lib/mysql /var/run/mysqld /var/log/mysql
        chown -R mysql:mysql /var/lib/mysql /var/run/mysqld /var/log/mysql 2>/dev/null || \
        chown -R mysql:mysql /var/lib/mysql /run/mysqld /var/log/mysql 2>/dev/null
        chmod 755 /var/run/mysqld 2>/dev/null || chmod 755 /run/mysqld 2>/dev/null
    " 2>/dev/null
    
    # 尝试不同的启动方法
    print_info "方法1: 使用系统服务管理器..."
    
    # OpenRC (Alpine)
    if docker exec ${CONTAINER_NAME} sh -c "which rc-service" 2>/dev/null; then
        docker exec ${CONTAINER_NAME} sh -c "rc-service mysql start || rc-service mysqld start || rc-service mariadb start" 2>/dev/null
        sleep 5
        if docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -v grep | grep -E 'mysqld|mariadbd'" 2>/dev/null; then
            print_info "MySQL 通过 OpenRC 启动成功"
            return 0
        fi
    fi
    
    # service 命令
    if docker exec ${CONTAINER_NAME} sh -c "which service" 2>/dev/null; then
        docker exec ${CONTAINER_NAME} sh -c "service mysql start || service mysqld start || service mariadb start" 2>/dev/null
        sleep 5
        if docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -v grep | grep -E 'mysqld|mariadbd'" 2>/dev/null; then
            print_info "MySQL 通过 service 启动成功"
            return 0
        fi
    fi
    
    # systemctl
    if docker exec ${CONTAINER_NAME} sh -c "which systemctl" 2>/dev/null; then
        docker exec ${CONTAINER_NAME} sh -c "systemctl start mysql || systemctl start mysqld || systemctl start mariadb" 2>/dev/null
        sleep 5
        if docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -v grep | grep -E 'mysqld|mariadbd'" 2>/dev/null; then
            print_info "MySQL 通过 systemctl 启动成功"
            return 0
        fi
    fi
    
    print_info "方法2: 直接启动 mysqld 进程..."
    
    if [ -n "$MYSQLD_PATH" ]; then
        # 检查是否需要初始化
        if [ ! -d "${DATA_ROOT}/mysql/mysql" ]; then
            print_warn "数据库未初始化，执行初始化..."
            # 尝试初始化
            docker exec ${CONTAINER_NAME} sh -c "
                if [ -x /usr/bin/mysql_install_db ]; then
                    /usr/bin/mysql_install_db --user=mysql --datadir=/var/lib/mysql
                elif [ -x ${MYSQLD_PATH} ]; then
                    ${MYSQLD_PATH} --initialize-insecure --user=mysql --datadir=/var/lib/mysql
                fi
            " 2>/dev/null
            sleep 3
        fi
        
        # 启动 mysqld
        docker exec -d ${CONTAINER_NAME} sh -c "${MYSQLD_PATH} --user=mysql --datadir=/var/lib/mysql --skip-networking=0" 2>/dev/null
        sleep 8
        
        if docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -v grep | grep -E 'mysqld|mariadbd'" 2>/dev/null; then
            print_info "MySQL 直接启动成功"
            return 0
        fi
    fi
    
    # 尝试使用 mysqld_safe
    if docker exec ${CONTAINER_NAME} sh -c "which mysqld_safe" 2>/dev/null; then
        print_info "方法3: 使用 mysqld_safe..."
        docker exec -d ${CONTAINER_NAME} sh -c "mysqld_safe --user=mysql --datadir=/var/lib/mysql" 2>/dev/null
        sleep 8
        
        if docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -v grep | grep -E 'mysqld|mariadbd'" 2>/dev/null; then
            print_info "MySQL 通过 mysqld_safe 启动成功"
            return 0
        fi
    fi
    
    print_error "MySQL 手动启动失败"
    return 1
}

# 检查数据库表是否存在
check_database_tables() {
    # 获取 MySQL 路径
    local paths=$(get_mysql_paths)
    eval "$paths"
    
    local mysql_cmd="${MYSQL_PATH:-mysql}"
    
    # 检查关键表是否存在（users 表）
    local table_count=$(docker exec ${CONTAINER_NAME} sh -c "${mysql_cmd} -N -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='xboard' AND table_name='users';\"" 2>/dev/null || echo "0")
    
    if [ "$table_count" = "1" ] || [ "$table_count" -gt 0 ]; then
        return 0  # 表存在
    else
        return 1  # 表不存在
    fi
}

# 初始化服务（仅首次）
init_service() {
    local init_flag="${DATA_ROOT}/.initialized"
    
    # 等待 MySQL 启动
    if ! wait_for_mysql; then
        print_error "MySQL 启动失败，无法继续初始化"
        print_warn "请尝试以下操作："
        echo "1. 检查镜像是否正确: docker images | grep xboard"
        echo "2. 重新拉取或构建镜像"
        echo "3. 检查容器日志: docker logs ${CONTAINER_NAME}"
        echo "4. 手动进入容器排查: docker exec -it ${CONTAINER_NAME} /bin/sh"
        exit 1
    fi
    
    # 检查数据库是否已初始化
    if check_database_initialized && check_database_tables; then
        print_warn "=========================================="
        print_warn "检测到已存在的数据库和表结构"
        print_warn "=========================================="
        print_info "跳过 php service init，保护现有数据"
        print_info "直接启动服务，使用现有数据库"
        
        # 只启动服务，绝不执行 init
        print_step "启动 XBoard 服务（使用现有数据）..."
        docker exec ${CONTAINER_NAME} sh -c "cd /www/xboard && php service start" 2>/dev/null || \
        docker exec ${CONTAINER_NAME} sh -c "php /www/xboard/service start" 2>/dev/null || \
        docker exec ${CONTAINER_NAME} php service start 2>/dev/null
        
        if [ -f "${init_flag}" ]; then
            print_info "数据库初始化信息:"
            cat ${init_flag}
        fi
        
        # 验证数据库中的用户数
        local paths=$(get_mysql_paths)
        eval "$paths"
        local mysql_cmd="${MYSQL_PATH:-mysql}"
        local user_count=$(docker exec ${CONTAINER_NAME} sh -c "${mysql_cmd} -N -e \"SELECT COUNT(*) FROM xboard.users;\"" 2>/dev/null || echo "0")
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
    
    # 尝试不同的初始化命令
    if docker exec ${CONTAINER_NAME} sh -c "test -f /www/xboard/service" 2>/dev/null; then
        docker exec -it ${CONTAINER_NAME} sh -c "cd /www/xboard && php service init"
    elif docker exec ${CONTAINER_NAME} sh -c "test -f /www/xboard/artisan" 2>/dev/null; then
        docker exec -it ${CONTAINER_NAME} sh -c "cd /www/xboard && php artisan xboard:install"
    else
        docker exec -it ${CONTAINER_NAME} php service init
    fi
    
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
    echo "  MySQL:  ${DATA_ROOT}/mysql"
    echo "  XBoard: ${DATA_ROOT}/xboard"
    echo ""
    echo -e "${BLUE}管理命令:${NC}"
    echo "  查看状态: $0 status"
    echo "  诊断问题: $0 diagnose"
    echo "  进入容器: docker exec -it ${CONTAINER_NAME} /bin/sh"
    echo "  查看日志: docker logs -f ${CONTAINER_NAME}"
    echo "  重启容器: docker restart ${CONTAINER_NAME}"
    echo ""
    echo -e "${YELLOW}重要提示:${NC}"
    echo "  1. 所有数据已持久化到 ${DATA_ROOT}"
    echo "  2. 首次访问可能需要等待服务完全启动"
    echo "  3. 如遇到问题，使用 $0 diagnose 诊断"
    echo "=========================================="
    echo ""
}

# 诊断功能
diagnose() {
    print_step "诊断 XBoard-Distro 系统..."
    echo ""
    
    # 检查容器
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "✓ 容器运行中"
    else
        print_error "✗ 容器未运行"
        exit 1
    fi
    
    # 获取 MySQL 路径
    print_step "查找系统组件..."
    local paths=$(get_mysql_paths)
    eval "$paths"
    echo "  mysqld: ${MYSQLD_PATH:-未找到}"
    echo "  mysql: ${MYSQL_PATH:-未找到}"
    echo "  mysqladmin: ${MYSQLADMIN_PATH:-未找到}"
    
    # 检查进程
    echo ""
    print_step "检查关键进程..."
    echo "MySQL 进程:"
    docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -E 'mysql|maria' | grep -v grep" || echo "  未找到 MySQL 进程"
    
    echo ""
    echo "其他服务进程:"
    docker exec ${CONTAINER_NAME} sh -c "ps aux | grep -E 'caddy|php|xray' | grep -v grep" || echo "  未找到其他服务"
    
    # 检查端口
    echo ""
    print_step "检查端口监听..."
    docker exec ${CONTAINER_NAME} sh -c "netstat -tuln 2>/dev/null || ss -tuln 2>/dev/null" | grep -E "3306|16443|443|4443" || echo "  无端口监听"
    
    # 检查文件系统
    echo ""
    print_step "检查文件系统..."
    echo "XBoard 目录:"
    docker exec ${CONTAINER_NAME} sh -c "ls -la /www/xboard 2>/dev/null | head -5" || echo "  目录不存在"
    
    echo ""
    echo "MySQL 数据目录:"
    docker exec ${CONTAINER_NAME} sh -c "ls -la /var/lib/mysql 2>/dev/null | head -5" || echo "  目录不存在"
    
    # 检查系统服务
    echo ""
    print_step "检查系统服务管理器..."
    if docker exec ${CONTAINER_NAME} sh -c "which rc-service" 2>/dev/null; then
        echo "OpenRC 已安装"
        docker exec ${CONTAINER_NAME} sh -c "rc-status" 2>/dev/null || echo "  rc-status 不可用"
    elif docker exec ${CONTAINER_NAME} sh -c "which systemctl" 2>/dev/null; then
        echo "Systemd 已安装"
        docker exec ${CONTAINER_NAME} sh -c "systemctl status mysql 2>/dev/null | head -10" || echo "  systemctl 不可用"
    elif docker exec ${CONTAINER_NAME} sh -c "which service" 2>/dev/null; then
        echo "SysV init 已安装"
        docker exec ${CONTAINER_NAME} sh -c "service --status-all 2>/dev/null" || echo "  service 不可用"
    else
        echo "未检测到服务管理器"
    fi
    
    # 检查 PHP
    echo ""
    print_step "检查 PHP 环境..."
    docker exec ${CONTAINER_NAME} sh -c "php -v 2>/dev/null | head -1" || echo "  PHP 未安装或不可用"
    docker exec ${CONTAINER_NAME} sh -c "which php" 2>/dev/null || echo "  找不到 php 命令"
    
    echo ""
    print_info "诊断完成"
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
        docker exec ${CONTAINER_NAME} ps aux | grep -E "caddy|mysqld|mariadbd|XrayR|php" | grep -v grep || echo "  无法获取服务状态"
        
        # 数据库连接测试
        echo ""
        local paths=$(get_mysql_paths)
        eval "$paths"
        local mysqladmin_cmd="${MYSQLADMIN_PATH:-mysqladmin}"
        
        if docker exec ${CONTAINER_NAME} sh -c "${mysqladmin_cmd} ping -h localhost --silent" 2>/dev/null; then
            echo -e "${GREEN}✓ MySQL 连接: 正常${NC}"
            
            # 显示数据库信息
            local mysql_cmd="${MYSQL_PATH:-mysql}"
            local user_count=$(docker exec ${CONTAINER_NAME} sh -c "${mysql_cmd} -N -e \"SELECT COUNT(*) FROM xboard.users WHERE id > 0;\"" 2>/dev/null || echo "0")
            local admin_count=$(docker exec ${CONTAINER_NAME} sh -c "${mysql_cmd} -N -e \"SELECT COUNT(*) FROM xboard.users WHERE is_admin = 1;\"" 2>/dev/null || echo "0")
            local order_count=$(docker exec ${CONTAINER_NAME} sh -c "${mysql_cmd} -N -e \"SELECT COUNT(*) FROM xboard.orders;\"" 2>/dev/null || echo "0")
            
            echo "  总用户数: ${user_count}"
            echo "  管理员数: ${admin_count}"
            echo "  订单数: ${order_count}"
        else
            echo -e "${RED}✗ MySQL 连接: 失败${NC}"
            echo "  尝试手动启动: $0 fix-mysql"
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

# 修复 MySQL
fix_mysql() {
    print_step "修复 MySQL 启动问题..."
    echo ""
    
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_error "容器未运行，请先启动容器: $0 start"
        exit 1
    fi
    
    # 获取路径
    local paths=$(get_mysql_paths)
    eval "$paths"
    
    # 停止现有进程
    print_info "停止现有 MySQL 进程..."
    docker exec ${CONTAINER_NAME} sh -c "pkill -9 mysqld 2>/dev/null; pkill -9 mariadbd 2>/dev/null" || true
    sleep 2
    
    # 修复权限
    print_info "修复文件权限..."
    docker exec ${CONTAINER_NAME} sh -c "
        mkdir -p /var/lib/mysql /var/run/mysqld /run/mysqld /var/log/mysql
        chown -R mysql:mysql /var/lib/mysql
        chown -R mysql:mysql /var/run/mysqld 2>/dev/null || chown -R mysql:mysql /run/mysqld 2>/dev/null
        chown -R mysql:mysql /var/log/mysql
        chmod 755 /var/run/mysqld 2>/dev/null || chmod 755 /run/mysqld 2>/dev/null
        chmod 750 /var/lib/mysql
    "
    
    # 检查是否需要初始化
    if [ ! -d "${DATA_ROOT}/mysql/mysql" ]; then
        print_warn "数据库未初始化，执行初始化..."
        if [ -n "$MYSQLD_PATH" ]; then
            docker exec ${CONTAINER_NAME} sh -c "${MYSQLD_PATH} --initialize-insecure --user=mysql --datadir=/var/lib/mysql" 2>/dev/null
        else
            docker exec ${CONTAINER_NAME} sh -c "
                mysql_install_db --user=mysql --datadir=/var/lib/mysql 2>/dev/null || \
                mysqld --initialize-insecure --user=mysql --datadir=/var/lib/mysql 2>/dev/null
            "
        fi
        sleep 3
    fi
    
    # 尝试启动
    print_info "启动 MySQL..."
    manual_start_mysql
    
    # 验证
    sleep 5
    if docker exec ${CONTAINER_NAME} sh -c "${MYSQLADMIN_PATH:-mysqladmin} ping -h localhost --silent" 2>/dev/null; then
        print_info "✓ MySQL 修复成功！"
        
        # 启动 XBoard 服务
        print_info "启动 XBoard 服务..."
        docker exec ${CONTAINER_NAME} sh -c "cd /www/xboard && php service start" 2>/dev/null || \
        docker exec ${CONTAINER_NAME} php service start 2>/dev/null
    else
        print_error "✗ MySQL 修复失败"
        echo ""
        echo "请尝试以下操作："
        echo "1. 查看容器日志: docker logs ${CONTAINER_NAME}"
        echo "2. 进入容器手动检查: docker exec -it ${CONTAINER_NAME} /bin/sh"
        echo "3. 重新部署: $0 redeploy"
    fi
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
    start_container
    wait_for_mysql
    
    print_info "恢复完成！"
    show_access_info
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
            init_service
            show_access_info
            ;;
        redeploy)
            echo "=========================================="
            echo "XBoard-Distro 重新部署"
            echo "=========================================="
            print_warn "注意: 此操作会删除容器但保留所有数据"
            echo ""
            read -p "确认继续? (回车继续，Ctrl+C 取消): " confirm
            check_root
            check_docker
            check_ports
            remove_old_container
            start_container
            init_service
            show_access_info
            ;;
        backup)
            backup_data
            ;;
        restore)
            restore_data "$2"
            ;;
        status)
            show_status
            ;;
        diagnose)
            diagnose
            ;;
        fix-mysql)
            fix_mysql
            ;;
        start)
            print_info "启动容器..."
            docker start ${CONTAINER_NAME}
            sleep 5
            wait_for_mysql
            docker exec ${CONTAINER_NAME} php service start 2>/dev/null || true
            print_info "容器已启动"
            show_access_info
            ;;
        stop)
            print_info "停止容器..."
            docker exec ${CONTAINER_NAME} php service stop 2>/dev/null || true
            sleep 2
            docker stop ${CONTAINER_NAME}
            print_info "容器已停止"
            ;;
        restart)
            print_info "重启容器..."
            docker exec ${CONTAINER_NAME} php service stop 2>/dev/null || true
            sleep 2
            docker restart ${CONTAINER_NAME}
            sleep 5
            wait_for_mysql
            docker exec ${CONTAINER_NAME} php service start 2>/dev/null || true
            print_info "容器已重启"
            ;;
        logs)
            docker logs -f ${CONTAINER_NAME}
            ;;
        shell)
            print_info "进入容器 shell..."
            docker exec -it ${CONTAINER_NAME} /bin/sh
            ;;
        *)
            echo "XBoard-Distro 部署脚本 - 完全修复版"
            echo ""
            echo "用法: $0 {命令}"
            echo ""
            echo "部署命令:"
            echo "  deploy       - 首次完整部署"
            echo "  redeploy     - 重新部署（保留数据）"
            echo ""
            echo "管理命令:"
            echo "  status       - 查看运行状态"
            echo "  diagnose     - 诊断系统问题"
            echo "  fix-mysql    - 修复 MySQL 启动问题"
            echo "  start        - 启动容器"
            echo "  stop         - 停止容器"
            echo "  restart      - 重启容器"
            echo ""
            echo "数据命令:"
            echo "  backup       - 备份所有数据"
            echo "  restore      - 恢复数据"
            echo ""
            echo "调试命令:"
            echo "  logs         - 查看日志"
            echo "  shell        - 进入容器"
            echo ""
            echo "示例:"
            echo "  $0 deploy                           # 首次部署"
            echo "  $0 diagnose                         # 诊断问题"
            echo "  $0 fix-mysql                        # 修复 MySQL"
            echo "  $0 backup                           # 备份数据"
            exit 1
            ;;
    esac
}

main "$@"
