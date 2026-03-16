#!/bin/sh
# A区模板
# 解析命令行参数
INTERFACE=""
WLAN_USER_ACCOUNT=""
WLAN_USER_PASSWORD=""
UA_TYPE="mobile"  # 默认使用 mobile UA
LOG_LEVEL=1       # 默认日志等级 INFO (0=DEBUG, 1=INFO, 2=ERROR)

# --- 参数解析 ---
while [ $# -gt 0 ]; do
    case $1 in
        --mwan3)
            INTERFACE="$2"
            shift 2
            ;;
        --account)
            WLAN_USER_ACCOUNT="$2"
            shift 2
            ;;
        --password)
            WLAN_USER_PASSWORD="$2"
            shift 2
            ;;
        --ua-type)
            UA_TYPE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# --- 基础配置 ---
CURL_CONNECT_TIMEOUT=3
CURL_MAX_TIME=5
PC_UA="Mozilla%2F5.0%20(Windows%20NT%2010.0%3B%20Win64%3B%20x64)%20AppleWebKit%2F537.36%20(KHTML%2C%20like%20Gecko)%20Chrome%2F134.0.0.0%20Safari%2F537.36"
MOBILE_UA="Mozilla%2F5.0%20%28Linux%3B%20U%3B%20Android%2011%3B%20zh-cn%3B%20MI%209%20Build%2FRKQ1.200826.002%29%20AppleWebKit%2F537.36%20%28KHTML%2C%20likeGecko%29%20Version%2F4.0%20Mobile%20Safari%2F537.36%20MQQBrowser%2F11.9"

# --- 日志函数 ---
# 级别: 0=DEBUG, 1=INFO, 2=ERROR
log() {
    local level_num=$1
    local msg="$2"
    local level_text="UNKNOWN"

    if [ "$level_num" -ge "$LOG_LEVEL" ]; then
        case "$level_num" in
            0) level_text="DEBUG" ;;
            1) level_text="INFO" ;;
            2) level_text="ERROR" ;;
        esac
        
        local log_msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$INTERFACE] [$level_text] $msg"
        echo "$log_msg" >> /var/log/multilogin.log
        
        # 写入 syslog
        local level_text_lower=$(echo "$level_text" | tr '[:upper:]' '[:lower:]')
        logger -t "multi_login_sh" -p "user.${level_text_lower}" "$log_msg"
        echo "$log_msg"
    fi
}

# --- 统一的网络请求封装 ---
# 处理 mwan3 调用和超时逻辑
curl_req() {
    local url="$1"
    # 使用 --connect-timeout 限制连接时间，-m 限制总传输时间
    mwan3 use "$INTERFACE" curl -s --connect-timeout "$CURL_CONNECT_TIMEOUT" -m "$CURL_MAX_TIME" "$url"
}

# --- 初始化检查 ---
init_check() {
    if [ -z "$INTERFACE" ] || [ -z "$WLAN_USER_ACCOUNT" ] || [ -z "$WLAN_USER_PASSWORD" ]; then
        log 2 "缺少必要的参数 --mwan3, --account, 或 --password"
        exit 4
    fi

    PHYSICAL_INTERFACE=$(/sbin/uci get "network.$INTERFACE.device" 2>/dev/null)
    if [ -z "$PHYSICAL_INTERFACE" ]; then
        log 2 "无法通过uci获取逻辑接口 '$INTERFACE' 的物理设备名称"
        exit 5
    fi
    log 0 "逻辑接口 '$INTERFACE' 对应的物理接口是 '$PHYSICAL_INTERFACE'"

    # 获取 MAC 和 IP (使用 ip 命令替换 ifconfig，兼容性更好)
    WLAN_USER_MAC=$(cat "/sys/class/net/$PHYSICAL_INTERFACE/address" 2>/dev/null | tr -d ':')
    WLAN_USER_IP=$(ip -4 addr show dev "$PHYSICAL_INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)

    if [ -z "$WLAN_USER_IP" ] || [ -z "$WLAN_USER_MAC" ]; then
        log 2 "无法获取接口 '$PHYSICAL_INTERFACE' 的IP地址或MAC地址"
        exit 6
    fi
}

# --- 状态检测函数 ---
check_status() {
    local status_url="http://10.254.7.4/drcom/chkstatus?callback=dr1002&jsVersion=4.X&v=5505&lang=zh"
    local response=$(curl_req "$status_url")

    # 1. 检测请求是否超时或为空
    if [ -z "$response" ]; then
        log 1 "状态检查超时或无响应，假定未认证，准备强制登录..."
        return 1
    fi

    # 2. 网关劫持判定 (未登录跳 portal)
    if echo "$response" | grep -q "WISPAccessGatewayParam"; then
        log 1 "请求被网关劫持 (未认证)，继续登录流程..."
        return 1
    fi
    
    # 3. 解析 JSON 结果字段
    local result=$(echo "$response" | grep -o '"result":[0-9]' | cut -d':' -f2)
    
    if [ "$result" = "1" ]; then
        log 0 "当前已认证，无需重复登录"
        return 0
    elif [ "$result" = "0" ]; then
        log 1 "状态返回0 (未认证)，继续登录流程..."
        return 1
    else
        # 返回了预期外的数据，同样假定未认证进行兜底
        log 2 "状态检查解析失败响应异常，强制尝试登录。响应: $response"
        return 1 
    fi
}

# --- 执行登录函数 ---
do_login() {
    local LOGIN_URL=""

    # 根据UA类型选择URL和参数 (保留原版精准的参数拼接)
    if [ "$UA_TYPE" = "pc" ]; then
        LOGIN_URL="http://login.cqu.edu.cn:801/eportal/portal/login?callback=dr1004&login_method=1&user_account=%2C0%2C$WLAN_USER_ACCOUNT&user_password=$WLAN_USER_PASSWORD&wlan_user_ip=$WLAN_USER_IP&wlan_user_ipv6=&wlan_user_mac=$WLAN_USER_MAC&wlan_ac_ip=&wlan_ac_name=&term_ua=$PC_UA&term_type=1&jsVersion=4.2&terminal_type=1&lang=zh-cn&v=2246&lang=zh"
    else
        LOGIN_URL="http://login.cqu.edu.cn:801/eportal/portal/login?callback=dr1005&login_method=1&user_account=%2C1%2C$WLAN_USER_ACCOUNT&user_password=$WLAN_USER_PASSWORD&wlan_user_ip=$WLAN_USER_IP&wlan_user_ipv6=&wlan_user_mac=$WLAN_USER_MAC&wlan_ac_ip=&wlan_ac_name=&term_ua=$MOBILE_UA&term_type=2&jsVersion=4.2&terminal_type=2&lang=zh-cn&v=2662&lang=zh"
    fi
    
    log 1 "尝试登录 ($UA_TYPE UA)，使用IP: $WLAN_USER_IP, MAC: $WLAN_USER_MAC"
    
    local response=$(curl_req "$LOGIN_URL")
    
    # 处理超时
    if [ -z "$response" ]; then
        log 2 "登录请求超时或无网络响应！"
        return 1
    fi

    local json_response=$(echo "$response" | grep -o '{.*}')
    
    if [ -n "$json_response" ]; then
        # 正常登录成功
        if echo "$json_response" | grep -q '"result":1'; then
            log 1 "登录成功！IP: $WLAN_USER_IP"
            return 0
        # 兼容“已经在线”的情况 (避免重复登录导致的报错死循环)
        elif echo "$json_response" | grep -q '"ret_code":2' || echo "$json_response" | grep -q '已经在线'; then
            log 1 "登录放行：该 IP 已经在线，无需重复认证！IP: $WLAN_USER_IP"
            return 0
        # 真正的登录失败
        else
            log 2 "登录失败！网关拒绝响应: $json_response"
            return 1
        fi
    else
        log 2 "登录失败！无法解析网关响应: $response"
        return 1
    fi
}

# --- 主流程 ---
main() {
    init_check
    
    check_status
    local status=$?

    if [ $status -eq 0 ]; then
        # 已经在线
        exit 2
    else
        # 离线、超时或状态未知，执行登录
        if do_login; then
            exit 0
        else
            exit 1
        fi
    fi
}

# 执行主程序
main