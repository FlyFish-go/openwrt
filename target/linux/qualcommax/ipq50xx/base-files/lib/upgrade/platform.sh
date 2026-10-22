. /lib/functions/bootconfig.sh

PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='dumpimage fw_printenv fw_setenv head seq'
RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock'

fritzbox_remove_oem_ubi_volumes() {
	remove_oem_ubi_volume avm_filesys_0
	remove_oem_ubi_volume avm_filesys_1
	remove_oem_ubi_volume avm_config
	remove_oem_ubi_volume avm_userdata
}

xiaomi_initramfs_prepare() {
	# Wipe UBI if running initramfs
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	local rootfs_mtdnum="$( find_mtd_index rootfs )"
	if [ ! "$rootfs_mtdnum" ]; then
		echo "unable to find mtd partition rootfs"
		return 1
	fi

	local kern_mtdnum="$( find_mtd_index ubi_kernel )"
	if [ ! "$kern_mtdnum" ]; then
		echo "unable to find mtd partition ubi_kernel"
		return 1
	fi

	ubidetach -m "$rootfs_mtdnum"
	ubiformat /dev/mtd$rootfs_mtdnum -y

	ubidetach -m "$kern_mtdnum"
	ubiformat /dev/mtd$kern_mtdnum -y
}

remove_oem_ubi_volume() {
	local oem_volume_name="$1"
	local oem_ubivol
	local mtdnum
	local ubidev

	mtdnum=$(find_mtd_index "$CI_UBIPART")
	if [ ! "$mtdnum" ]; then
		return
	fi

	ubidev=$(nand_find_ubi "$CI_UBIPART")
	if [ ! "$ubidev" ]; then
		ubiattach --mtdn="$mtdnum"
		ubidev=$(nand_find_ubi "$CI_UBIPART")
	fi

	if [ "$ubidev" ]; then
		oem_ubivol=$(nand_find_volume "$ubidev" "$oem_volume_name")
		[ "$oem_ubivol" ] && ubirmvol "/dev/$ubidev" --name="$oem_volume_name"
	fi
}

linksys_bootconfig_set_primaryboot() {
	local partname=$1
	local tempfile
	local mtdidx

	mtdidx=$(find_mtd_index "$partname")
	[ ! "$mtdidx" ] && {
		echo "cannot find mtd index for $partname"
		return 1
	}

	# No need to cleanup as files in /tmp will be removed upon reboot
	tempfile=/tmp/mtd"$mtdidx".bin
	dd if=/dev/mtd"$mtdidx" of="$tempfile" bs=1 count=336 2>/dev/null
	[ $? -ne 0 ] || [ ! -f "$tempfile" ]&& {
		echo "failed to create a temp copy of /dev/mtd$mtdidx"
		return 1
	}

	set_bootconfig_primaryboot "$tempfile" "0:HLOS" $2
	[ $? -ne 0 ] && {
		echo "failed to toggle primaryboot on 0:HLOS part"
		return 1
	}
	
	set_bootconfig_primaryboot "$tempfile" "rootfs" $2
	[ $? -ne 0 ] && {
		echo "failed to toggle primaryboot for rootfs part"
		return 1
	}

	mtd write "$tempfile" /dev/mtd"$mtdidx" 2>/dev/null
	[ $? -ne 0 ] && {
		echo "failed to write temp copy back to /dev/mtd$mtdidx"
		return 1
	}
}

linksys_bootconfig_pre_upgrade() {
	local setenv_script="/tmp/fw_env_upgrade"

	CI_UBIPART="rootfs_1"
	boot_part="$(fw_printenv -n boot_part)"
	if [ -n "$UPGRADE_OPT_USE_CURR_PART" ]; then
		CI_UBIPART="rootfs"
	else
		if [ "$boot_part" -eq "1" ]; then
			echo "boot_part 2" >> $setenv_script
			linksys_bootconfig_set_primaryboot "0:bootconfig" 1
			linksys_bootconfig_set_primaryboot "0:bootconfig1" 1
		else
			echo "boot_part 1" >> $setenv_script
			linksys_bootconfig_set_primaryboot "0:bootconfig" 0
			linksys_bootconfig_set_primaryboot "0:bootconfig1" 0
		fi
	fi

	boot_part_ready="$(fw_printenv -n boot_part_ready)"
	if [ "$boot_part_ready" -ne "3" ]; then
		echo "boot_part_ready 3" >> $setenv_script
	fi

	auto_recovery="$(fw_printenv -n auto_recovery)"
	if [ "$auto_recovery" != "yes" ]; then
		echo "auto_recovery yes" >> $setenv_script
	fi

	if [ -f "$setenv_script" ]; then
		fw_setenv -s $setenv_script || {
			echo "failed to update U-Boot environment"
			return 1
		}
	fi
}

linksys_mx_pre_upgrade() {
	local setenv_script="/tmp/fw_env_upgrade"

	CI_UBIPART="rootfs"
	boot_part="$(fw_printenv -n boot_part)"
	if [ -n "$UPGRADE_OPT_USE_CURR_PART" ]; then
		if [ "$boot_part" -eq "2" ]; then
			CI_KERNPART="alt_kernel"
			CI_UBIPART="alt_rootfs"
		fi
	else
		if [ "$boot_part" -eq "1" ]; then
			echo "boot_part 2" >> $setenv_script
			CI_KERNPART="alt_kernel"
			CI_UBIPART="alt_rootfs"
		else
			echo "boot_part 1" >> $setenv_script
		fi
	fi

	boot_part_ready="$(fw_printenv -n boot_part_ready)"
	if [ "$boot_part_ready" -ne "3" ]; then
		echo "boot_part_ready 3" >> $setenv_script
	fi

	auto_recovery="$(fw_printenv -n auto_recovery)"
	if [ "$auto_recovery" != "yes" ]; then
		echo "auto_recovery yes" >> $setenv_script
	fi

	if [ -f "$setenv_script" ]; then
		fw_setenv -s $setenv_script || {
			echo "failed to update U-Boot environment"
			return 1
		}
	fi
}

h3c_hw_a_dec() { case "$1" in ''|*[!0-9]*) return 1 ;; esac
	local value
	value=$(printf '%s' "$1" | sed 's/^0*//')
	[ -n "$value" ] || value=0
	printf '%s\n' "$value"
}
h3c_hw_a_check_target() { local index dir offset size flags
	index=$(find_mtd_index "$1") || return 1
	dir="/sys/class/mtd/mtd$index"
	[ -r "$dir/offset" ] && [ -r "$dir/size" ] && [ -r "$dir/flags" ] || return 1
	offset=$(cat "$dir/offset") && size=$(cat "$dir/size") && flags=$(cat "$dir/flags") || return 1
	offset=$(h3c_hw_a_dec "$offset") && size=$(h3c_hw_a_dec "$size") || return 1
	[ "$offset" = "$2" ] && [ "$size" = "$3" ] || return 1
	case "$flags:$4" in
		0x400:writable|1024:writable|0x0:readonly|0:readonly) return 0 ;;
		*) return 1 ;;
	esac
}
h3c_hw_a_platform_check_image() {
	[ "$(board_name)" = 'h3c,rw3000-hw-a' ] || return 1
	nand_do_platform_check 'h3c,rw3000-hw-a' "$1" || return 1
	h3c_hw_a_check_target rootfs 9437184 41943040 writable && h3c_hw_a_check_target oem-recovery 51380224 41943040 readonly
}
h3c_hw_a_cmdline_exact() { local key=$1 expected=$2 arg value count=0
	for arg in $(cat /proc/cmdline); do case "$arg" in "$key"=*) value=${arg#*=}; count=$((count + 1)) ;; esac; done
	[ "$value" = "$expected" ] && { [ "$key" = root ] || [ "$count" -eq 1 ]; }
}
h3c_hw_a_platform_do_upgrade() { local index ubi
	h3c_hw_a_platform_check_image "$1" || return 1
	index=$(find_mtd_index rootfs) && ubi=$(nand_find_ubi rootfs) || return 1
	[ -n "$ubi" ] && [ "${ubi##*/}" = ubi0 ] && [ "$(cat "/sys/class/ubi/${ubi##*/}/mtd_num")" = "$index" ] && [ "$(cat "/sys/class/ubi/${ubi##*/}_1/name")" = rootfs ] || return 1
	h3c_hw_a_cmdline_exact ubi.mtd rootfs && h3c_hw_a_cmdline_exact root /dev/ubiblock0_1 || return 1
	[ -z "$(find_mtd_index kernel 2>/dev/null)" ] || return 1
	CI_UBIPART=rootfs; CI_KERN_UBIPART=rootfs; CI_ROOT_UBIPART=rootfs; CI_DATA_UBIPART=rootfs
	CI_KERNPART=kernel; CI_ROOTPART=rootfs; CI_SKIP_KERNEL_MTD=1
	nand_do_upgrade "$1"
}


platform_check_image() {
	case "$(board_name)" in
	h3c,rw3000-hw-a)
		h3c_hw_a_platform_check_image "$1"
		;;
	*)
		return 0
		;;
	esac
}

platform_pre_upgrade() {
	case "$(board_name)" in
	avm,fritzbox-4050)
		fritzbox_remove_oem_ubi_volumes
		;;
	xiaomi,ax6000)
		xiaomi_initramfs_prepare
		;;
	esac
}

platform_do_upgrade() {
	case "$(board_name)" in
	h3c,rw3000-hw-a)
		h3c_hw_a_platform_do_upgrade "$1"
		;;
	avm,fritzbox-4050)
		sync
		CI_KERNPART="fit0"
		nand_do_flash_file "$1" || nand_do_upgrade_failed
		CI_KERNPART="fit1"
		nand_do_flash_file "$1" || nand_do_upgrade_failed
		nand_do_upgrade_success
		;;
	cmcc,mr3000d-ci|\
	cmcc,pz-l8|\
	cmcc,rax3000q|\
	elecom,wrc-x3000gs2|\
	elecom,wrc-x3000gst2|\
	iodata,wn-dax3000gr)
		local delay

		delay=$(fw_printenv bootdelay)
		[ -z "$delay" ] || [ "$delay" -eq "0" ] && \
			fw_setenv bootdelay 3

		elecom_upgrade_prepare

		remove_oem_ubi_volume bt_fw
		remove_oem_ubi_volume ubi_rootfs
		remove_oem_ubi_volume wifi_fw
		nand_do_upgrade "$1"
		;;
	glinet,gl-b3000)
		glinet_do_upgrade "$1"
		;;
	glinet,gl-x2000)
		# The stock UBI fills the whole partition (0 free LEBs) with its
		# own wifi_fw and ubi_rootfs volumes, leaving no room for the
		# OpenWrt rootfs. Drop them before upgrading.
		CI_UBIPART="rootfs"
		remove_oem_ubi_volume ubi_rootfs
		remove_oem_ubi_volume wifi_fw
		glinet_do_upgrade "$1"
		;;
	linksys,mr2000|\
	linksys,mr5500|\
	linksys,mx2000|\
	linksys,mx5500|\
	linksys,spnmx56)
		linksys_mx_pre_upgrade "$1"
		remove_oem_ubi_volume squashfs
		nand_do_upgrade "$1"
		;;
	linksys,mx6200)
		linksys_bootconfig_pre_upgrade "$1"
		remove_oem_ubi_volume ubi_rootfs
		nand_do_upgrade "$1"
		;;
	mercusys,mr80x-v2)
		# A/B: write the inactive slot, then point tp_boot_idx at it.
		# tp_boot_idx=0 boots "rootfs", 1 boots "rootfs_1". primaryboot
		# must stay 0, the stock loader and the button recovery pick the
		# slot by name from tp_boot_idx alone. tp_boot_idx only changes
		# once the new slot is fully written.
		local tp active target newtp primaryboot bcidx bcfile

		# Warn only, flipping primaryboot here would desync the running
		# and the next-boot slot names.
		bcidx=$(find_mtd_index "0:bootconfig")
		if [ -n "$bcidx" ]; then
			bcfile=/tmp/mtd"$bcidx".bin
			dd if=/dev/mtd"$bcidx" of="$bcfile" bs=1 count=336 2>/dev/null
			primaryboot=$(get_bootconfig_primaryboot "$bcfile" "rootfs")
			[ "$primaryboot" = "0" ] || \
				echo "WARNING: primaryboot=$primaryboot (expected 0); slot selection may be inverted"
		fi

		tp=$(fw_printenv -n tp_boot_idx 2>/dev/null)
		case "$tp" in
			1) active="rootfs_1"; target="rootfs";   newtp=0 ;;
			*) active="rootfs";   target="rootfs_1"; newtp=1 ;;
		esac

		if [ -n "$UPGRADE_OPT_USE_CURR_PART" ]; then
			CI_UBIPART="$active"
		else
			CI_UBIPART="$target"
		fi

		remove_oem_ubi_volume ubi_rootfs
		remove_oem_ubi_volume wifi_fw
		remove_oem_ubi_volume bt_fw
		sync
		nand_do_flash_file "$1" || nand_do_upgrade_failed
		if [ -z "$UPGRADE_OPT_USE_CURR_PART" ]; then
			fw_setenv tp_boot_idx "$newtp" || {
				echo "failed to set tp_boot_idx"
				nand_do_upgrade_failed
			}
		fi
		nand_do_upgrade_success
		;;
	tplink,archer-ax55-v1|\
	tplink,eap650-outdoor-v1|\
	tplink,re700x)
		# Dual boot: install into the inactive rootfs/rootfs_1 slot,
		# then point tp_boot_idx at it. The running slot is left
		# untouched as a fallback - if the new image fails to load,
		# TP-Link's U-Boot boots the other slot on its own (only on
		# load failure though: there is no boot counter, a kernel
		# that boots and then crashes is not detected).
		local idx=1
		CI_UBIPART="rootfs_1"
		if grep -q 'ubi.mtd=rootfs_1' /proc/cmdline; then
			idx=0
			CI_UBIPART="rootfs"
		fi
		fw_setenv tp_boot_idx $idx || {
			echo "failed to set tp_boot_idx $idx"
			return 1
		}
		# a slot last written by TP-Link firmware carries extra
		# volumes that would leave no room for ours
		remove_oem_ubi_volume ubi_rootfs
		remove_oem_ubi_volume tp_data
		nand_do_upgrade "$1"
		;;
	wallys,dr5018s)
		CI_UBIPART="rootfs"
		remove_oem_ubi_volume debug
		remove_oem_ubi_volume ubi_rootfs
		remove_oem_ubi_volume bt_fw
		remove_oem_ubi_volume wifi_fw
		nand_do_upgrade "$1"
		;;
	xiaomi,ax6000|\
	xiaomi,redmi-ax5400)
		# Make sure that UART is enabled
		fw_setenv boot_wait on
		fw_setenv uart_en 1

		# Enforce single partition.
		fw_setenv flag_boot_rootfs 0
		fw_setenv flag_last_success 0
		fw_setenv flag_boot_success 1
		fw_setenv flag_try_sys1_failed 8
		fw_setenv flag_try_sys2_failed 8

		# Kernel and rootfs are placed in 2 different UBI
		CI_KERN_UBIPART="ubi_kernel"
		CI_ROOT_UBIPART="rootfs"
		CI_DATA_UBIPART="rootfs"
		nand_do_upgrade "$1"
		;;
	xunison,exigo-hub-d50-5g|\
	yuncore,ax830|\
	yuncore,ax850|\
	zyxel,scr50axe)
		CI_UBIPART="rootfs"
		remove_oem_ubi_volume ubi_rootfs
		remove_oem_ubi_volume bt_fw
		remove_oem_ubi_volume wifi_fw
		nand_do_upgrade "$1"
		;;
	zte,t5400)
		CI_UBIPART="rootfs"
		nand_do_upgrade "$1"
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}
