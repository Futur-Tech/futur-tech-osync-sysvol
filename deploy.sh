#!/usr/bin/env bash

source "$(dirname "$0")/ft-util/ft_util_inc_var"
source "$(dirname "$0")/ft-util/ft_util_inc_func"
source "$(dirname "$0")/ft-util/ft_util_sudoersd"
source "$(dirname "$0")/ft-util/ft_util_usrmgmt"

app_name="futur-tech-osync-sysvol"
app_user="ft-osync-sysvol"

required_pkg_arr=("rsync" "at")

bin_dir="/usr/local/bin/${app_name}"
etc_f="/usr/local/etc/${app_name}.conf"

$S_LOG -d $S_NAME "Start $S_DIR_NAME/$S_NAME $*"

# Checking which Zabbix Agent is detected and adjust include directory
$(which zabbix_agent2 >/dev/null) && zbx_conf_agent_d="/etc/zabbix/zabbix_agent2.d"
$(which zabbix_agentd >/dev/null) && zbx_conf_agent_d="/etc/zabbix/zabbix_agentd.conf.d"
if [ ! -d "${zbx_conf_agent_d}" ]; then $S_LOG -s warn -d $S_NAME "${zbx_conf_agent_d} Zabbix Include directory not found"; fi

echo "
    CHECK CURRENT SAMBA SETUP
------------------------------------------"

# Check if Samba is compiled
if [ -d "/usr/local/samba/" ]; then
    $S_LOG -s crit -d $S_NAME "Sorry but /usr/local/samba/ exist and maybe you have already a compiled version of Samba... this script is not prepared for this setup."
    exit
fi

# Check samba-tool
if [ -z "$(command -v samba-tool)" ]; then
    $S_LOG -s crit -d $S_NAME "Cannot find the 'samba-tool' binary, is it installed?"
    exit
fi

# Check if server role is active directory domain controller
server_role=$(samba-tool testparm --suppress-prompt --parameter-name="server role" 2>/dev/null)
if [ ! "${server_role}" = "active directory domain controller" ]; then
    $S_LOG -s crit -d $S_NAME "Please deploy this repo on a Samba Active Directory Domain Controller only (current role: ${server_role})"
    exit
fi

# Check how many DC are in the domain
nbr_dc=$(samba-tool group listmembers 'Domain Controllers' | wc -l)
$S_LOG -d $S_NAME "${nbr_dc} Domain Controllers found on the AD domain"
if ((${nbr_dc} > 2)); then
    $S_LOG -s crit -d $S_NAME "Sorry this AD Domain has more than 2 Domain Controller... this script is not prepared for this setup."
    exit
elif ((${nbr_dc} < 2)); then
    $S_LOG -s crit -d $S_NAME "Why synchronize? This Domain Controller is the only one around here... this script is not prepared for this setup."
    exit
fi

# The PDC Emulation Master will run the osync
if samba-tool fsmo show | grep PdcEmulationMasterRole | grep -i $(hostname --short) >/dev/null; then
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

if ping -c 1 $other_dc_fqdn &>/dev/null; then
    $S_LOG -d $S_NAME "${other_dc_fqdn} is reachable"
else
    $S_LOG -s crit -d $S_NAME "${other_dc_fqdn} is not reachable"
    exit
fi

echo "
    CHECK NEEDED PACKAGES
------------------------------------------"
$S_DIR_PATH/ft-util/ft_util_pkg -u -i ${required_pkg_arr[@]} || exit 1

echo "
    SETUP USER/GROUP
------------------------------------------"
if [ ! $(getent group ${app_user}) ]; then
    groupadd ${app_user}
    $S_LOG -s $? -d $S_NAME "Creating group \"${app_user}\" returned EXIT_CODE=$?"
else $S_LOG -d $S_NAME "Group \"${app_user}\" exists"; fi
if [ ! $(getent passwd ${app_user}) ]; then
    useradd --shell /bin/bash --home /home/${app_user} --create-home --comment "${app_user}" --password '*' --gid ${app_user} ${app_user}
    $S_LOG -s $? -d $S_NAME "Creating user \"${app_user}\" returned EXIT_CODE=$?"
else $S_LOG -d $S_NAME "User \"${app_user}\" exists"; fi

echo "
    SETUP SSH KEYS
------------------------------------------"

$S_DIR_PATH/ft-util/ft_util_sshkey ${app_user} # Create SSH Key

if [ "$is_dc_master" = true ]; then
    # Test SSH Connection
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -i /home/${app_user}/.ssh/id_rsa -q ${app_user}@${other_dc_fqdn} exit
    if [ $? -ne 0 ]; then
        # Show instructions to deploy public key on other DC
        echo "ssh connection to ${app_user}@${other_dc_fqdn} failed
        1 - Deploy the repo to ${other_dc_fqdn}
        2 - Run the followinf command on ${other_dc_fqdn}:
        echo \"$(cat /home/${app_user}/.ssh/id_rsa.pub)\" > /home/${app_user}/.ssh/authorized_keys.d/${app_name}
        3 - Deploy again the repo to ${other_dc_fqdn}
        4 - Deplay again the repo on $(hostname)
        " | $S_LOG -s warn -d $S_NAME -i
        exit
    else
        $S_LOG -d $S_NAME "ssh connection to ${app_user}@${other_dc_fqdn} successful"
    fi

else
    $S_DIR_PATH/ft-util/ft_util_sshauth ${app_user} # Setup of authorized_keys
fi

echo "
    SETUP SUDOER FILES
------------------------------------------"

bak_if_exist "/etc/sudoers.d/${app_name}"
sudoersd_reset_file $app_name $app_user
if [ ! "$is_dc_master" = true ]; then
    sudoersd_addto_file $app_name $app_user "$(type -p rsync),$(type -p bash)" ALL root "NOPASSWD:SETENV"
    sudoersd_addto_file $app_name $app_user "/usr/bin/samba-tool ntacl sysvolreset" ALL root "NOPASSWD:SETENV"
fi
if [ -d "${zbx_conf_agent_d}" ]; then
    echo "Defaults:zabbix !requiretty" | sudo EDITOR='tee -a' visudo --file=$sudoers_etc &>/dev/null
    sudoersd_addto_file $app_name zabbix "${S_DIR_PATH}/deploy-update.sh"
    sudoersd_addto_file $app_name zabbix "/usr/bin/samba-tool fsmo show"
    sudoersd_addto_file $app_name zabbix "/usr/bin/samba-tool ntacl sysvolcheck"
fi
show_bak_diff_rm "/etc/sudoers.d/${app_name}"

echo "
    INSTALL BIN FILES
------------------------------------------"
if [ "$is_dc_master" = true ]; then
    mkdir_if_missing ${bin_dir}
    $S_DIR/ft-util/ft_util_file-deploy "$S_DIR/osync.sh" "${bin_dir}/osync.sh"
else
    echo "Only on PDC Emulation Master"
fi

echo "
    CONFIGURATION FILES
------------------------------------------"
if [ "$is_dc_master" = true ]; then

    bak_if_exist ${etc_f}
    $S_DIR/ft-util/ft_util_file-deploy "$S_DIR/sync.conf.example" "${etc_f}" "NO-COMPARE"

    function custom_conf() {
        if grep "^${1}=" ${etc_f} &>/dev/null; then
            sed -i "s|^${1}=.*$|${1}=${2} # ${app_name}|" ${etc_f} >/dev/null
            $S_LOG -s ${?/0/debug} -d $S_NAME -d "custom_conf" "${1}=${2} returned EXIT_CODE=$?"
        else
            $S_LOG -s crit -d $S_NAME -d "custom_conf" "Couldn't find ${1} in ${etc_f}"
        fi
    }

    custom_conf INSTANCE_ID "\"${app_name}\""

    custom_conf INITIATOR_SYNC_DIR "\"/var/lib/samba/sysvol\""
    custom_conf TARGET_SYNC_DIR "\"ssh://${app_user}@${other_dc_fqdn}//var/lib/samba/sysvol\""

    custom_conf SUDO_EXEC "true"
    custom_conf SSH_RSA_PRIVATE_KEY "\"/home/${app_user}/.ssh/id_rsa\""
    custom_conf SSH_IGNORE_KNOWN_HOSTS "true"
    custom_conf REMOTE_HOST_PING "true"
    custom_conf REMOTE_3RD_PARTY_HOSTS "\"\""

    custom_conf SOFT_DELETE "true"
    custom_conf SOFT_DELETE_DAYS "30"

    custom_conf PRESERVE_ACL "true"
    custom_conf PRESERVE_XATTR "true"
    custom_conf CHECKSUM "true"

    custom_conf RSYNC_COMPRESS "false"

    custom_conf LOCAL_RUN_AFTER_CMD "\"/usr/bin/samba-tool ntacl sysvolreset\""
    custom_conf REMOTE_RUN_AFTER_CMD "\"sudo /usr/bin/samba-tool ntacl sysvolreset\""

    custom_conf LOGFILE "\"/var/log/${app_name}.log\""
    custom_conf DESTINATION_MAILS "\"\""

    # This is just to avoid problem with ft_util_conf-update which doesn't like when nothing is after =
    custom_conf SKIP_DELETION "\"\""
    custom_conf SYNC_TYPE "\"\""
    custom_conf SMTP_USER "\"\""
    custom_conf SMTP_PASSWORD "\"\""

    show_bak_diff_rm ${etc_f}

else
    echo "Only on PDC Emulation Master"
fi

echo "
  INSTALL CRON.D FILES
------------------------------------------"

if [ "$is_dc_master" = true ]; then
    $S_DIR/ft-util/ft_util_file-deploy "$S_DIR/etc.cron.d/${app_name}" "/etc/cron.d/${app_name}" "NO-BACKUP"
else
    # Remove cron if not master... in case roles got reversed
    [ -e "/etc/cron.d/${app_name}" ] && rm "/etc/cron.d/${app_name}"
fi

echo "
  SETUP LOG ROTATION
------------------------------------------"

[ ! -e "/var/log/${app_name}.log" ] && touch /var/log/${app_name}.log
enforce_security conf "/var/log/${app_name}.log" adm

$S_DIR/ft-util/ft_util_file-deploy "$S_DIR/etc.logrotate/${app_name}" "/etc/logrotate.d/${app_name}"

if [ -d "${zbx_conf_agent_d}" ]; then
    echo "
  INSTALL ZABBIX CONF
------------------------------------------"

    $S_DIR/ft-util/ft_util_file-deploy "$S_DIR/etc.zabbix/${app_name}.conf" "${zbx_conf_agent_d}/${app_name}.conf"
    echo "systemctl restart zabbix-agent*" | at now + 1 min &>/dev/null ## restart zabbix agent with a delay
    $S_LOG -s $? -d "$S_NAME" "Scheduling Zabbix Agent Restart"
fi

exit
