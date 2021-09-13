#!/bin/bash

# Ubuntu release reference: https://wiki.ubuntu.com/Releases
zabbix_agent-install-ubuntu ()
{
  if [ ! $(which wget) ]; then
    apt-get install -y wget
  fi

  DISTRO=$(cat /etc/*release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '"' | grep -Eo 'Ubuntu.*[0-9]{2}')

  case ${DISTRO} in
    "Ubuntu 20.04")
      PACKAGE='http://repo.zabbix.com/zabbix/5.0/ubuntu/pool/main/z/zabbix/zabbix-agent_5.0.0-1%2Bfocal_amd64.deb'
      ZABBIX_AGENT_START="systemctl enable --now zabbix-agent"
    ;;
    "Ubuntu 18.04")
      PACKAGE='http://repo.zabbix.com/zabbix/5.0/ubuntu/pool/main/z/zabbix/zabbix-agent_5.0.0-1%2Bbionic_amd64.deb'
      ZABBIX_AGENT_START="systemctl enable --now zabbix-agent"
    ;;
    "Ubuntu 16.04")
      PACKAGE='http://repo.zabbix.com/zabbix/5.0/ubuntu/pool/main/z/zabbix/zabbix-agent_5.0.0-1%2Bxenial_amd64.deb'
      ZABBIX_AGENT_START="systemctl enable --now zabbix-agent"
    ;;
    "Ubuntu 14.04")
      PACKAGE='http://repo.zabbix.com/zabbix/5.0/ubuntu/pool/main/z/zabbix/zabbix-agent_5.0.0-1%2Btrusty_amd64.deb'
      ZABBIX_AGENT_START="service zabbix-agent start && ckconfig zabbix-agent on"
    ;;
  esac

  wget ${PACKAGE} 
  sudo dpkg -i zabbix-agent_5.*.deb
  sudo ${ZABBIX_AGENT_START}
  zabbix_agent_config_file

}

# Red Hat Distros
zabbix_agent-install-redhat-like ()
{
  sudo yum install -y http://repo.zabbix.com/zabbix/5.0/rhel/7/x86_64/zabbix-agent-5.0.0-1.el7.x86_64.rpm
  zabbix_agent_config_file
  sudo systemctl enable --now zabbix-agent && \
      sudo systemctl status zabbix-agent
}

zabbix_agent_config_file ()
{

    sudo cat > /etc/zabbix/zabbix_agentd.conf << EOF
PidFile=/run/zabbix/zabbix_agentd.pid
LogFile=/var/log/zabbix/zabbix_agentd.log
DebugLevel=3
Server=${ZABBIX_SERVER}
ListenPort=10050
ListenIP=0.0.0.0
StartAgents=3
ServerActive=${ZABBIX_SERVER}
Hostname=${HOST_NAME}
DenyKey=system.run[*]
Timeout=3
User=zabbix
Include=/etc/zabbix/zabbix_agentd.d/
EOF

}

### Main function 
# Distro detect
main ()
{
  DISTRO=$(cat /etc/*release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '"' | cut -d' ' -f1)

  case ${DISTRO} in
    "Ubuntu")
      zabbix_agent-install-ubuntu
    ;;
    "CentOS"|"Amazon"|"Red"|"Rocky")
      zabbix_agent-install-redhat-like
    ;;
    *)
      echo "[${DISTRO} ==> Not supported!]"
      exit 0
    ;;
  esac
}


# Zabbix API 
api_zabbix_availability_check ()
{
  
  echo -e "*** Zabbix API - Connection ***\n"
  read -p "Endpoint: " ZABBIX_URL 
  read -p "User    : " API_USER
  read -p "Password: " API_PASS

  HEADER="Content-Type:application/json"

  curl -Is ${ZABBIX_URL} > .header.tmp 
  HTTP_STATUS_CODE=$(grep HTTP .header.tmp | cut -d' ' -f2)
  
  case ${HTTP_STATUS_CODE} in
    "200")
      echo $(grep HTTP .header.tmp)
     ;;
     "301")
       sed -i 's/\r$//' .header.tmp
       ZABBIX_URL="$(grep -E 'Location' .header.tmp | awk '{print $2}')"
     ;;
     *)
       exit 0
     ;;
  esac
  rm -f .header

}


# API Autentication
api_zabbix_authentication ()
{

  JSON_API_AUTENTICATION='
  {
    "jsonrpc":"2.0",
    "method":"user.login",
    "params":{
      "user":"'${API_USER}'",
      "password":"'${API_PASS}'"
    },
    "id":0
  }
  '
  TOKEN=$(curl -s -X POST -H "${HEADER}" -d "${JSON_API_AUTENTICATION}" ${ZABBIX_URL}/api_jsonrpc.php | cut -d'"' -f8)
   
  JSON_API_DISCONNECT='
  {
    "jsonrpc": "2.0",
    "method": "user.logout",
    "params": [],
    "id": 0,
    "auth": "'$TOKEN'"
  } 
  '

}

# Group create
api_zabbix_group_create ()
{ 

  # Checking if the group exists
  JSON_HOSTGROUP_GET='
  {
    "jsonrpc": "2.0",
    "method": "hostgroup.get",
    "params": {
      "output": "extend",
        "filter": {
          "name": [
            "'$GROUP_NAME'"
          ]
        }
    },
    "auth": "'$TOKEN'",
    "id": 1
  }
  '
  GROUP_ID="$(curl -s -X POST -H "${HEADER}" -d "${JSON_HOSTGROUP_GET}" ${ZABBIX_URL}/api_jsonrpc.php | awk -v RS='{"' -F\" '/^groupid/ {printf $3}')"

  if [ -z ${GROUP_ID} ]; then
    JSON_HOSTGROUP_CREATE=' 
    {
      "jsonrpc": "2.0",
      "method": "hostgroup.create",
      "params": {
          "name": "'$GROUP_NAME'"
      },
      "auth": "'$TOKEN'",
      "id": 1
    }
    '
    GROUP_ID=$(curl -s -X POST -H "${HEADER}" -d "${JSON_HOSTGROUP_CREATE}" ${ZABBIX_URL}/api_jsonrpc.php | awk -v RS='{"' -F\" '/^groupid/ {printf $3}' )
  fi 
  
}

api_zabbix_host_create ()
{

  HOST_IP=$(ip a | grep -E 'inet.*[0-9]{0,3}\.[0-9]{0,3}\.[0-9]{0,3}\.[0-9]{0,3}' | awk '{print $2}' | cut -d'/' -f1 | grep -vF '127.0.0.1')

  # Host create
  JSON_HOST_CREATE='
  {
  "jsonrpc": "2.0",
  "method": "host.create",
  "params": {
     "host": "'$HOST_NAME'",
     "interfaces": [
       {
         "type": 1,
         "main": 1,
         "useip": 1,
         "ip": "'$HOST_IP'",
         "dns": "",
         "port": "10050"
       }
      ],
      "groups": [
        {
          "groupid":"'$GROUP_ID'",
          "name": "'$GROUP_NAME'"
        }
      ],
      "tags": [
        {
          "tag": "Host name",
          "value": "'$HOST_NAME'"
        }
      ],
      "templates": [
        {
          "templateid": "10284",
          "name": "Template OS Linux by Zabbix agent active"
        }
      ]
  },
    "auth": "'$TOKEN'",
    "id": 1
  }
  '
  curl -s -X POST -H "${HEADER}" -d "${JSON_HOST_CREATE}" ${ZABBIX_URL}/api_jsonrpc.php

  # Disconnect
  curl -s -X POST -H "${HEADER}" -d "${JSON_API_DISCONNECT}" ${ZABBIX_URL}/api_jsonrpc.php
}

# Main funciton
main

### Zabbix API 
api_zabbix_availability_check

# API Connection
api_zabbix_authentication

# Group
api_zabbix_group_create

# Host
api_zabbix_host_create

# Sintax
#  && env ZABBIX_SERVER="" GROUP_NAME="" HOST_NAME="" ./zabbix_agent-install.sh
