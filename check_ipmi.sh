#!/bin/sh
# License: GPL v2
# Copyright (c) 2007 op5 AB
# Author: Hugo Hallqvist <dev@op5.com>
# Copyright (c) 2010-2012
# Author: Elan Ruusamäe <glen@delfi.ee>
#
# Ported to pure shell by Elan Ruusamäe
# Original PHP version:
# http://git.op5.org/git/?p=nagios/op5plugins.git;a=blob_plain;f=check_ipmi.php;hb=HEAD
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Description:
# Nagios plugin for locally checking hardware status (fans, voltage) via ipmi.
# It utilizes ipmitool to get results from kernel.
#
# Usage: check_ipmi <filename>
#
# filename points to a file which is used as a cache for speeding up the check.

PROGRAM=${0##*/}
PROGPATH=${0%/*}
VERSION=1.15
ARGS="$*"
. $PROGPATH/utils.sh

# ipmitool needs to be with full path for sudo
ipmitool=/usr/bin/ipmitool
sudo=/usr/bin/sudo
modprobe=/sbin/modprobe
outfile=
verbose=false

die() {
	eval local rc=\$STATE_$1
	[ "$rc" ] || rc=$STATE_UNKNOWN
	echo "$2"

	# print also verbose output out
	if $verbose; then
		cat $outfile
		rm -f $outfile
	fi
	exit $rc
}

usage() {
	cat >&2 <<EOF
Usage: check_ipmi <filename>
       check_ipmi -i 'FAN.*' <filename>
       check_ipmi -I nc,lnc <filename>
       check_ipmi -S
       check_ipmi -c

     <filename> indicates the cache file for speeding up sensor readings.

    -c
       Checks if ipmitool can be used on this system
    -S
       Install sudo rules
    -i
       grep extended regexp which sensors to ignore
    -I
       comma separated list of statuses to ignore
    -v
       enable verbose output (prints each sensor which is not ignored)
EOF
}

# trim leading and trailing whitespace
trim() {
	echo "$*" | sed -e 's/^ *\| *$//g'
}

# checks if $status is in comma separated list of $ignore_stats
ignored_status() {
	local status="$1"
	local IFS=","
	for s in $ignore_status; do
		if [ "$status" = "$s" ]; then
			return 0
		fi
	done
	return 1
}

# checks if ipmitool is even usable on this system
check_ipmitool() {
	local status
	echo "IPMI chassis selftest..."
	status=$(LC_ALL=C $ipmitool chassis selftest 2>/dev/null | awk '/Self Test Results/{print $NF}')
	if [ "$status" != "passed" ]; then
		echo "Chassis selftest failed, modprobing"
		$modprobe ipmi_si
		if [ $? != 0 ]; then
			echo "ERROR: ipmi_si module did not load, probably IPMI not present"
			echo "You can setup options to ipmi_si via modprobe.conf"
			exit 1
		fi
		$modprobe ipmi_devintf
		if [ $? != 0 ]; then
			echo "ERROR: ipmi_devintf module did not load"
			exit 1
		fi
	else
		echo "OK: $status"
		return
	fi

	# check again, maybe static dev needs device updating
	status=$(LC_ALL=C $ipmitool chassis selftest 2>/dev/null | awk '/Self Test Results/{print $NF}')
	if [ "$status" != "passed" ]; then
		echo "Still fails, checking ipmi /dev node"
		major=$(awk '$2 == "ipmidev" {print $1}' /proc/devices)
		if [ -z "$major" ]; then
			echo "ERROR: ipmidev module not present or /proc not mounted"
			exit 1
		fi
		dev=/dev/ipmi0
		rm -f $dev
		mknod $dev c $major 0
	fi

	status=$(LC_ALL=C $ipmitool chassis selftest 2>/dev/null | awk '/Self Test Results/{print $NF}')
	if [ "$status" != "passed" ]; then
		echo "ERROR: Can't get it to work, I give up"
		exit 1
	fi
	echo "Seems now it's OK"
}

setup_sudoers() {
	check_ipmitool

	new=/etc/sudoers.$$.new
	umask 0227
	cat /etc/sudoers > $new
	cat >> $new <<-EOF

	# Lines matching CHECK_IPMI added by $0 $ARGS on $(date)
	User_Alias CHECK_IPMI=nagios
	CHECK_IPMI ALL=(root) NOPASSWD: $ipmitool sdr dump $cache_filename
	CHECK_IPMI ALL=(root) NOPASSWD: $ipmitool -S $cache_filename sdr
	EOF

	if visudo -c -f $new; then
		mv -f $new /etc/sudoers
		exit 0
	fi
	rm -f $new
	exit 1
}

create_sdr_cache_file() {
	local filename="$1"

	# return false if cache already exists (i.e, previous check running)
	[ -f "$filename" ] && return 1

	touch "$filename"
	# we run the dump in background
	$sudo $ipmitool sdr dump $filename >/dev/null &
	return 0
}

## Start of main program ##
while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help)
		usage
		exit 0
		;;
	-V|--version)
		echo $PROGRAM $VERSION
		exit 0
		;;
	-v)
		verbose=:
		;;
	-c)
		check_ipmitool=1
		;;
	-i)
		shift
		ignore_sensors="$1"
		;;
	-I)
		shift
		ignore_status="$1"
		;;
	-S)
		setup_sudo=1
		;;
	*)
		cache_filename="$1"
		;;
	esac
	shift
done

if [ "$setup_sudo" = 1 ]; then
	setup_sudoers
fi

if [ "$check_ipmitool" = 1 ]; then
	check_ipmitool
	exit 0
fi

if [ -z "$cache_filename" ]; then
	die UNKNOWN "No databasename given."
fi

if [ ! -s "$cache_filename" ]; then
	if create_sdr_cache_file $cache_filename; then
		die UNKNOWN "New database initialized, no results yet."
	else
		die CRITICAL "Error initializing database."
	fi
fi

t=$(mktemp) || die CRITICAL "Can't create tempfile"
LC_ALL=C $sudo $ipmitool -S $cache_filename sdr > $t || die CRITICAL "Can't run ipmitool sdr"
# VRD 1 Temp       | 34 degrees C      | ok
# CMOS Battery     | 3.12 Volts        | ok
# VCORE            | 0x01              | ok
# Power Supply 1   | 40 Watts          | nc
# Power Supply 2   | 40 Watts          | nc
# Power Supplies   | 0 unspecified     | nc
# Fan 1            | 13.72 unspecifi   | nc
# Fan 2            | 13.72 unspecifi   | nc
# Fan 3            | 29.40 unspecifi   | nc
# Fan 4            | 29.40 unspecifi   | nc
# Fans             | 0 unspecified     | nc

# setup outfile, because we should print verbose after status message
if $verbose; then
	outfile=$(mktemp) || die CRITICAL "Can't create tempfile"
fi

ok_sensors=0
warn_sensors=0
crit_sensors=0
critical=''
warning=''
oIFS=$IFS IFS='|'
while read label result status; do
	# check for ignored sensors
	if trim "$label" | grep -qE "^($ignore_sensors)$"; then
		continue
	fi
	status=$(trim "$status")

	if ignored_status "$status"; then
		continue
	fi

	case "$status" in
	ns)
		# skip ns = Disabled
		continue
		;;
	nc)
		# Non Critical -> warning
		warn_sensors=$((warn_sensors+1))
		label=$(trim "$label")
		result=$(trim "$result")
		warning="$warning($label, $status, $result) "
		;;
	ok)
		# count ok
		ok_sensors=$((ok_sensors+1))
		;;
	*)
		crit_sensors=$((crit_sensors+1))
		label=$(trim "$label")
		result=$(trim "$result")
		critical="$critical($label, $status, $result) "
		;;
	esac
	if $verbose; then
		echo "$label $result $status" >> $outfile
	fi
done < $t
rm -f $t

msg="${critical:+$crit_sensors sensors critical: $critical}"
msg="${msg}${warning:+$warn_sensors sensors warning: $warning}"
if [ $crit_sensors -gt 0 ]; then
	die CRITICAL "$msg"
fi
if [ $warn_sensors -gt 0 ]; then
	die WARNING "$msg"
fi

if [ $ok_sensors -le 0 ]; then
	# 0 sensors found OK is likely error
	die UNKNOWN "No sensors found OK"
fi

die OK "$ok_sensors sensors OK"
