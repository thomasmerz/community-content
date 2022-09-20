#!/bin/bash
#
# fail.sh v0.3 - shfmnt'ed and shellcheck'ed version by https://github.com/thomasmerz
#

para=$1
parb=$2
parc=$3
pard=$4

# is curl installed?
curl=$(whereis curl | awk '{ print $2 }')
if [ $? -ne 0 ]; then
  echo "Curl is not properly configured"
  exit 1
fi

# Where is the robot at?
uri="https://robot-ws.your-server.de/failover.yaml"

# check if first argument is an ip

echo $para | grep -E "\b(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b" >/dev/null 2>&1

# if it is an ip, we do not need a config
if [ $? -eq 0 ]; then
  if [ "$parb" == "set-and-exec" ]; then
    echo "Option {set-and-exec} only available for configured services"
    exit 1
  elif [ -z "$parb" ]; then
    echo "$0 now needs one of the following options:"
    echo "usage: $0 $para {get|set} <failover-IP>"
    exit 1
  fi

  if [ -z "$parc" -a "$parb" == "set" ]; then
    echo "You have to specify the IP address of the failover server"
    exit 1
  fi
  ip=$para
  stty -echo
  echo "username:"
  read user
  echo "password:"
  read pass
  stty echo
else

  # where will I find the config files
  resourcedir="/etc/failover/resources"
  resources=$(cat $resourcedir/* | grep "resource" | awk '{ print $2 }')

  if [ $? -ne 0 ]; then
    echo "There are no properly configured resources in $resourcedir"
    exit 1
  fi

  # check if the service is properly configured in $resourcedir
  if [ -z $para ]; then
    echo "You have to specify a service or enter an IP"
    echo "configured services are:"
    echo $resources
    exit 1
  fi

  echo $resources | grep $para >/dev/null

  if [ $? -ne 0 ]; then
    echo "$para not available"
    echo "configured services are:"
    echo $resources
    exit 1
  fi

  ip=$(cat $resourcedir/$para | grep "^ip" | awk '{ print $2 }')
  if [ -z "$ip" ]; then
    echo "There is no IP-address set for resource $para in $resourcedir/$para"
    exit 1
  fi
  user=$(cat $resourcedir/$para | grep "user" | awk '{ print $2 }')
  pass=$(cat $resourcedir/$para | grep "password" | awk '{ print $2 }')
  if [ -z "$user" ]; then
    echo "There is no username set for resource $para in $resourcedir/$para"
    exit 1
  fi
  if [ -z "$pass" ]; then
    echo "There is no password set for user $user in $resourcedir/$para"
    exit 1
  fi
fi

case "$parb" in
get)

  get=$($curl -s -u $user:$pass $uri/$ip)
  if echo "$get" | grep "^error" >/dev/null 2>&1; then
    echo "There is a communication error. Hetzner returned"
    echo $get
    exit 1
  elif [ -z "$get" ]; then
    echo "There was no response from Hetzner"
    exit 1
  elif echo "$get" | grep "ip" >/dev/null 2>&1 && echo "$get" | grep "server_ip" >/dev/null 2>&1 && echo "$get" | grep "active_server_ip" >/dev/null 2>&1; then
    :
  else
    echo "This script does not know how to handle Hetzner's answer:"
    echo $get
    exit 1
  fi

  yamlip=$(echo "$get" | grep "^  ip" | awk '{ print $2 }')
  yamlserverip=$(echo "$get" | grep "^  server_ip" | awk '{ print $2 }')
  yamlactiveip=$(echo "$get" | grep "^  active_server_ip" | awk '{print $2 }')

  echo "This is the active configuration of the service $para"
  echo "IP address of the service: $yamlip"
  echo "failover IP was ordered for: $yamlserverip"
  echo "currently the IP is routed to: $yamlactiveip"
  if [ "$ip" != "$para" ]; then echo "the configured failover server(s) is/are: $(cat $resourcedir/$para | grep "^failover_ip" | sed -e 's/failover_ip //g')"; fi
  ;;

set)

  if [ -z $parc ]; then
    echo "You have to specify the IP address of the failover server"
    echo "the configured failover server(s) is/are: $(cat $resourcedir/$para | grep "^failover_ip" | sed -e 's/failover_ip //g')"
    exit 1
  fi

  echo "Waiting for a response..."
  set=$($curl -s -u $user:$pass $uri/$ip -d active_server_ip=$parc)

  if echo "$set" | grep "^error" >/dev/null 2>&1; then
    if echo "$set" | grep "^  status: 409" >/dev/null 2>&1; then
      echo "Looks like you tried to route the failover IP to the currently selected server"
      exit 1
    elif echo "$set" | grep "^  status: 500" >/dev/null 2>&1; then
      echo "There seems to be an error with the rerouting request on Hetzner's part"
      echo "Try again later"
      exit 1
    elif echo "$set" | grep "^  status: 404" >/dev/null 2>&1; then
      echo "Hetzner returned Error 404"
      echo "Most likely the failover IP for the service is faulty"
      exit 1
    fi
    echo "An unknown error occurred"
    exit 1

  elif echo "$set" | grep "^failover" >/dev/null 2>&1; then
    yamlip=$(echo "$set" | grep "^  ip" | awk '{ print $2 }')
    yamlserverip=$(echo "$set" | grep "^  server_ip" | awk '{ print $2 }')
    yamlactiveip=$(echo "$set" | grep "^  active_server_ip" | awk '{ print $2 }')

    echo "This is the changed configuration of the service $para"
    echo "IP address of the service: $yamlip"
    echo "failover IP was ordered for: $yamlserverip"
    echo "currently the IP is routed to: $yamlactiveip"
    if [ "$ip" != "$para" ]; then echo "the configured failover server(s) is/are: $(cat $resourcedir/$para | grep "^failover_ip" | sed -e 's/failover_ip //g')"; fi
  fi

  ;;

set-and-exec)

  script=$(grep "script" $resourcedir/$para | awk '{ print $2 }')

  if [ -z "$script" ]; then
    echo "There is no script set in $resourcedir/$para"
    exit 1
  elif [ -x $script ]; then
    ./$0 $para set $parc
    if [ $? = 0 ]; then $script; else exit 1; fi
  elif [ -f $script ]; then
    echo "Script is not executable"
    exit 1
  fi
  ;;
*)
  if [ -n $parb ]; then
    echo "$parb is an unknown option"
  fi
  echo -e "$0 needs one of the following options"
  echo "usage: $0 <service> {get|set|set-and-exec} <failover IP>"
  exit 1
  ;;

esac
