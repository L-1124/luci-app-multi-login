#!/bin/bash

# Implementation logic:
# 1. Load multiple login instances from UCI config.
# 2. Main loop checks each interface status through mwan4 and attempts login if offline.

LOGIN_SCRIPT_PATH="/etc/multilogin/login.sh"

INITIAL_RETRY_DELAY=4
MAX_RETRY_DELAY=16384
ALREADY_LOGGED_DELAY=16
MAIN_LOOP_SLEEP=5
LOG_LEVEL="info"

level_to_num() {
  case "$1" in
    debug) echo 7 ;;
    info) echo 6 ;;
    notice) echo 5 ;;
    warning|warn) echo 4 ;;
    error|err) echo 3 ;;
    *) echo 6 ;;
  esac
}

map_to_logger_severity() {
  case "$1" in
    error) echo err ;;
    warn) echo warning ;;
    *) echo "$1" ;;
  esac
}

log() {
  local level=$1
  shift
  local message="$*"

  local msg_lvl_num=$(level_to_num "$level")
  local conf_lvl_num=$(level_to_num "$LOG_LEVEL")
  if [ "$msg_lvl_num" -gt "$conf_lvl_num" ]; then
    return 0
  fi

  local log_msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$$] [$level] $message"
  echo "$log_msg" >> /var/log/multilogin.log
  local sys_sev=$(map_to_logger_severity "$level")
  logger -t "multi_login[$$]" -p "user.$sys_sev" "[$level] $message"
}

get_interface_status_json() {
  local interface="$1"
  ubus call mwan4 status "{\"section\":\"interfaces\",\"interface\":\"$interface\"}" 2>/dev/null
}

get_interface_status_field() {
  local json="$1"
  local field="$2"
  jsonfilter -s "$json" -e "@.interfaces.*.$field" 2>/dev/null
}

login_interface() {
  local logical_interface=$1
  local account=$2
  local password=$3
  local ua_type=$4
  local login_script=$5
  local delay_var_name=$6

  eval "current_delay=\${$delay_var_name}"

  [ -f "$login_script" ] || {
    log "error" "$logical_interface ERROR: Login script '$login_script' not found"
    return 3
  }

  log "info" "$logical_interface Attempting login... (Account: $account, UA: $ua_type)"

  sh "$login_script" --mwan4 "$logical_interface" --account "$account" --password "$password" --ua-type "$ua_type" >"/tmp/login_output_$logical_interface" 2>&1
  local login_result=$?
  rm -f "/tmp/login_output_$logical_interface"

  case $login_result in
    0)
      log "notice" "$logical_interface Login successful"
      eval "$delay_var_name=$INITIAL_RETRY_DELAY"
      return 0
      ;;
    1)
      local new_delay=$((current_delay * 2))
      [ $new_delay -gt $MAX_RETRY_DELAY ] && new_delay=$MAX_RETRY_DELAY
      eval "$delay_var_name=$new_delay"
      log "warning" "$logical_interface Login failed, will retry in ${new_delay}s"
      return 1
      ;;
    2)
      log "info" "$logical_interface Already logged in, will check again in ${ALREADY_LOGGED_DELAY}s"
      eval "$delay_var_name=$ALREADY_LOGGED_DELAY"
      return 2
      ;;
    *)
      log "error" "$logical_interface Login script returned unknown status: $login_result"
      eval "$delay_var_name=$INITIAL_RETRY_DELAY"
      return 3
      ;;
  esac
}

main() {
  if ! command -v mwan4 >/dev/null 2>&1; then
    log "error" "mwan4 not installed or not in PATH. Cannot continue."
    exit 1
  fi
  if ! command -v ubus >/dev/null 2>&1; then
    log "error" "ubus command not available. Cannot query mwan4 status."
    exit 1
  fi
  if ! command -v jsonfilter >/dev/null 2>&1; then
    log "error" "jsonfilter command not available. Cannot parse mwan4 status."
    exit 1
  fi

  if ! uci -q get multilogin.global >/dev/null 2>&1; then
    log "error" "UCI config 'multilogin' not found or global settings missing."
    exit 1
  fi

  local global_enabled=$(uci -q get multilogin.global.enabled)
  if [ "$global_enabled" != "1" ]; then
    log "notice" "Multi-login disabled in global settings, exiting."
    exit 0
  fi

  INITIAL_RETRY_DELAY=$(uci -q get multilogin.global.retry_interval || echo $INITIAL_RETRY_DELAY)
  MAIN_LOOP_SLEEP=$(uci -q get multilogin.global.check_interval || echo $MAIN_LOOP_SLEEP)
  MAX_RETRY_DELAY=$(uci -q get multilogin.global.max_retry_delay || echo $MAX_RETRY_DELAY)
  ALREADY_LOGGED_DELAY=$(uci -q get multilogin.global.already_logged_delay || echo $ALREADY_LOGGED_DELAY)
  LOG_LEVEL=$(uci -q get multilogin.global.log_level || echo $LOG_LEVEL)

  declare -a logical_interfaces
  declare -a accounts
  declare -a passwords
  declare -a ua_types
  declare -a delays

  local index=0
  while read -r section_name; do
    [ -z "$section_name" ] && continue

    local instance_enabled=$(uci -q get multilogin."$section_name".enabled)
    [ "$instance_enabled" != "1" ] && continue

    local interface=$(uci -q get multilogin."$section_name".interface)
    local ua_type=$(uci -q get multilogin."$section_name".ua_type)
    [ -z "$ua_type" ] && ua_type="pc"

    local account_ref=$(uci -q get multilogin."$section_name".account)
    local username=""
    local password=""
    if [ -n "$account_ref" ]; then
      username=$(uci -q get multilogin."$account_ref".username)
      password=$(uci -q get multilogin."$account_ref".password)
    fi

    if [ -z "$interface" ] || [ -z "$username" ] || [ -z "$password" ]; then
      log "warning" "Instance '$section_name' config incomplete, skipped."
      continue
    fi

    logical_interfaces[$index]="$interface"
    accounts[$index]="$username"
    passwords[$index]="$password"
    ua_types[$index]="$ua_type"
    delays[$index]=$INITIAL_RETRY_DELAY

    log "info" "Loaded instance #$index: Interface=$interface, Account=$account_ref ($username), UA=$ua_type"
    index=$((index + 1))
  done < <(uci show multilogin | awk -F'[.=]' '$3 == "instance" {print $2}' | sort)

  if [ ${#logical_interfaces[@]} -eq 0 ]; then
    log "error" "No enabled login instances found. Daemon will continue running but perform no login operations."
    log "info" "Starting multi-WAN auto-login daemon (PID: $$) with no active instances."
  else
    log "info" "Starting multi-WAN auto-login daemon (PID: $$), loaded ${#logical_interfaces[@]} instances."
  fi

  declare -a last_login_time
  for i in "${!logical_interfaces[@]}"; do
    last_login_time[$i]=0
  done

  while true; do
    if [ ${#logical_interfaces[@]} -eq 0 ]; then
      sleep $MAIN_LOOP_SLEEP
      continue
    fi

    local current_time=$(date +%s)

    for i in "${!logical_interfaces[@]}"; do
      local interface="${logical_interfaces[$i]}"
      local time_diff=$((current_time - last_login_time[$i]))

      if [ $time_diff -lt ${delays[$i]} ]; then
        continue
      fi

      local status_json
      status_json=$(get_interface_status_json "$interface")
      if [ -z "$status_json" ]; then
        log "warning" "Failed to get mwan4 status for '$interface'."
        continue
      fi

      local interface_status tracking_status enabled_status
      interface_status=$(get_interface_status_field "$status_json" status)
      tracking_status=$(get_interface_status_field "$status_json" tracking)
      enabled_status=$(get_interface_status_field "$status_json" enabled)

      if [ -z "$interface_status" ]; then
        log "debug" "Interface '$interface' not found in mwan4 status, skipping."
        continue
      fi

      if [ "$enabled_status" != "true" ] && [ "$enabled_status" != "1" ]; then
        log "debug" "Interface '$interface' is disabled in mwan4, skipping."
        continue
      fi

      if [ "$tracking_status" = "down" ] || [ "$tracking_status" = "disabled" ]; then
        log "debug" "Interface '$interface' tracking is $tracking_status, skipping login attempt."
        continue
      fi

      if [ "$interface_status" = "offline" ]; then
        log "info" "$interface detected as offline by mwan4, preparing to login."
        login_interface "$interface" "${accounts[$i]}" "${passwords[$i]}" "${ua_types[$i]}" "$LOGIN_SCRIPT_PATH" "delays[$i]"
        last_login_time[$i]=$current_time
      elif [ "$interface_status" = "online" ] && [ ${delays[$i]} -ne $INITIAL_RETRY_DELAY ]; then
        log "debug" "$interface is online, resetting its delay."
        delays[$i]=$INITIAL_RETRY_DELAY
      fi
    done

    sleep $MAIN_LOOP_SLEEP
  done
}

trap 'log "notice" "Received termination signal, exiting"; exit 0' INT TERM
main
