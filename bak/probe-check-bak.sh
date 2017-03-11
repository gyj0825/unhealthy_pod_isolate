#/bin/bash

SECRET_PATH='/var/run/secrets/kubernetes.io/serviceaccount'
CA_FILE=${SECRET_PATH}/ca.crt
TOKEN_FILE=${SECRET_PATH}/token
NAMESPACE_FILE=${SECRET_PATH}/namespace
MASTER_URL='https://kubernetes.default.svc.cluster.local'

# check environment variable exists,use set default value
function find_env() {
  var=`printenv "$1"`
  if [ -n "$var" ]; then
    echo $var
  else
    echo $2
  fi
}

namespace=`cat $NAMESPACE_FILE`
token=`cat $TOKEN_FILE`
check_script_path=$(find_env "CHECK_SCRIPT_PATH" "/opt/webserver/bin")
use_backout=$(find_env "USE_BACKOUT" "FALSE")
backout=${use_backout^^}
flag=0

function check_status() { 
   if [ -f ${check_script_path}/readiness.sh ];then
     /bin/sh ${check_script_path}/readiness.sh
     if [ $? == 0 ];then
        exit 0
     else
        flag=1
        times=`cat /tmp/times`
        times=$(($times + 1))
        echo $times > /tmp/times
     fi
   fi
}

function check_init() {
  #first_run_check=`grep "times" ~/.bashrc | wc -l`
  #if [ "$first_run_check" == "0" ];then
  #  sed -i '$a unset '$i'' ~/.bashrc
  #fi
  #sed -i '$a times=0' ~/.bashrc
  #source ~/.bashrc
  if [ ! -f /tmp/times ];then
    echo 0 > /tmp/times
  fi
  declare -a unhealthy_pod_list
  
}

function get_pod_info() {
  curl -s --cacert $CA_FILE -H "Authorization: Bearer $token" -H "Content-type:application/json" ${MASTER_URL}/api/v1/namespaces/${namespace}/pods/${pod_name} > /tmp/${pod_name}.info.json
}

function get_dc_name(){
  temp_name=`echo ${pod_name%-*}`
  dc_name=`echo ${temp_name%-*}`
}

function delete_pod_label(){
  content=`cat /tmp/${pod_name}.info.json | grep -n $selector_label`
  tag=`echo $content | grep ','`
  if [ -n $tag ];then
    #need other handle
    line_num=`echo $content | cut -d ':' -f 1`
    sed -i "/$selector_label/d" /tmp/${pod_name}.info.json
    sed -i $(($line_num - 1))'s/,//' /tmp/${pod_name}.info.json
  else
    sed -i "/$selector_label/d" /tmp/${pod_name}.info.json
  fi
}

function add_pod_label(){
  #get_dc_name
  sed -i '/labels/a\\      \"app\": \"unhealthy\",' /tmp/${pod_name}.info.log
}


function update_pod_info(){
  curl -XPUT  --cacert $CA_FILE -H "Authorization: Bearer $token" -H "Content-type:application/json" ${MASTER_URL}/api/v1/namespaces/${namespace}/pods/${pod_name} --data  "@/tmp/${pod_name}.info.json"
}

function check_probe_state() {
  status=`cat /tmp/${pod_name}.info.json | grep '\"ready\":'`
  ready=`echo $status | cut  -d ' ' -f 2 | cut -d ',' -f 1`
}
function get_dc_selector(){
  get_dc_name
  curl -s --cacert $CA_FILE -H "Authorization: Bearer $token" -H "Content-type:application/json" ${MASTER_URL}/oapi/v1/namespaces/${namespace}/deploymentconfigs/${dc_name} > /tmp/${pod_name}.dc.info.json
  selector_line=`grep -n selector /tmp/${pod_name}.dc.info.json  | cut -d ':' -f 1`
  rc_labels=`grep -A1 selector  /tmp/${pod_name}.dc.info.json | grep -v selector | cut -d ':' -f 1`
  selector_label=$rc_labels
}

if [ ! -n "POD_NAME" ];then
   echo "Not define POD_NAME"
   exit 217
else
   pod_name=$POD_NAME
fi

check_init
check_status

if [ "$flag" == "1" ];then
  if [ "$backout" == "FALSE" ];then
    exit 1
  else
    get_pod_info
    check_probe_state
    if [ "$ready" == "false" ];then
      echo 0 > /tmp/times
    fi
    current_times=`cat /tmp/times`
    failureThreshold=`cat /tmp/${pod_name}.info.json | grep failureThreshold | cut -d ':' -f 2 | cut -d ' ' -f 2`
    #retry_times=$(($failureThreshold - 1))
    retry_times=2
    if [ "$current_times" -ge "$retry_times" ];then  
      get_pod_info
      check_probe_state
      if [ "$ready" == "true" ];then
         get_dc_selector
         delete_pod_label
         add_pod_label
         update_pod_info
      fi
      echo 0 > /tmp/times
    fi
    exit 1
  fi
fi
