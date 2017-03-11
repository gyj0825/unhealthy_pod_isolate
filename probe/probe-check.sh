#/bin/bash

#---configmap---
#must create configmap which name is <dcname>.configmap context is:
#MAX_ISOLATE_NUM=2
#BLOCK_ISOLATE=false
#---error code---
#0 probe check ok
#1 probe check failed
#200 request ose API error
#217 file and var error

#----------------init---------------------------
# check environment variable exists,use set default value
function find_env() {
  var=`printenv "$1"`
  if [ -n "$var" ]; then
    echo $var
  else
    echo $2
  fi
}
check_script_path=$(find_env "CHECK_SCRIPT_PATH")
max_failure_times=$(find_env "MAX_FAILURE_TIMES" 3)
retry_times=$(find_env "MAX_RETRY_TIMES" 20)
pod_name=`cat /etc/hostname`

SECRET_PATH='/var/run/secrets/kubernetes.io/serviceaccount'
CA_FILE=${SECRET_PATH}/ca.crt
TOKEN_FILE=${SECRET_PATH}/token
NAMESPACE_FILE=${SECRET_PATH}/namespace
MASTER_URL='https://kubernetes.default.svc.cluster.local'
NAMESPACE=`cat $NAMESPACE_FILE`
TOKEN=`cat $TOKEN_FILE`
pod_file_path=/tmp/${pod_name}.pod.info.json
dc_name_temp=`echo ${pod_name%-*}`
dc_name=`echo ${dc_name_temp%-*}`
dc_file_path=/tmp/${dc_name}.dc.info.json
if [ -f /opt/cfgmap/$dc_name ];then
  . /opt/cfgmap/$dc_name
fi
max_isolate_num=${MAX_ISOLATE_NUM:-2}
block_isolate_temp=${BLOCK_ISOLATE:-false}
block_isolate=${block_isolate_temp,,}
times_file_name='unhealthy_times'
if [ ! -f $check_script_path/probe-utils.sh ];then
  exit 217
fi
. $check_script_path/probe-utils.sh

if [ ! -f /tmp/$times_file_name ];then
  echo 0 > /tmp/$times_file_name
fi

#-------------main--------------------------
#check pod current state
i=0
while (( i++ < retry_times ));do
  response_code=$(request_ose_api $CA_FILE $TOKEN $MASTER_URL $NAMESPACE pods GET $pod_name $pod_file_path)
  if [ "$response_code" == "200" ];then
     break
  fi
done
if [ "$response_code" != "200" ];then
   echo "[Fatal]: GET /$NAMESPACE/pods/${pod_name} ERROR,can't request API,Please check!"
   exit 200
fi

current_unhealthy_label=$(grep '\"status\": \"unhealthy\"' "$pod_file_path")
pod_current_state=$(get_pod_probe_state)

if [ ! "$current_unhealthy_label" ];then  #normal pod (not be isolated, to be checked)
   if [ "$pod_current_state" == "false" ];then #not ready --> ready
      if [ -f ${check_script_path}/readiness.sh ];then
         /bin/sh ${check_script_path}/readiness.sh
         if [ $? != 0 ];then
            echo "[Error]: readiness check failed!"
            exit 1
         fi
      fi
   else  #ready --> not ready
      if [ -f ${check_script_path}/liveness.sh ];then
         /bin/sh ${check_script_path}/liveness.sh
         if [ $? == 0 ];then
            echo 0 > /tmp/$times_file_name
            exit 0
         else
            times=`cat /tmp/${times_file_name}`
            times=$(($times + 1))
            echo $times > /tmp/$times_file_name
         fi
      else
        exit 0
      fi
      current_times=`cat /tmp/$times_file_name`
      if [ "$current_times" -ge "$max_failure_times" ];then
         i=0
         while (( i++ < retry_times ));do 
           response_code=$(request_ose_api $CA_FILE $TOKEN $MASTER_URL $NAMESPACE pods GET $pod_name $pod_file_path)
           if [ "$response_code" != "200" ];then
              continue
           fi
           response_code=$(request_ose_api $CA_FILE $TOKEN $MASTER_URL $NAMESPACE deploymentconfigs GET $dc_name $dc_file_path)
           if [ "$response_code" != "200" ];then
              continue
           fi
           update_pod_labels
           response_code=$(request_ose_api $CA_FILE $TOKEN $MASTER_URL $NAMESPACE pods PUT $pod_name $pod_file_path)
           if [ "$response_code" == "200" ];then
              break
           fi
         done
         if [ "$response_code" != "200" ];then
            echo "[Error]: Update pod labels failed,http code:${response_code},Delete pod ${pod_name}..."
            i=0
            while (( i++ < retry_times ));do
               response_code=$(request_ose_api $CA_FILE $TOKEN $MASTER_URL $NAMESPACE pods DELETE $pod_name)
               if [ "$response_code" == "200" -o "$response_code" == "404" ];then
                  break
               fi
            done
            if [ "$response_code" != "200" -a "$response_code" != "404" ];then
               echo "[Error]: Delete pod ${pod_name} failed!"
               exit 200
            fi
         fi
         i=0
         while (( i++ < retry_times ));do
            response_code=$(request_ose_api $CA_FILE $TOKEN $MASTER_URL $NAMESPACE deploymentconfigs GET $dc_name $dc_file_path)
            if [ "$response_code" != "200" ];then
               continue
            fi
            annotations_context_temp=$(generate_annotations_context $pod_name $dc_file_path $block_isolate)
            oldest_pod_name=`echo ${annotations_context_temp#*|}`
            annotations_context=`echo ${annotations_context_temp%|*}`
            inject_annotations "$annotations_context" "$dc_file_path"
            response_code=$(request_ose_api $CA_FILE $TOKEN $MASTER_URL $NAMESPACE deploymentconfigs PUT $dc_name $dc_file_path)
            if [ "$response_code" == "200" ];then
               break
            fi
         done
         if [ "$response_code" != "200" ];then
            echo "[Error]: Update ${dc_name} annotations failed,http code:${response_code}.Delete pod ${pod_name}..."
            i=0
            while (( i++ < retry_times ));do
               response_code=$(request_ose_api $CA_FILE $TOKEN $MASTER_URL $NAMESPACE pods DELETE $pod_name)
               if [ "$response_code" == "200" -o "$response_code" == "404" ];then
                  break
               fi
            done
            if [ "$response_code" != "200" -a "$response_code" != "404" ];then
               echo "[Error]: Delete pod ${pod_name} failed!"
               exit 200
            fi
         fi
      fi
      if [ ! -n "$oldest_pod_name" ];then
         exit 1
      fi
      read -a delete_pod <<< $oldest_pod_name
      for unhealthy_pod in ${delete_pod[@]};do
         i=0
         while (( i++ < retry_times ));do
            if [ "$unhealthy_pod" ];then
              response_code=$(request_ose_api $CA_FILE $TOKEN $MASTER_URL $NAMESPACE pods DELETE $unhealthy_pod)
            fi
            if [ "$response_code" == "200" -o "$response_code" == "404" ];then
               break
            fi
         done
         if [ "$response_code" != "200" -a "$response_code" != "404" ];then
            echo "[Error]: Delete pod $unhealthy_pod failed!"
         fi
      done
   exit 1
   fi
else #already isolated
    echo "[Info]: $pod_name is isolated"
    exit 1
fi
