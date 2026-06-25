#!/usr/bin/env bash
# xm.sh - 强大的 Realm 管理脚本
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m[ERROR] 此脚本必须以 root 用户执行！\033[0m" >&2
    exit 1
fi

XM_DIR="/root/xm"
BIN_DIR="$XM_DIR/bin"
LOG_DIR="$XM_DIR/log"
CONF_DIR="$XM_DIR/conf"
mkdir -p "$BIN_DIR" "$LOG_DIR" "$CONF_DIR"

NETWORK_DIR="$CONF_DIR/network"
ENDPOINTS_DIR="$CONF_DIR/endpoints"
mkdir -p "$NETWORK_DIR" "$ENDPOINTS_DIR"

CONFIG_FILE="$CONF_DIR/config.json"
NETWORK_FILE="$NETWORK_DIR/network.json"
LOG_FILE="$LOG_DIR/realm.log"
REALM_BIN="$BIN_DIR/realm"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

install_deps() {
    echo -e "${YELLOW}[INFO] 安装依赖 ...${NC}"
    (apt install -y curl tar net-tools iproute2 jq netcat-openbsd coreutils 2>/dev/null ||
     yum install -y curl tar net-tools iproute jq nmap-ncat coreutils 2>/dev/null ||
     apk add curl tar net-tools iproute2 jq netcat-openbsd coreutils 2>/dev/null) || {
        echo -e "${RED}[ERROR] 依赖安装失败${NC}"
        exit 1
    }
}

detect_system() {
    arch=$(uname -m)
    case "$arch" in
        x86_64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) echo -e "${RED}[ERROR] 不支持的架构: $arch${NC}"; exit 1 ;;
    esac
    ldd --version 2>&1 | grep -qi musl && LIBC="musl" || LIBC="gnu"

    if [[ -d /run/systemd/system ]] || [[ -f /usr/lib/systemd/systemd ]]; then
        INIT="systemd"
    elif [[ -f /sbin/openrc-run ]]; then
        INIT="openrc"
    else
        echo -e "${RED}[ERROR] 未检测到支持的 init 系统（systemd 或 openrc）${NC}"; exit 1
    fi
    echo -e "${GREEN}[INFO] 系统: $ARCH, libc: $LIBC, init: $INIT${NC}"
}

download_realm() {
    url="https://github.com/zhboner/realm/releases/latest/download/realm-${ARCH}-unknown-linux-${LIBC}.tar.gz"
    tmp_dir=$(mktemp -d)
    echo -e "${YELLOW}[INFO] Realm 下载中...${NC}"
    curl -# -L "$url" -o "$tmp_dir/realm.tar.gz" || { rm -rf "$tmp_dir"; echo -e "${RED}[ERROR] 下载失败${NC}"; exit 1; }
    tar -xzf "$tmp_dir/realm.tar.gz" -C "$tmp_dir" realm
    mv "$tmp_dir/realm" "$REALM_BIN"
    chmod +x "$REALM_BIN"
    rm -rf "$tmp_dir"
    echo -e "${GREEN}[INFO] Realm 已安装${NC}"
}

service_ctl() {
    local action=$1
    case "$INIT" in
        systemd) systemctl $action realm ;;
        openrc)  rc-service realm $action ;;
    esac
}

install_service() {
    local user=root
    case "$INIT" in
        systemd)
            tee /etc/systemd/system/realm.service > /dev/null <<EOF
[Unit]
Description=Realm Port Forwarding
After=network.target
[Service]
Type=simple
User=$user
WorkingDirectory=$XM_DIR
ExecStart=$REALM_BIN -c $CONFIG_FILE
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable realm
            ;;
        openrc)
            tee /etc/init.d/realm > /dev/null <<EOF
#!/sbin/openrc-run
command="$REALM_BIN"
command_args="-c $CONFIG_FILE"
command_user="$user"
pidfile="/run/realm.pid"
command_background=true
EOF
            chmod +x /etc/init.d/realm
            rc-update add realm default
            ;;
    esac
    echo -e "${GREEN}[INFO] 服务已安装${NC}"
}

remove_service() {
    case "$INIT" in
        systemd) systemctl disable realm; rm -f /etc/systemd/system/realm.service; systemctl daemon-reload ;;
        openrc)  rc-update del realm; rm -f /etc/init.d/realm ;;
    esac
    echo -e "${GREEN}[INFO] 服务已移除${NC}"
}

install_realm() {
    install_deps
    detect_system
    download_realm
    install_service
    service_ctl start
}

update_realm() {
    detect_system
    service_ctl stop || true
    download_realm
    service_ctl start
}

uninstall_realm() {
    service_ctl stop || true
    remove_service
    rm -rf "$XM_DIR"
    echo -e "${GREEN}[INFO] 已卸载${NC}"
}

read_network() {
    local enable_tcp="${ENABLE_TCP:-}"
    local enable_udp="${ENABLE_UDP:-}"

    if [[ -n "$enable_tcp" || -n "$enable_udp" ]]; then
        echo "{\"no_tcp\":$( [[ "$enable_tcp" == "true" ]] && echo false || echo true ), \"use_udp\":$( [[ "$enable_udp" == "true" ]] && echo true || echo false )}"
    else
        if [[ -f "$NETWORK_FILE" ]]; then
            cat "$NETWORK_FILE"
        else
            echo '{"no_tcp":false,"use_udp":true}'
        fi
    fi
}

read_endpoints() {
    local first=true
    echo "["
    for f in "$ENDPOINTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$first" == true ]] && first=false || echo ","
        cat "$f"
    done
    echo "]"
}

generate_config() {
    local tmp_config=$(mktemp)
    cat > "$tmp_config" <<EOF
{
  "log": { "level": "warn", "output": "$LOG_FILE" },
  "network": $(read_network),
  "endpoints": $(read_endpoints)
}
EOF

    if ! jq empty "$tmp_config" 2>/dev/null; then
        echo -e "${RED}[ERROR] 生成的配置文件无效，请检查规则文件格式${NC}" >&2
        rm -f "$tmp_config"
        exit 1
    fi

    mv "$tmp_config" "$CONFIG_FILE"
    echo -e "${GREEN}[INFO] 配置文件已生成${NC}"
}

write_endpoint() {
    local listen=$1 remote=$2 extra_remotes=$3 balance=$4
    local port=$(echo "$listen" | awk -F: '{print $NF}')
    local file="$ENDPOINTS_DIR/${port}.json"
    if [[ -z "$extra_remotes" || "$extra_remotes" == "[]" ]]; then
        cat > "$file" <<EOF
{
  "listen": "$listen",
  "remote": "$remote"
}
EOF
    else
        if [[ -z "$balance" ]]; then
            echo -e "${RED}[ERROR] 请提供 balance 策略${NC}"
            exit 1
        fi
        cat > "$file" <<EOF
{
  "listen": "$listen",
  "remote": "$remote",
  "extra_remotes": $extra_remotes,
  "balance": "$balance"
}
EOF
    fi
    echo -e "${GREEN}[INFO] 规则已保存: $file${NC}"
}

list_endpoints() {
    if [[ -f "$CONFIG_FILE" ]] && jq -e '.endpoints | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then
        echo "当前规则列表:"
        jq '.endpoints[]' "$CONFIG_FILE"
    else
        echo "当前没有规则。"
    fi
}

check_port() {
    local port=$1
    if ss -lpn 2>/dev/null | grep -q ":${port}.*LISTEN.*realm"; then
        return 0
    elif ss -lpn 2>/dev/null | grep -q ":${port}.*LISTEN"; then
        echo -e "${RED}[ERROR] 端口 $port 被其他进程占用${NC}"
        return 1
    fi
    return 0
}

expand_ports() {
    local input="$1"
    local ports=()
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)
        if [[ "$part" =~ ^[0-9]+$ ]]; then
            ports+=("$part")
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            if [[ $start -le $end ]]; then
                for ((p=start; p<=end; p++)); do
                    ports+=("$p")
                done
            else
                echo -e "${RED}[ERROR] 端口范围错误: $part${NC}" >&2
                exit 1
            fi
        else
            echo -e "${RED}[ERROR] 无效端口格式: $part${NC}" >&2
            exit 1
        fi
    done
    printf '%s\n' "${ports[@]}" | sort -nu
}

validate_addr() {
    local addr=$1
    if [[ ! "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] && \
       [[ ! "$addr" =~ ^\[[0-9a-fA-F:]+\]:[0-9]+$ ]] && \
       [[ ! "$addr" =~ ^[0-9a-fA-F:]+:[0-9]+$ ]]; then
        echo -e "${RED}[ERROR] 地址格式错误，应为 IP:PORT 或 [IPv6]:PORT${NC}" >&2
        return 1
    fi
    local port=${addr##*:}
    if [[ $port -lt 1 || $port -gt 65535 ]]; then
        echo -e "${RED}[ERROR] 端口号必须在 1-65535 之间${NC}" >&2
        return 1
    fi
    return 0
}

validate_strategy() {
    [[ "$1" == "roundrobin" || "$1" == "iphash" ]] && return 0
    echo -e "${RED}[ERROR] 策略仅支持 roundrobin 或 iphash${NC}" >&2
    return 1
}

validate_weights() {
    local weights_str=$1
    local extra_count=$2
    IFS=',' read -ra w_arr <<< "$weights_str"
    local count=${#w_arr[@]}
    local expected=$((extra_count + 1))
    if [[ $count -ne $expected ]]; then
        echo -e "${RED}[ERROR] 权重数量（$count）必须等于远程数量（$expected）${NC}" >&2
        return 1
    fi
    for w in "${w_arr[@]}"; do
        if ! [[ "$w" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}[ERROR] 权重必须是正整数${NC}" >&2
            return 1
        fi
    done
    return 0
}

validate_endpoint() {
    local ep=$1
    local listen=$(echo "$ep" | jq -r '.listen')
    local remote=$(echo "$ep" | jq -r '.remote')
    local extra=$(echo "$ep" | jq -r '.extra_remotes // ""')
    local balance=$(echo "$ep" | jq -r '.balance // ""')

    if ! validate_addr "$listen" || ! validate_addr "$remote"; then
        return 1
    fi

    if [[ -n "$extra" && "$extra" != "[]" ]]; then
        local extra_count=$(echo "$extra" | jq -r 'length')
        for ((i=0; i<extra_count; i++)); do
            local addr=$(echo "$extra" | jq -r ".[$i]")
            if ! validate_addr "$addr"; then
                return 1
            fi
        done
        if [[ -z "$balance" ]]; then
            echo -e "${RED}[ERROR] 有 extra_remotes 时必须提供 balance${NC}" >&2
            return 1
        fi
        local strategy=$(echo "$balance" | jq -r '.strategy')
        local weights=$(echo "$balance" | jq -r '.weights | join(",")')
        if ! validate_strategy "$strategy" || ! validate_weights "$weights" "$extra_count"; then
            return 1
        fi
    else
        if [[ -n "$balance" ]]; then
            echo -e "${RED}[ERROR] 没有 extra_remotes 时不能指定 balance${NC}" >&2
            return 1
        fi
    fi
    return 0
}

test_remote() {
    if [[ "${ENABLE_TCP:-}" == "false" ]]; then
        echo -e "${YELLOW}[INFO] TCP 已全局禁用，跳过测试${NC}"
        return 0
    fi

    local addr=$1
    local host port
    if [[ "$addr" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$addr" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$addr" =~ ^([0-9a-fA-F:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        echo -e "${YELLOW}[WARN] 无法解析地址: $addr，跳过测试${NC}"
        return 1
    fi

    echo -e "${YELLOW}[INFO] 测试 $addr ...${NC}"
    if command -v nc &>/dev/null; then
        if nc -z -w 2 "$host" "$port" 2>/dev/null; then
            echo -e "${GREEN}[INFO] 成功连接: $addr${NC}"
            return 0
        else
            echo -e "${YELLOW}[WARN] 无法连接到 $addr${NC}"
            return 1
        fi
    else
        if timeout 2 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
            echo -e "${GREEN}[INFO] 成功连接: $addr${NC}"
            return 0
        else
            echo -e "${YELLOW}[WARN] 无法连接到 $addr${NC}"
            return 1
        fi
    fi
}

test_all_remotes() {
    echo -e "${YELLOW}[INFO] 开始测试所有远程地址的连通性...${NC}"
    local fail_count=0
    local total=0
    local failed_addrs=()

    if ! ls "$ENDPOINTS_DIR"/*.json &>/dev/null; then
        echo -e "${YELLOW}[INFO] 当前没有任何规则，无法测试。${NC}"
        return
    fi

    for f in "$ENDPOINTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        local rule_name=$(basename "$f")

        local remote=$(jq -r '.remote' "$f")
        if [[ -n "$remote" && "$remote" != "null" ]]; then
            total=$((total+1))
            if ! test_remote "$remote"; then
                fail_count=$((fail_count+1))
                failed_addrs+=("$remote (规则 $rule_name)")
            fi
        fi

        local extras=$(jq -r '.extra_remotes[]? // empty' "$f")
        for extra in $extras; do
            total=$((total+1))
            if ! test_remote "$extra"; then
                fail_count=$((fail_count+1))
                failed_addrs+=("$extra (规则 $rule_name)")
            fi
        done
    done

    echo -e "\n${YELLOW}[INFO] 测试完成，总计 $total 个远程地址，失败 $fail_count 个。${NC}"
    if [[ $fail_count -eq 0 ]]; then
        echo -e "${GREEN}所有远程地址均可达。${NC}"
    else
        echo -e "${RED}存在 $fail_count 个不可达地址:${NC}"
        for addr in "${failed_addrs[@]}"; do
            echo -e "  ${RED}✗${NC} $addr"
        done
    fi
}

add_rules() {
    [[ -z "${XM_ADD_JSON:-}" ]] && { echo -e "${RED}[ERROR] 需要 XM_ADD_JSON${NC}"; exit 1; }

    local len=$(echo "$XM_ADD_JSON" | jq -r 'length')
    for ((i=0; i<len; i++)); do
        ep=$(echo "$XM_ADD_JSON" | jq -r ".[$i]")
        if ! validate_endpoint "$ep"; then
            echo -e "${RED}[ERROR] 第 $((i+1)) 个规则校验失败${NC}" >&2
            exit 1
        fi
        listen=$(echo "$ep" | jq -r '.listen')
        port=$(echo "$listen" | awk -F: '{print $NF}')
        if ! check_port "$port"; then
            echo -e "${RED}[ERROR] 端口 $port 被占用${NC}" >&2
            exit 1
        fi
    done

    for ((i=0; i<len; i++)); do
        ep=$(echo "$XM_ADD_JSON" | jq -r ".[$i]")
        remote=$(echo "$ep" | jq -r '.remote')
        test_remote "$remote"
        if echo "$ep" | jq -e '.extra_remotes' >/dev/null 2>&1; then
            extras=$(echo "$ep" | jq -r '.extra_remotes[]?')
            for extra in $extras; do
                test_remote "$extra"
            done
        fi
    done

    if [[ "${XM_CLEAR:-}" == "true" ]]; then
        rm -f "$ENDPOINTS_DIR"/*.json
    fi

    for ((i=0; i<len; i++)); do
        ep=$(echo "$XM_ADD_JSON" | jq -r ".[$i]")
        listen=$(echo "$ep" | jq -r '.listen')
        remote=$(echo "$ep" | jq -r '.remote')
        extra=$(echo "$ep" | jq -r '.extra_remotes // ""')
        balance=$(echo "$ep" | jq -r '.balance // ""')
        write_endpoint "$listen" "$remote" "$extra" "$balance"
    done

    generate_config
    service_ctl restart
}

delete_rule() {
    [[ -z "${XM_DELETE_PORT:-}" ]] && { echo -e "${RED}[ERROR] 需要 XM_DELETE_PORT${NC}"; exit 1; }
    mapfile -t port_list < <(expand_ports "$XM_DELETE_PORT")
    for port in "${port_list[@]}"; do
        rm -f "$ENDPOINTS_DIR/${port}.json"
        echo -e "${GREEN}[INFO] 已删除端口 $port 的规则${NC}"
    done
    generate_config
    service_ctl restart
}

add_rule_interactive() {
    read -p "清空现有规则？(y/n): " clear
    [[ "$clear" =~ ^[Yy]$ ]] && rm -f "$ENDPOINTS_DIR"/*.json

    while true; do
        read -p "监听 (如 0.0.0.0:10000): " listen
        validate_addr "$listen" && break
    done

    port=$(echo "$listen" | awk -F: '{print $NF}')
    check_port "$port" || return 1

    while true; do
        read -p "远程 (如 127.0.0.1:20000): " remote
        validate_addr "$remote" && break
    done

    if ! test_remote "$remote"; then
        read -p "是否继续添加此规则？(y/n): " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}[INFO] 已取消添加规则${NC}"
            return 1
        fi
    fi

    extra="[]"
    balance=""
    read -p "有额外远程？(y/n): " has_extra
    if [[ "$has_extra" =~ ^[Yy]$ ]]; then
        echo "输入地址，空行结束:"
        extras=()
        while read -p "> " addr; do
            [[ -z "$addr" ]] && break
            if ! validate_addr "$addr"; then
                echo -e "${RED}无效地址，请重新输入${NC}" >&2
                continue
            fi
            if ! test_remote "$addr"; then
                read -p "是否继续添加此规则？(y/n): " continue_choice
                if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}[INFO] 已取消添加规则${NC}"
                    return 1
                fi
            fi
            extras+=("\"$addr\"")
        done
        [[ ${#extras[@]} -gt 0 ]] && extra="[$(IFS=,; echo "${extras[*]}")]" || extra="[]"

        while true; do
            read -p "策略 (roundrobin/iphash): " strategy
            validate_strategy "$strategy" && break
        done

        local extra_count=${#extras[@]}
        while true; do
            read -p "权重 (如 4,2,1，数量需为额外远程数+1): " weights
            validate_weights "$weights" "$extra_count" && break
        done

        balance=$(jq -n --arg strategy "$strategy" --arg weights "$weights" \
            '{strategy: $strategy, weights: ($weights | split(",") | map(tonumber))}')
    fi

    write_endpoint "$listen" "$remote" "$extra" "$balance"
    generate_config
    service_ctl restart
}

delete_rule_interactive() {
    list_endpoints
    read -p "输入要删除的端口（支持逗号和范围，如 10001,10002,20001-20002）: " input
    mapfile -t port_list < <(expand_ports "$input")
    for port in "${port_list[@]}"; do
        rm -f "$ENDPOINTS_DIR/${port}.json"
        echo -e "${GREEN}[INFO] 已删除端口 $port 的规则${NC}"
    done
    generate_config
    service_ctl restart
}

if [[ -n "${XM_ACTION:-}" ]]; then
    case "$XM_ACTION" in
        install)   install_realm ;;
        update)    update_realm ;;
        uninstall) uninstall_realm ;;
        add)       add_rules ;;
        delete)    delete_rule ;;
        *) echo -e "${RED}[ERROR] 未知动作${NC}"; exit 1 ;;
    esac
else
    while true; do
        echo
        echo "===== Realm 管理菜单 ====="
        echo "1. 安装 Realm"
        echo "2. 更新 Realm"
        echo "3. 卸载 Realm"
        echo "4. 查看规则"
        echo "5. 添加规则"
        echo "6. 删除规则"
        echo "7. 测试远程连通性"
        echo "0. 退出"
        read -p "请选择 [0-7]: " opt
        case $opt in
            1) install_realm ;;
            2) update_realm ;;
            3) 
                read -p "确认卸载 Realm？（所有配置和数据将被删除）[y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_realm
                else
                    echo -e "${YELLOW}已取消卸载${NC}"
                fi
                ;;
            4) list_endpoints ;;
            5) add_rule_interactive ;;
            6) delete_rule_interactive ;;
            7) test_all_remotes ;;
            0) exit 0 ;;
            *) echo "无效选项" ;;
        esac
    done
fi