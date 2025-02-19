#!/bin/bash

# Set a fixed value
check_option="${1}"
download_version="${2}"
TMP_CHECK_DIR="/tmp/amlogic"
AMLOGIC_SOC_FILE="/etc/flippy-openwrt-release"
START_LOG="${TMP_CHECK_DIR}/amlogic_check_firmware.log"
LOG_FILE="${TMP_CHECK_DIR}/amlogic.log"
github_api_openwrt="${TMP_CHECK_DIR}/github_api_openwrt"
LOGTIME=$(date "+%Y-%m-%d %H:%M:%S")
[[ -d ${TMP_CHECK_DIR} ]] || mkdir -p ${TMP_CHECK_DIR}

# Find the partition where root is located
ROOT_PTNAME=$(df / | tail -n1 | awk '{print $1}' | awk -F '/' '{print $3}')
if [ "${ROOT_PTNAME}" == "" ]; then
    echo "Cannot find the partition corresponding to the root file system!"
    exit 1
fi

# Find the disk where the partition is located, only supports mmcblk?p? sd?? hd?? vd?? and other formats
case ${ROOT_PTNAME} in
mmcblk?p[1-4])
    EMMC_NAME=$(echo ${ROOT_PTNAME} | awk '{print substr($1, 1, length($1)-2)}')
    PARTITION_NAME="p"
    LB_PRE="EMMC_"
    ;;
[hsv]d[a-z][1-4])
    EMMC_NAME=$(echo ${ROOT_PTNAME} | awk '{print substr($1, 1, length($1)-1)}')
    PARTITION_NAME=""
    LB_PRE=""
    ;;
*)
    echo "Unable to recognize the disk type of ${ROOT_PTNAME}!"
    exit 1
    ;;
esac

# Set the default download path
FIRMWARE_DOWNLOAD_PATH="/mnt/${EMMC_NAME}${PARTITION_NAME}4"

# Log function
tolog() {
    echo -e "${1}" >$START_LOG
    echo -e "${LOGTIME} ${1}" >>$LOG_FILE
    [[ -z "${2}" ]] || exit 1
}

# Current device model
MYDEVICE_NAME=$(cat /proc/device-tree/model | tr -d '\000')
if [[ -z "${MYDEVICE_NAME}" ]]; then
    tolog "The device name is empty and cannot be recognized." "1"
elif [[ "$(echo ${MYDEVICE_NAME} | grep "Chainedbox L1 Pro")" != "" ]]; then
    MYDTB_FILE="rockchip"
    SOC="l1pro"
elif [[ "$(echo ${MYDEVICE_NAME} | grep "BeikeYun")" != "" ]]; then
    MYDTB_FILE="rockchip"
    SOC="beikeyun"
elif [[ "$(echo ${MYDEVICE_NAME} | grep "V-Plus Cloud")" != "" ]]; then
    MYDTB_FILE="allwinner"
    SOC="vplus"
elif [[ -f "${AMLOGIC_SOC_FILE}" ]]; then
    MYDTB_FILE="amlogic"
    source ${AMLOGIC_SOC_FILE} 2>/dev/null
    SOC="${SOC}"
else
    tolog "Unknown device: [ ${MYDEVICE_NAME} ], Not supported." "1"
fi
[[ ! -z "${SOC}" ]] || tolog "The custom firmware soc is invalid." "1"
tolog "Device: ${MYDEVICE_NAME} [ ${SOC} ], Use in [ ${EMMC_NAME} ]"
sleep 2

# 01. Query local version information
tolog "01. Query version information."
# 01.01 Query the current version
current_kernel_v=$(ls /lib/modules/ 2>/dev/null | grep -oE '^[1-9].[0-9]{1,3}.[0-9]+')
tolog "01.01 current version: ${current_kernel_v}"
sleep 2

# 01.01 Version comparison
main_line_ver=$(echo "${current_kernel_v}" | cut -d '.' -f1)
main_line_maj=$(echo "${current_kernel_v}" | cut -d '.' -f2)
main_line_version="${main_line_ver}.${main_line_maj}"

# 01.02. Query the selected branch in the settings
server_kernel_branch=$(uci get amlogic.config.amlogic_kernel_branch 2>/dev/null | grep -oE '^[1-9].[0-9]{1,3}')
if [ -z "${server_kernel_branch}" ]; then
    server_kernel_branch="${main_line_version}"
    uci set amlogic.config.amlogic_kernel_branch="${main_line_version}" 2>/dev/null
    uci commit amlogic 2>/dev/null
fi
if [[ "${server_kernel_branch}" != "${main_line_version}" ]]; then
    main_line_version="${server_kernel_branch}"
    tolog "01.02 Select branch: ${main_line_version}"
    sleep 2
fi

# 01.03. Download server version documentation
server_firmware_url=$(uci get amlogic.config.amlogic_firmware_repo 2>/dev/null)
[[ ! -z "${server_firmware_url}" ]] || tolog "01.03 The custom firmware download repo is invalid." "1"
releases_tag_keywords=$(uci get amlogic.config.amlogic_firmware_tag 2>/dev/null)
[[ ! -z "${releases_tag_keywords}" ]] || tolog "01.04 The custom firmware tag keywords is invalid." "1"
firmware_suffix=$(uci get amlogic.config.amlogic_firmware_suffix 2>/dev/null)
[[ ! -z "${firmware_suffix}" ]] || tolog "01.05 The custom firmware suffix is invalid." "1"

# Supported format:
# server_firmware_url="https://github.com/ophub/amlogic-s9xxx-openwrt"
# server_firmware_url="ophub/amlogic-s9xxx-openwrt"
if [[ ${server_firmware_url} == http* ]]; then
    server_firmware_url=${server_firmware_url#*com\/}
fi

# Delete other residual firmware files
rm -f ${FIRMWARE_DOWNLOAD_PATH}/*${firmware_suffix} 2>/dev/null && sync
rm -f ${FIRMWARE_DOWNLOAD_PATH}/*.img 2>/dev/null && sync

firmware_download_url="https:.*${releases_tag_keywords}.*${SOC}.*${main_line_version}.*${firmware_suffix}"

# 02. Check Updated
check_updated() {
    tolog "02. Start checking the updated ..."
    curl -s "https://api.github.com/repos/${server_firmware_url}/releases" >${github_api_openwrt} && sync
    sleep 1

    # Get the openwrt firmware updated_at
    api_down_line_array=$(cat ${github_api_openwrt} | grep -n "${firmware_download_url}" | awk -F ":" '{print $1}' | tr "\n" " " | echo $(xargs))
    # return: 123 233 312

    i=1
    api_updated_at=()
    api_updated_merge=()
    for x in ${api_down_line_array}; do
        api_updated_at[${i}]="$(cat ${github_api_openwrt} | sed -n "$((x - 1))p" | cut -d '"' -f4)"
        api_updated_merge[${i}]="${x}@$(cat ${github_api_openwrt} | sed -n "$((x - 1))p" | cut -d '"' -f4)"
        let i++
    done
    # return: api_updated_at: 2021-10-21T17:52:56Z 2021-10-21T11:22:39Z 2021-10-22T17:52:56Z
    latest_updated_at=$(echo ${api_updated_at[*]} | tr ' ' '\n' | sort -r | head -n 1)
    latest_updated_at_format=$(echo ${latest_updated_at} | tr 'T' '(' | tr 'Z' ')')
    # return: latest_updated_at: 2021-10-22T17:52:56Z
    api_op_down_line=$(echo ${api_updated_merge[*]} | tr ' ' '\n' | grep ${latest_updated_at} | cut -d '@' -f1)
    # return: api_openwrt_download_line: 123

    if [[ -n "${api_op_down_line}" && -n "$(echo ${api_op_down_line} | sed -n "/^[0-9]\+$/p")" ]]; then
        tolog '<input type="button" class="cbi-button cbi-button-reload" value="Download" onclick="return b_check_firmware(this, '"'download_${api_op_down_line}'"')"/> Latest updated: '${latest_updated_at_format}''
    else
        tolog "02.02 Invalid firmware check." "1"
    fi

    exit 0
}

# 03. Download Openwrt firmware
download_firmware() {
    tolog "03. Download Openwrt firmware ..."

    # Get the openwrt firmware download path
    if [[ ${download_version} == download* ]]; then
        download_version=$(echo "${download_version}" | cut -d '_' -f2)
        tolog "03.01 Start downloading..."
    else
        tolog "03.02 Invalid parameter" "1"
    fi

    firmware_releases_path=$(cat ${github_api_openwrt} | sed -n "${download_version}p" | grep "browser_download_url" | grep -o "${firmware_download_url}" | head -n 1)
    firmware_download_name="openwrt_${SOC}_k${main_line_version}_github${firmware_suffix}"
    wget -c "${firmware_releases_path}" -O "${FIRMWARE_DOWNLOAD_PATH}/${firmware_download_name}" >/dev/null 2>&1 && sync
    if [[ "$?" -eq "0" && -s "${FIRMWARE_DOWNLOAD_PATH}/${firmware_download_name}" ]]; then
        tolog "03.01 OpenWrt firmware download complete, you can update."
    else
        tolog "03.02 Invalid firmware download." "1"
    fi
    sleep 2

    # Delete temporary files
    rm -f ${github_api_openwrt} 2>/dev/null && sync

    #echo '<a href="javascript:;" onclick="return amlogic_update(this, '"'${firmware_download_name}'"')">Update</a>' >$START_LOG
    tolog '<input type="button" class="cbi-button cbi-button-reload" value="Update" onclick="return amlogic_update(this, '"'${firmware_download_name}'"')"/>'

    exit 0
}

getopts 'cd' opts
case $opts in
c | check)
    check_updated
    ;;
* | download)
    download_firmware
    ;;
esac
