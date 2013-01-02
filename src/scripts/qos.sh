#! /bin/bash
#
### BEGIN INIT INFO
# Provides: qos
# Required-Start: $network
# Should-Start:
# Required-Stop: $network
# Should-Stop:
# Default-Start:  3 5
# Default-Stop:   0 1 2 6
# Short-Description: QoS configuration
# Description: Configures the kernel for routing traffic prioritization
### END INIT INFO

#
# This script sets up QoS prioritization using HTB (Hierarchical Token Bucket).
# Assumptions:
#
#   o Nothing else uses queueing disciplines on the $QOS_DEV_IFB and $QOS_DEV_EXT interfaces
#
# References:
#   http://www.lartc.org
#   http://tldp.org/HOWTO/ADSL-Bandwidth-Management-HOWTO/
#

# Constants
QOSCONFIG='@qosconfig@'
IP='@iputil@'
TC='@tcutil@'
MODPROBE='@modprobe@'

. /etc/rc.status
rc_reset

# Slurp in configuration
test -r "$QOSCONFIG" || exit 5
. "$QOSCONFIG"
test -n "$QOS_DEV_EXT" || exit 5

# Run a command
do_cmd()
{
    local doer=''
    if [ "${DRY_RUN}" = '1' ]; then
        doer='echo'
        if [ "$1" = '-quiet' ]; then
            shift
        fi
    fi
    if [ "$1" = '-ignore-error' ]; then
        shift
        $doer ${1+"$@"} 2>/dev/null || true
    elif [ "$1" = '-quiet' ]; then
        shift
        $doer ${1+"$@"} >/dev/null
    else
        $doer ${1+"$@"}
    fi
}

# Remove QoS settings
clear_qos()
{
    do_cmd -ignore-error $TC qdisc del dev "$QOS_DEV_EXT" ingress
    do_cmd -ignore-error $TC qdisc del dev "$QOS_DEV_EXT" root
    do_cmd -ignore-error $TC qdisc del dev "$QOS_DEV_IFB" root
}

# Check devices really exist
check_devices()
{

    # Check uplink interface
    if ! [ -e /sys/class/net/"$QOS_DEV_EXT" ]; then
        echo -n "$QOS_DEV_EXT not found"
        return 1
    fi

    # Check ifb interface, loading module if necessary
    if ! [ -e /sys/class/net/"$QOS_DEV_IFB" ]; then
        $MODPROBE ifb
        RESULT=$?
        if [ $RESULT -ne 0 ]; then
            echo -n "can't load module ifb"
            return 1
        fi
        if ! [ -e /sys/class/net/"$QOS_DEV_IFB" ]; then
            echo -n "$QOS_DEV_IFB not found"
            return 1
        fi
    fi
}

# Add a tc filter
add_filter()
{
    local dev="$1"
    local parent="$2"
    local flow="$3"
    shift
    shift
    shift
    do_cmd $TC filter add dev $dev parent $parent protocol ip prio 10 u32 ${1+"$@"} flowid $flow
}

#
# Set up tc filters to classify high priority packets into the 1:10 class.
#
add_filters()
{
    # Get params
    local dev="$1"
    local parent="$2"
    local flow="1:10"

    # Small TCP packets (typically ACKs)
    if [ "$QOS_TCP_ACK" = "yes" ]; then
        add_filter $dev $parent $flow       \
          match ip protocol 6 0xff          \
          match u16 0x0000 0xffc0 at 2      \
          match u8 0x10 0x10 at nexthdr+13
    fi

    # SSH interactive traffic
    if [ "$QOS_SSH_INTERACTIVE" = "yes" ]; then
        for OFFSET in 0 2; do
            add_filter $dev $parent $flow       \
              match ip tos 0x10 0x1c            \
              match ip protocol 6 0xff        \
              match u16 22 0xffff at nexthdr+$OFFSET
        done
    fi

    # DNS traffic
    if [ "$QOS_DNS" = "yes" ]; then
        for PROTO in 6 17; do
            for OFFSET in 0 2; do
                add_filter $dev $parent $flow       \
                  match ip protocol $PROTO 0xff     \
                  match u16 53 0xffff at nexthdr+$OFFSET
            done
        done
    fi

    # User-specified filters
    echo $QOS_HIGH_PRIORITY | tr ',' '\n' | while IFS="," read MATCH; do
        if [ -n "$MATCH" ]; then
            add_filter $dev $parent $flow $MATCH
        fi
    done
}

# Set up QoS
set_qos()
{
    # Bring up ifb0
    do_cmd $IP link set "$QOS_DEV_IFB" up

    # Add ingress queueing discipline root
    do_cmd $TC qdisc add dev "$QOS_DEV_EXT" ingress

    # Configure outgoing traffic
    set_qos_dev "$QOS_DEV_EXT" "$QOS_BANDWIDTH_UP_TOTAL" "$QOS_BANDWIDTH_UP_HIGHPRIO"

    # Configure incoming traffic
    set_qos_dev "$QOS_DEV_IFB" "$QOS_BANDWIDTH_DOWN_TOTAL" "$QOS_BANDWIDTH_DOWN_HIGHPRIO"

    # Redirect all packets coming into the uplink to the ifb interface
    do_cmd -quiet $TC filter add dev "$QOS_DEV_EXT" parent ffff: protocol ip prio 10 u32 \
      match u32 0 0 flowid 1:1 action mirred egress redirect dev "$QOS_DEV_IFB"
}


# Add queue disciplines, classes, and filters for one interface
set_qos_dev()
{
    # Get params
    local dev="$1"
    local total_bw="$2"
    local hiprio_bw="$3"

    # Define handles
    local hiflow="1:10"
    local loflow="1:20"

    # Adjust total bandwidth to 98% of actual bandwidth
    total_bw=$(( $total_bw * 98 / 100 ))

    # Remainder is the low priority bandwidth
    local loprio_bw=$(( $total_bw - $hiprio_bw ))

    # Sanity check
    if [ "$total_bw" -le 0 -o "$hiprio_bw" -le 0 -o "$loprio_bw" -le 0 \
      -o "$hiprio_bw" -ge "$total_bw" -o "$loprio_bw" -ge "$total_bw" ]; then
        echo "qos: illegal bandwidth settings on $dev" 1>&2
        return 1
    fi

    ##
    ## Set up HTB classes
    ##

    # Add the queueing discipline
    do_cmd $TC qdisc add dev $dev root handle 1:0 htb default 20

    # Add the root class
    do_cmd $TC class add dev $dev parent 1:0 classid 1:1 htb \
        rate ${total_bw}kbit ceil ${total_bw}kbit

    # Add class for high priority packets
    do_cmd $TC class add dev $dev parent 1:1 classid $hiflow htb \
        rate ${hiprio_bw}kbit ceil ${total_bw}kbit prio 0 quantum 3000

    # Add class for low priority packets
    do_cmd $TC class add dev $dev parent 1:1 classid $loflow htb \
        rate ${loprio_bw}kbit ceil ${total_bw}kbit prio 1 quantum 3000

    ##
    ## Set up filters to classify packets into the above classes
    ##

    add_filters $dev 1:0 $hiflow
}

# Watch QOS filter or class activity
watch_qos()
{
    # Whether to watch filter or class
    case "$2" in
        -f)
            watch -n 0.2 tc -p -s -d filter show dev "$QOS_DEV_IFB"
            ;;
        -c|*)
            watch -n 0.2 tc -s class show dev "$QOS_DEV_IFB"
            ;;
    esac
}

# Main entry
case "$1" in
    start)
        echo -n "Starting QoS "
        if ! check_devices; then
            rc_status -u
        else
            clear_qos
            set_qos
            rc_status -v
        fi
        ;;
    stop)
        echo -n "Stopping QoS "
        clear_qos || true
        rc_status -v
        ;;
    reload)
        $0 stop
        $0 start
        ;;
    restart)
        $0 stop
        $0 start
        ;;
    show)
        DRY_RUN="1"
        clear_qos
        set_qos
        ;;
    watch)
        watch_qos ${1+"$@"}
        ;;
    *)
        echo "Usage: $0 {start|stop|show|watch|restart}"
        exit 1
        ;;
esac

# Set exit status
rc_exit

# vim: sw=4
