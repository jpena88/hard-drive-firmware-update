#!/bin/bash

# Copyright (c) 2012 John Peña <jsp3na@gmail.com> and contributors

echo_usage() {
	echo -e "Usage: update_drive_fw.sh [options] model firmware filename"
	echo -e "-hdp|--hdparm <hdparm filename>    Use specific hdparm version"
	echo -e "-r|--resize <LBA count>            Resize SSD"
	echo -e "-l|--list <list filename>          Use list to lookup drive info"
	echo -e "-x|--regexp                        Use regexp for model check"
	echo -e "-h|--help                          prints help"
	echo -e "Note: This script only does one device model at a time, if more is needed, please run script again with different device model."
	echo -e "Also, if a file called 'stopthisstupidprocess' exist in working directory, it will stop the next possible drive update"
	echo ""
}

check_status() {
	[ $# -lt 1 ] && { $ERRCODE=$?; }
	ERRCODE=$1
	shift
	if [ $ERRCODE != 0 ]; then
		echo -e $RD"ERROR!$RS Exit Code: [ $ERRCODE ]"
		exit $ERRCODE
	fi
}

update_fw() {
	drivetool=$1
	case $drivetool in
	seagate)
		tool='seagate'
		;;
	*)
		tool='default'
		;;
	esac
	if [ -e $fwfile ]; then
		if [ "$tool" == 'seagate' ]; then
			$seagatetool -f $fwfile -d $x -s 64
			returnCode=$?
			check_status $returnCode
		else
			$hdparm --fwdownload $fwfile --yes-i-know-what-i-am-doing --please-destroy-my-drive $x
			returnCode=$?
			check_status $returnCode
		fi
	else
		echo -e ${RD}"\nERROR! ${fwfile} does not exist.\n"${RS}
		exit 1
	fi
}

resize_ssd() {
	$hdparm --yes-i-know-what-i-am-doing -N p$size $x
	returnCode=$?
	check_status $returnCode
}

parse_list() {
	if [ ! -e $hdd_list ]; then
		echo -e ${RD}"\nCan't Find the Following List: $hdd_list"${RS}
	else
		dos2unix $hdd_list >/dev/null 2>&1
		returnCode=$?
		check_status $returnCode
		sscode_list=$(awk -F "," '/SS/{print $1}' $hdd_list)
		for i in $sscode_list; do
			if [ "$i" == "$sscode" ]; then
				model=$(awk -F "," '/'$i'/{print $2}' $hdd_list)
				fw=$(awk -F "," '/'$i'/{print $3}' $hdd_list)
				fwfile=$(awk -F "," '/'$i'/{print $4}' $hdd_list)
			fi
		done
		if [ -z "$model" ]; then
			echo -e ${RD}"\nThis Model is Not On This List.\n"${RS}
			exit 1
		elif [ ! -e "$fwfile" ]; then
			echo -e ${RD}"\nCan't Find FW Binary: $fwfile\n"${RS}
			exit 1
		fi
	fi
}

set_variables() {
	if [ "$pdType" == 'SAS' ]; then
		raidParam='megaraid'
		ymodel=$(smartctl -a -d $raidParam,$i /dev/sdb | awk '/Product/{print $NF}')
		yfw=$(smartctl -a -d $raidParam,$i /dev/sdb | awk '/Revision/{gsub(/[\.\-_]/,"",$NF);print $NF}')
	elif [ "$pdType" == 'SATA' ]; then
		raidParam='sat+megaraid'
		ymodel=$(smartctl -a -d $raidParam,$i /dev/sdb | awk '/Device Model/{print $NF}')
		yfw=$(smartctl -a -d $raidParam,$i /dev/sdb | awk '/Firmware Version/{gsub(/[\.\-_]/,"",$NF);print $NF}')
	else
		echo -e ${RD}"Unknown RAID type, please check system."${RS}
		exit 1
	fi
}

stop_this_stupid_process() {
	if [ -e ./stopthisstupidprocess ]; then
		echo -e "${RD}STOP${RS} ${BL}THIS${RS} ${GN}STUPID${RS} ${PL}PROCESS${RS}"
		exit 123
	fi
}

update_lsi_drives() {
	echo -e "***************************************"
	echo -e "**** Checking LSI Raid Card Drives ****"
	echo -e "***************************************\n"
	sleep 1
}

if [ -a pdlist.txt ]; then
	rm pdlist.txt
fi

MegaCli64 pdlist -aALL >pdlist.txt

encID=$(awk '/Enclosure Device ID/{print $NF}' pdlist.txt | sed -n 1p)
deviceID=$(awk '/Device Id/{print $NF}' pdlist.txt)
slotID=$(awk '/Slot Number/{print $NF;exit;}' pdlist.txt)
pdType=$(awk '/PD Type/{print $NF;exit;}' pdlist.txt)

for i in $deviceID; do
	correctDrive='no'
	echo -e ${YL}"[ Checking Raid Card Device ID: $i ]"${RS}
	cleanfw=$(echo $fw | awk '{gsub(/[\.\-_]/,"");print}')
	set_variables
	echo -e "Current Model: ${PB}${ymodel}${RS}"
	echo -e "Current Firmware: ${PB}${yfw}${RS}"
	if [ ${regexp} == 'yes' ]; then
		if [ ! -z ${model} ] && [[ "${ymodel}" =~ ${model} ]]; then
			correctDrive='yes'
		fi
	else
		if [ "${ymodel}" == ${model} ]; then
			correctDrive='yes'
		fi
	fi
	if [ "${correctDrive}" == 'yes' ]; then
		if [ "$yfw" != "$cleanfw" ]; then
			echo "Flashing Device $i, Slot $slotID FW to $fw..."
			sleep 10
			MegaCli64 -PdFwDownload -PhysDrv["$encID":"$slotID"] -f $fwfile -a0
			returnCode=$?
			check_status $returnCode
			echo "Update complete. Sleeping for 30 seconds..."
			sleep 30
		else
			echo -e "Firmware is Correct...\n"
		fi
	else
		echo -e "Not The Target Drive...\n"
	fi
	((slotID++))
done

update_pmc_drives() {
	echo -e "***************************************"
	echo -e "**** Checking PMC Raid Card Drives ****"
	echo -e "***************************************\n"
	sleep 1

	hd_array=()
	fw_array=()
	channel_array=()
	id_array=()
	controller_array=()
	controller_count=$(arcconf getversion | grep "Controller #" | wc -l)

	echo -e "Collecting Controller Info..."

	if [ -e 'pmc_config.txt' ]; then
		rm -f pmc_config.txt
	fi

	if [ -e 'controller_num.txt' ]; then
		rm -f controller_num.txt
	fi

	echo -e "\nNumber of Controllers: $controller_count"
	for i in $(seq 1 $controller_count); do
		arcconf getconfig $i >>pmc_config.txt
		hd_count=$(arcconf getconfig $i | grep Channel,Device | wc -l)
		for x in $(seq 1 $hd_count); do
			echo $i >>controller_num.txt
		done
	done

	drive_type=$(awk '/Transfer Speed/ {print $4;exit}' pmc_config.txt)
	hd=$(awk '/Model/ && !/Controller/ {print $NF}' pmc_config.txt)
	fw=$(awk '/Firmware/ && !/[.]/ {print $NF}' pmc_config.txt)
	channel=$(awk '/Reported Channel/{print $NF}' pmc_config.txt | awk -F '[(,]' '{print $1}')
	id=$(awk '/Reported Channel/{print $NF}' pmc_config.txt | awk -F '[(,]' '{print $2}')

	if [ "$drive_type" == 'SAS' ]; then
		mode=7
	elif [ "$drive_type" == 'SATA' ]; then
		mode=3
	else
		echo "Epic Fail! Unknown Drive Type. Please Contact QC Engineering."
		exit 1
	fi

	for i in $hd; do
		hd_array+=("$i")
	done

	for i in $fw; do
		fw_array+=("$i")
	done

	for i in $channel; do
		channel_array+=("$i")
	done

	for i in $id; do
		id_array+=("$i")
	done

	for i in $(cat controller_num.txt); do
		controller_array+=("$i")
	done

	count='0'
	for i in "${hd_array[@]}"; do
		if [ "$i" == "$model" ]; then
			echo -e "\nFound $model, Checking Firmware..."
			if [ ${fw_array[$count]} == "$fw" ]; then
				echo -e ${GR}"Controller: ${controller_array[$count]} Channel: ${channel_array[$count]} ID: ${id_array[$count]} Current FW: [$fw] is already correct..."${RS}
			else
				echo -e ${RD}"Current FW: [${fw_array[$count]}] is incorrect,  Flashing to [$fw]..."${RS}
				echo -e ${GR}"Executing: arcconf imageupdate ${controller_array[$count]} device ${channel_array[$count]} ${id_array[$count]} 16384 $fwfile $mode noprompt"${RS}
				arcconf imageupdate ${controller_array[$count]} device ${channel_array[$count]} ${id_array[$count]} 16384 $fwfile $mode noprompt
				sleep 10
				check_exit
			fi
		fi
		((count++))
	done
}

update_onboard_drives() {
	echo -e "***********************************"
	echo -e "***** Checking Onboard Drives *****"
	echo -e "***********************************\n"
	sleep 1

	for x in /dev/sd*[a-z]; do
		stop_this_stupid_process
		correctDrive='no'
		echo -e ${YL}"[ Checking $x ]"${RS}
		xmodel=$(smartctl -i $x | awk '/Device Model|Product/{print$NF}')
		xfw=$(smartctl -i $x | awk '/Firmware Version|Revision/{print$NF}')
		echo -e "Current Model: ${PB}$xmodel${RS}"
		echo -e "Current Firmware: ${PB}$xfw${RS}"
		if [ "${regexp}" == 'yes' ]; then
			if [[ "${xmodel}" =~ [Mm]icron ]]; then
				correctDrive='micron'
			elif [[ "${xmodel}" =~ ${model} ]] && [[ "${xmodel}" =~ ^ST ]]; then
				correctDrive='seagate'
			elif [ ! -z ${model} ] && [[ "${xmodel}" =~ ${model} ]]; then
				correctDrive='default'
			fi
		else
			if [[ "${xmodel}" =~ [Mm]icron ]]; then
				correctDrive='micron'
			elif [ "${xmodel}" == ${model} ] && [[ "${xmodel}" =~ ^ST ]]; then
				correctDrive='seagate'
			elif [ "${xmodel}" == ${model} ]; then
				correctDrive='default'
			fi
		fi
		if [ "${correctDrive}" == 'micron' ]; then
			echo "Micron drive found. Executing Micron Update Script..."
			sleep 1
			./update_micron_ssd.sh $model $fw $fwfile
			returnCode=$?
			check_status $returnCode
			echo "Finish Updating Micron Drives, sleeping for 5 seconds..."
			sleep 5
		elif [ "${correctDrive}" == 'seagate' ]; then
			echo "Seagate drive found. Updating with Seagate tool"
			if [ "${xfw}" != "${fw}" ]; then
				echo -e "Drive ${x} FW ${xfw} -> ${RD}[ Incorrect ]${RS}\n"
				echo "Preparing to flash FW..."
				update_fw seagate
			else
				echo -e "Drive ${x} FW ${xfw} -> ${GR}[ Correct ]${RS}"
			fi

		elif [ "${correctDrive}" == 'default' ]; then
			if [ "${xfw}" != "${fw}" ]; then
				echo -e "Drive ${x} FW ${xfw} -> ${RD}[ Incorrect ]${RS}\n"
				echo "Preparing to flash FW..."
				update_fw
			else
				echo -e "Drive ${x} FW ${xfw} -> ${GR}[ Correct ]${RS}"
			fi
			if [ "$resize" -eq 1 ]; then
				echo "Will resize SSD in 5 seconds..."
				sleep 3
				resize_ssd
			fi
		else
			echo "Not The Target Drive..."
		fi
		echo ""
	done
}

######################
# MAIN
######################

# Colors
RD='\E[31m'
GR='\E[32m'
YL='\E[33m'
BL='\E[34m'
PB='\E[35m'
RS='\E[0m'

# Defaults
ERRCODE=0
resize=0
list_exists=0
hdparm='hdparm'
seagatetool='./dl_sea_fw'
sscode=$(dmidecode -t 1 | awk '/SKU Number/{print $NF}')

if [ $# -lt 1 ]; then
	echo -e ${RD}"\nEpic Fail! Please enter a valid parameter.\n"${RS}
	echo_usage
	exit 1
else
	while [ $# -gt 0 ]; do
		case "$1" in
		-l | -list | --list)
			if [ $2 ]; then
				hdd_list=$2
				shift 2
				parse_list
			else
				echo -e $RD"ERROR! -list flag needs a list.$RS\n"
				echo_usage
				exit 1
			fi
			;;
		-r | -resize | --resize)
			resize=1
			if [ $2 ]; then
				size=$2
				shift 2
			else
				echo -e $RD"ERROR! -resize flag needs an LBA count.$RS\n"
				echo_usage
				exit 1
			fi
			;;
		-h | -hdparm | --hdparm)
			if [ $2 ]; then
				if [ -e $2 ]; then
					hdparm=$2
					shift 2
				else
					echo -e $RD"ERROR! Can not find hdparm version $2.$RS\n"
					exit 1
				fi
			else
				echo -e $RD"ERROR! -hdparm flag needs an filename.$RS\n"
				echo_usage
				exit 1
			fi
			;;
		-x | -regexp | --regexp)
			regexp='yes'
			shift 1
			;;
		*)
			if [ -n $1 -a -n $2 -a -n $3 ]; then
				model=$1
				fw=$2
				fwfile=$3
				shift 3
			else
				echo -e $RD"ERROR! Please provide drive model, firmware, and binary file.$RS"
				echo_usage
				exit 1
			fi
			;;
		esac
	done
fi

echo ""
echo -e 'Requested Model:' ${YL}${model}${RS}
echo -e 'Requested Firmware:' ${YL}${fw}${RS}
echo -e 'Requested Binary:' ${YL}${fwfile}${RS}
echo ""

if [ ! -e $fwfile ]; then
	echo -e "Firmware file '${fwfile}' can not be found!"
	exit 55
fi

# Update onboard drives
update_onboard_drives

# Update LSI MegaRAID drives
lspci | grep -i "MegaRAID" >/dev/null
if [ $? == 0 ]; then
	update_lsi_drives
fi

# Update PMC drives
if [ $(arcconf getversion | awk '{print $NF;exit}') -gt '0' ]; then
	update_pmc_drives
fi

exit 0
