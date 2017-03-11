#!/bin/bash

#----Operation openshift api----
#$1 https ca file
#$2 token
#$3 openshift master url
#$4 pod's namespace
#$5 resource type: "pods | deploymentconfigs"
#$6 api action: "PUT | GET | DELETE"
#$7 resource name: "pod_name | dc_name"
#$8 file path
function request_ose_api(){
  local ca_file=$1
  local default_token=$2
  local master_url=$3
  local namespace=$4
  local resource_type=$5
  local api_action=$6
  local resource_name=$7
  local resource_file_path=$8
  local ose_api=api
  local timeout_opts="-m 1 --connect-timeout 1"
  local api_response_code
  if [ $resource_type == "deploymentconfigs" ];then
     ose_api=oapi
  fi
  case "$api_action" in
    GET)
      local api_response_code=$(curl $timeout_opts -s -o ${resource_file_path}  -w "%{http_code}"  -XGET --cacert $ca_file -H "Authorization: Bearer $default_token" -H "Content-type:application/json" ${master_url}/${ose_api}/v1/namespaces/${namespace}/${resource_type}/${resource_name})
      ;;
    PUT)
      local api_response_code=$(curl $timeout_opts -s -o /dev/null -w "%{http_code}" -XPUT --cacert $ca_file -H "Authorization: Bearer $default_token" -H "Content-type:application/json" ${master_url}/${ose_api}/v1/namespaces/${namespace}/${resource_type}/${resource_name} --data  "@${resource_file_path}")
      ;;
    DELETE)
      local api_response_code=$(curl $timeout_opts -s -o /dev/null -w "%{http_code}" -XDELETE --cacert $ca_file -H "Authorization: Bearer $default_token" -H "Content-type:application/json" ${master_url}/${ose_api}/v1/namespaces/${namespace}/${resource_type}/${resource_name})
      ;;
  esac
  echo $api_response_code
}

#----get pod current state----
function get_pod_probe_state() {
  local probe_status=`cat "$pod_file_path" | grep '\"ready\":'`
  local ready=`echo $probe_status | cut  -d ' ' -f 2 | cut -d ',' -f 1`
  echo $ready
}

#----update unhealthy pod labels----
function update_pod_labels(){
  local selector_label=`grep -A1 selector  "$dc_file_path" | grep -v selector | cut -d ':' -f 1`
  local selector_content=`cat "$pod_file_path" | grep -n $selector_label`
  local comma_tag=`echo $selector_content | grep ','`
  #remove label
  if [ ! -n "$comma_tag" ];then
    local line_num=`echo $selector_content | cut -d ':' -f 1`
    sed -i "/$selector_label/d" $pod_file_path
    if [ "$line_num" ];then
      sed -i $(($line_num - 1))'s/,//' $pod_file_path
    fi
  else
    sed -i "/$selector_label/d" $pod_file_path
  fi
  #add other labels
  sed -i '/labels/a\\      \"status\": \"unhealthy\",' $pod_file_path
}

#----get current unhealthy pod list----
#$1 dc file path
function get_current_unhealthy_pod(){
  declare -a current_unhealthy_pod
  local dc_file_path=$1
  local unhealthy_pods_exist=`grep "unhealthy_pods" $dc_file_path`
  if [ -n "unhealthy_pods_exist" ];then
    local pod_context=`grep "unhealthy_pods" $dc_file_path | awk -F '[{}]' '{print $2}'`
    local pod_name_list_temp=${pod_context//'\"pod_name\":'/ }
    local pod_name_list=${pod_name_list_temp//'\"'/ }
    IFS=',' read -a current_pod_list <<< $pod_name_list 
    for unhealthy_pod in ${current_pod_list[@]}; do
      current_unhealthy_pod=(${current_unhealthy_pod[@]} $unhealthy_pod)
    done
  fi
  echo "${current_unhealthy_pod[@]}"
}

#----generate annotations context for unhealthy pod----
#$1 new unhealthy pod name
#$2 dc file path
#$3 whether block isolate or not
function generate_annotations_context(){
  local context=""
  local new_pod_name=$1
  local dc_file_path=$2
  local block_isolate=$3
  declare -a unhealthy_pod_name
  declare -a oldest_pod_name
  pod_name_str="$(get_current_unhealthy_pod $dc_file_path)"
  unhealthy_pod_name=($pod_name_str)
  current_num=${#unhealthy_pod_name[@]}
  oldest_pod_num=`expr $current_num - $max_isolate_num + 1`
  if [ "$oldest_pod_num" -gt "0" ];then
     if [ "$block_isolate" == "false" ];then
        oldest_pod_name=(${unhealthy_pod_name[@]::$oldest_pod_num})
        unhealthy_pod_name=(${unhealthy_pod_name[@]:$oldest_pod_num})
        unhealthy_pod_name=(${unhealthy_pod_name[@]} $new_pod_name)
     else
        oldest_num=`expr $current_num - $max_isolate_num`
        oldest_pod_name=(${unhealthy_pod_name[@]::$oldest_num})
        unhealthy_pod_name=(${unhealthy_pod_name[@]:$oldest_num})
        oldest_pod_name=(${oldest_pod_name[@]} $new_pod_name)
     fi
  else
     unhealthy_pod_name=(${unhealthy_pod_name[@]} $new_pod_name)
  fi
  for unhealthy_pod in ${unhealthy_pod_name[@]}; do
      context="${context} \\\\\"pod_name\\\\\": \\\\\"$unhealthy_pod\\\\\","
  done
  context=`echo ${context%,*}`
  local annotations_context="\"unhealthy_pods\": \"{ $context }\""
  echo "$annotations_context|${oldest_pod_name[@]}"
}

#----update dc of annotations----
#$1 annotations context
#$2 dc file path
function inject_annotations(){
  local annotations=$1
  local dc_file_path=$2
  local annotations_exist=`grep "annotations" $dc_file_path`
  if [ -n "$annotations_exist" ];then
    local unhealthy_pods_exist=`grep "unhealthy_pods" $dc_file_path`
    if [ -n "$unhealthy_pods_exist" ];then
      local comma_exist=`grep -E "unhealthy_pods.*,$" $dc_file_path`
      if [ -n "$comma_exist" ];then
        sed -i "s|     \"unhealthy_pods\".*|     ${annotations},|"  $dc_file_path
      else
        sed -i "s|     \"unhealthy_pods\".*|     ${annotations}|" $dc_file_path
      fi
    else
      sed -i "/annotations/a\\      ${annotations}," $dc_file_path
    fi
  else 
    local line_num=`grep -n '"metadata": {'  $dc_file_path | head -1 | cut -d ':' -f 1`
    sed -i "${line_num}a\    \"annotations\": {" $dc_file_path
    local next_line=$(($line_num + 1))
    sed -i "${next_line}a\       ${annotations}"  $dc_file_path
    local second_line=$(($line_num + 2))
    sed -i "${second_line}a\    },"  $dc_file_path
  fi
}
