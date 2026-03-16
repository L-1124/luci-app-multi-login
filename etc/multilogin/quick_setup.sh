#!/bin/sh

# Quick Setup Script for Virtual Interfaces & mwan4
# Usage: /etc/multilogin/quick_setup.sh <base_interface> <count>
# Example: /etc/multilogin/quick_setup.sh eth0 3

BASE_IF=$1
COUNT=$2

if [ -z "$BASE_IF" ] || [ -z "$COUNT" ]; then
    echo "Usage: $0 <base_interface> <count>"
    exit 1
fi

COUNT=$((COUNT))

echo "Starting configuration for $COUNT interfaces based on $BASE_IF..."

echo "Cleaning up old auto_ configurations..."
for type in network firewall mwan4; do
    uci show $type 2>/dev/null | grep 'auto_' | awk -F. '{print $2}' | awk -F= '{print $1}' | sort -u | while read -r section; do
        uci -q delete $type."$section"
    done
done

WAN_ZONE=$(uci show firewall | grep '=zone' | grep -B1 "name='wan'" | awk -F. '{print $2}' | head -n1)
if [ -z "$WAN_ZONE" ]; then
    uci set firewall.wan=zone
    uci set firewall.wan.name='wan'
    uci set firewall.wan.input='REJECT'
    uci set firewall.wan.output='ACCEPT'
    uci set firewall.wan.forward='REJECT'
    uci set firewall.wan.masq='1'
    uci set firewall.wan.mtu_fix='1'
    WAN_ZONE="wan"
fi

for intf in $(uci -q get firewall."$WAN_ZONE".network); do
    case "$intf" in
        auto_*) uci del_list firewall."$WAN_ZONE".network="$intf" ;;
    esac
done

for route in $(uci -q get mwan4.balanced.use_route 2>/dev/null); do
    case "$route" in
        auto_*) uci del_list mwan4.balanced.use_route="$route" ;;
    esac
done

uci -q get mwan4.globals >/dev/null 2>&1 || uci set mwan4.globals=globals
uci -q get mwan4.globals.mmx_mask >/dev/null 2>&1 || uci set mwan4.globals.mmx_mask='0x3F00'
uci -q get mwan4.balanced >/dev/null 2>&1 || uci set mwan4.balanced=strategy
uci -q get mwan4.default_rule_v4 >/dev/null 2>&1 || uci set mwan4.default_rule_v4=rule
uci set mwan4.default_rule_v4.dest_ip='0.0.0.0/0'
uci set mwan4.default_rule_v4.use_strategy='balanced'
uci del mwan4.default_rule_v4.family 2>/dev/null
uci add_list mwan4.default_rule_v4.family='ipv4'

NEW_INTERFACES=""

for i in $(seq 1 $COUNT); do
    MACVLAN_DEV="auto_${BASE_IF}_${i}"
    LOGICAL_IF="auto_vwan_${i}"
    MWAN_ROUTE="auto_vwan_${i}_m1_w5"
    METRIC=$((10 + i))

    uci set network.$MACVLAN_DEV=device
    uci set network.$MACVLAN_DEV.type='macvlan'
    uci set network.$MACVLAN_DEV.ifname="$BASE_IF"
    uci set network.$MACVLAN_DEV.name="$MACVLAN_DEV"
    uci set network.$MACVLAN_DEV.mode='private'
    uci set network.$MACVLAN_DEV.ipv6='0'

    uci set network.$LOGICAL_IF=interface
    uci set network.$LOGICAL_IF.proto='dhcp'
    uci set network.$LOGICAL_IF.device="$MACVLAN_DEV"
    uci set network.$LOGICAL_IF.metric="$METRIC"

    NEW_INTERFACES="$NEW_INTERFACES $LOGICAL_IF"

    uci set mwan4.$LOGICAL_IF=interface
    uci set mwan4.$LOGICAL_IF.enabled='1'
    uci del mwan4.$LOGICAL_IF.family 2>/dev/null
    uci add_list mwan4.$LOGICAL_IF.family='ipv4'
    uci del mwan4.$LOGICAL_IF.track_ip 2>/dev/null
    uci add_list mwan4.$LOGICAL_IF.track_ip='223.5.5.5'
    uci add_list mwan4.$LOGICAL_IF.track_ip='114.114.114.114'
    uci set mwan4.$LOGICAL_IF.reliability='1'

    uci set mwan4.$MWAN_ROUTE=route
    uci set mwan4.$MWAN_ROUTE.interface="$LOGICAL_IF"
    uci set mwan4.$MWAN_ROUTE.metric='1'
    uci set mwan4.$MWAN_ROUTE.weight='5'

    uci add_list mwan4.balanced.use_route="$MWAN_ROUTE"
done

for intf in $NEW_INTERFACES; do
    uci add_list firewall."$WAN_ZONE".network="$intf"
done

echo "Committing UCI changes..."
uci commit network
uci commit firewall
uci commit mwan4

echo "Reloading services..."
/etc/init.d/network reload
/etc/init.d/firewall reload
/etc/init.d/mwan4 restart

echo "Configuration applied successfully!"
exit 0
