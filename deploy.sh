#!/usr/bin/env bash

source "$(dirname "$0")/ft-util/ft_util_inc_var"

app_name="futur-tech-osync-sysvol"
app_user="ft-osync-sysvol"

required_pkg_arr=( "rsync" "at" )

bin_dir="/usr/local/bin/${app_name}"
src_dir="/usr/local/src/${app_name}"
etc_file="/usr/local/src/${app_name}.conf"
sudoers_etc="/etc/sudoers.d/${app_name}"

$S_LOG -d $S_NAME "Start $S_DIR_NAME/$S_NAME $*"

# Checking which Zabbix Agent is detected and adjust include directory
$(which zabbix_agent2 >/dev/null) && zbx_conf_agent_d="/etc/zabbix/zabbix_agent2.d"
$(which zabbix_agentd >/dev/null) && zbx_conf_agent_d="/etc/zabbix/zabbix_agentd.conf.d"
if [ ! -d "${zbx_conf_agent_d}" ] ; then $S_LOG -s warn -d $S_NAME "${zbx_conf_agent_d} Zabbix Include directory not found" ; fi

echo "
    CHECK CURRENT SAMBA SETUP
------------------------------------------"

# Check if Samba is compiled
if [ -d "/usr/local/samba/" ] ; then $S_LOG -s crit -d $S_NAME "Sorry but /usr/local/samba/ exist and maybe you have already a compiled version of Samba... this script is not prepared for this setup." ; exit ; fi

# Check samba-tool
if [ -z "$(command -v samba-tool)" ] ; then $S_LOG -s crit -d $S_NAME "Cannot find the 'samba-tool' binary, is it installed?" ; exit ; fi

# Check if server role is active directory domain controller
server_role=$(samba-tool testparm --suppress-prompt --parameter-name="server role" 2>/dev/null)
if [ ! "${server_role}" = "active directory domain controller" ] ; then $S_LOG -s crit -d $S_NAME "Please deploy this repo on a Samba Active Directory Domain Controller only (current role: ${server_role})" ; exit ; fi

# Check how many DC are in the domain
nbr_dc=$(samba-tool group listmembers 'Domain Controllers' | wc -l)
$S_LOG -d $S_NAME "${nbr_dc} Domain Controllers found on the AD domain"
if (( ${nbr_dc} > 2 )) ; then
    $S_LOG -s crit -d $S_NAME "Sorry this AD Domain has more than 2 Domain Controller... this script is not prepared for this setup." ; exit
elif (( ${nbr_dc} < 2 )) ; then
    $S_LOG -s crit -d $S_NAME "Why synchronize? This Domain Controller is the only one around here... this script is not prepared for this setup." ; exit
fi

# The PDC Emulation Master will run the osync
if samba-tool fsmo show | grep PdcEmulationMasterRole | grep -i $(hostname --short) >/dev/null ; then
    is_dc_master=true
    $S_LOG -d $S_NAME "This domain controller has PDC Emulation Master Role" 
    $S_LOG -d $S_NAME "Osync script will be run from here"
else
    is_dc_master=false
    $S_LOG -d $S_NAME "This domain controller doesn't have PDC Emulation Master Role" 
fi

# Who is the other DC?
other_dc_fqdn=$(samba-tool group listmembers 'Domain Controllers' | grep -iv $(hostname --short) | tr '[:upper:]' '[:lower:]' | sed "s/\$$/.$(hostname | cut -d '.' -f 2-)/")
$S_LOG -d $S_NAME "${other_dc_fqdn} is the other Domain Controller on the AD domain"

if ping -c 1 $other_dc_fqdn &> /dev/null ; then
    $S_LOG -d $S_NAME "${other_dc_fqdn} is reachable"
else
    $S_LOG -s crit -d $S_NAME "${other_dc_fqdn} is not reachable" ; exit
fi

echo "
    CHECK NEEDED PACKAGES
------------------------------------------"
$S_DIR_PATH/ft-util/ft_util_pkg -u -i ${required_pkg_arr[@]} || exit 1

echo "
    SETUP USER/GROUP
------------------------------------------"
if [ ! $(getent group ${app_user}) ] ; then groupadd ${app_user} ; $S_LOG -s $? -d $S_NAME "Creating group \"${app_user}\" returned EXIT_CODE=$?" ; else $S_LOG -d $S_NAME "Group \"${app_user}\" exists" ; fi
if [ ! $(getent passwd ${app_user}) ] ; then useradd --shell /bin/bash --home /home/${app_user} --create-home --comment "${app_user}" --password '*' --gid ${app_user} ${app_user} ; $S_LOG -s $? -d $S_NAME "Creating user \"${app_user}\" returned EXIT_CODE=$?" ; else $S_LOG -d $S_NAME "User \"${app_user}\" exists" ; fi


echo "
    SETUP SSH KEYS
------------------------------------------"

if [ "$is_dc_master" = true ] ; then
    $S_DIR_PATH/ft-util/ft_util_sshkey ${app_user} # Create SSH Key
else
    $S_DIR_PATH/ft-util/ft_util_sshauth ${app_user} # Setup of authorized_keys
fi

echo "
    SETUP SUDOER FILES
------------------------------------------"
if [ "$is_dc_master" = true ] ; then
    echo "Only on PDC Emulation Slave"

else
    $S_LOG -d $S_NAME -d "$sudoers_etc" "==============================="
    echo "Defaults:${app_user} !requiretty" | sudo EDITOR='tee' visudo --file=$sudoers_etc &>/dev/null
    echo "${app_user} ALL=NOPASSWD:SETENV:$(type -p rsync),$(type -p bash)" | sudo EDITOR='tee -a' visudo --file=$sudoers_etc &>/dev/null
    cat $sudoers_etc | $S_LOG -d "$S_NAME" -d "$sudoers_etc" -i 
    $S_LOG -d $S_NAME -d "$sudoers_etc" "==============================="

fi


echo "
    INSTALL BIN FILES
------------------------------------------"
if [ "$is_dc_master" = true ] ; then
    if [ ! -d "${bin_dir}" ] ; then mkdir "${bin_dir}" ; $S_LOG -s $? -d $S_NAME "Creating ${bin_dir} returned EXIT_CODE=$?" ; fi
    $S_DIR/ft-util/ft_util_file-deploy "$S_DIR/osync.sh" "${bin_dir}/osync.sh"

else
    echo "Only on PDC Emulation Master"
fi


echo "
    CONFIGURATION FILES
------------------------------------------"
if [ "$is_dc_master" = true ] ; then
    $S_DIR/ft-util/ft_util_conf-update -s "$S_DIR/sync.conf.example" -d "${etc_file}"

    conf_before=$(<${etc_file})

    function custom_conf () {
        if grep "^${1}=" ${etc_file} &>/dev/null ; then 
            sed -i "s|^${1}=.*$|${1}=${2} # ${app_name}|" ${etc_file}123 >/dev/null
            $S_LOG -s ${?/0/debug} -d $S_NAME -d "custom_conf" "${1}=${2} returned EXIT_CODE=$?"
        else
           $S_LOG -s crit -d $S_NAME -d "custom_conf" "Couldn't find ${1} in ${etc_file}"
        fi
    }

    custom_conf INSTANCE_ID "\"${app_name}\""
    custom_conf INITIATOR_SYNC_DIR "\"/var/lib/samba/sysvol\""
    custom_conf TARGET_SYNC_DIR "\"ssh://${app_user}@${other_dc_fqdn}:22//var/lib/samba/sysvol\""
    custom_conf SSH_RSA_PRIVATE_KEY "\"/home/${app_user}/.ssh/id_rsa\""
    custom_conf REMOTE_3RD_PARTY_HOSTS "\"\""
    custom_conf PRESERVE_ACL "true"
    custom_conf PRESERVE_XATTR "true"
    custom_conf RSYNC_COMPRESS "false"
    custom_conf REMOTE_RUN_AFTER_CMD "\"/usr/bin/samba-tool ntacl sysvolreset\""
    custom_conf LOGFILE "\"/var/log/${app_name}.log\""
    custom_conf SUDO_EXEC "true"


if echo -e "$conf_before" | diff --unified=0 --to-file=${etc_file} - ; then 
    $S_LOG -s info -d $S_NAME "${etc_file} has not changed"
else
    $S_LOG -s warn -d $S_NAME "${etc_file} has changed"
fi


else
    echo "Only on PDC Emulation Master"
fi

#
# echo "
#   INSTALL CRON.D FILES
# ------------------------------------------"

# [ ! -e "/etc/cron.d/${app_name}" ] && $S_DIR/ft-util/ft_util_file-deploy "$S_DIR/etc.cron.d/${app_name}" "/etc/cron.d/${app_name}"


# echo "
#   SETUP LOG ROTATION
# ------------------------------------------"

# [ ! -e "/var/log/${app_name}.log" ] && touch /var/log/${app_name}.log
# $S_DIR/ft-util/ft_util_file-deploy "$S_DIR/etc.logrotate/${app_name}" "/etc/logrotate.d/${app_name}" "NO-BACKUP"

# if [ -d "${zbx_conf_agent_d}" ]
# then
#   echo "
#   INSTALL ZABBIX CONF
# ------------------------------------------"

#   $S_DIR/ft-util/ft_util_file-deploy "$S_DIR/etc.zabbix/${app_name}.conf" "${zbx_conf_agent_d}/${app_name}.conf"


#   echo "
#   RESTART ZABBIX LATER
# ------------------------------------------"

#   echo "systemctl restart zabbix-agent*" | at now + 1 min &>/dev/null ## restart zabbix agent with a delay
#   $S_LOG -s $? -d "$S_NAME" "Scheduling Zabbix Agent Restart"
# fi

$S_LOG -d "$S_NAME" "End $S_NAME"
