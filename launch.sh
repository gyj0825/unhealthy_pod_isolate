#!/bin/sh

. /usr/local/dynamic-resources/dynamic_resources.sh

# Arguments:
# $1 - datasource jndi name
# $2 - datasource username
# $3 - datasource password
# $4 - datasource driver
# $5 - datasource url
function generate_datasource() {
  ds="    <Resource name=\"$1\" auth=\"Container\" type=\"javax.sql.DataSource\" username=\"$2\" password=\"$3\" driverClassName=\"$4\" url=\"$5\"  validationQuery=\"SELECT 1\" testWhenIdle=\"true\" testOnBorrow=\"true\" factory=\"org.apache.tomcat.jdbc.pool.DataSourceFactory\""
  if [ -n "$tx_isolation" ]; then
    ds="$ds defaultTransactionIsolation=\"$tx_isolation\""
  fi
  if [ -n "$min_Idle" ]; then
    ds="$ds minIdle=\"$min_Idle\""
  fi
  if [ -n "$max_Idle" ]; then
    ds="$ds maxIdle=\"$max_Idle\""
  fi
  if [ -n "$max_Active" ]; then
    ds="$ds maxActive=\"$max_Active\""
  fi
  if [ -n "$max_Wait" ]; then
    ds="$ds maxWait=\"$max_Wait\""
  fi
  if [ -n "$min_Evictable_Idle_TimeMillis" ]; then
    ds="$ds minEvictableIdleTimeMillis=\"$min_Evictable_Idle_TimeMillis\""
  fi
  if [ -n "$time_Between_Eviction_RunsMillis" ]; then
    ds="$ds timeBetweenEvictionRunsMillis=\"$time_Between_Eviction_RunsMillis\""
  fi
  if [ -n "$remove_Abandoned" ]; then
    ds="$ds removeAbandoned=\"$remove_Abandoned\""
  fi
  if [ -n "$remove_Abandoned_Timeout" ]; then
    ds="$ds removeAbandonedTimeout=\"$remove_Abandoned_Timeout\""
  fi
  ds="$ds />"

  echo "$ds"
}

# Finds the environment variable  and returns its value if found.
# Otherwise returns the default value if provided.
#
# Arguments:
# $1 env variable name to check
# $2 default value if environemnt variable was not set
function find_env() {
  var=`printenv "$1"`
  
  # If environment variable exists
  if [ -n "$var" ]; then
    echo $var
  else
    echo $2
  fi
}

# Finds the name of the database services and generates data sources
# based on this info
function inject_datasources() {
  datasources=""

  # Find all databases in the $DB_SERVICE_PREFIX_MAPPING separated by ","
  IFS=',' read -a db_backends <<< $DB_SERVICE_PREFIX_MAPPING

  for db_backend in ${db_backends[@]}; do

    service_name=${db_backend%=*}
    service=${service_name^^}
    service=${service//-/_}
    db=${service##*_}
    prefix=${db_backend#*=}

    host=$(find_env "${service}_SERVICE_HOST")
    port=$(find_env "${service}_SERVICE_PORT")

    if [ "$db" = "MYSQL" ] || [ "$db" = "POSTGRESQL" ] || [ "$db" = "ORACLE" ]; then
      configurable_db=true
    else
      configurable_db=false
    fi

    if [ "$configurable_db" = true ]; then
      if [ -z $host ] || [ -z $port ]; then
        echo "There is a problem with your service configuration!"
        echo "You provided following database mapping (via DB_SERVICE_PREFIX_MAPPING environment variable): $db_backend. To configure datasources we expect ${service}_SERVICE_HOST and ${service}_SERVICE_PORT to be set."
        echo
        echo "Current values:"
        echo
        echo "${service}_SERVICE_HOST: $host"
        echo "${service}_SERVICE_PORT: $port"
        echo
        echo "Please make sure you provided correct service name and prefix in the mapping. Additionally please check that you do not set portalIP to None in the $service_name service. Headless services are not supported at this time."
        echo
        echo "WARNING! The ${db,,} datasource for $prefix service WILL NOT be configured."
        continue
      fi

      # Custom JNDI environment variable name format: [NAME]_[DATABASE_TYPE]_JNDI
      jndi=$(find_env "${prefix}_JNDI" "jboss/datasources/${service,,}")

      # Database username environment variable name format: [NAME]_[DATABASE_TYPE]_USERNAME
      username=$(find_env "${prefix}_USERNAME")

      # Database password environment variable name format: [NAME]_[DATABASE_TYPE]_PASSWORD
      password=$(find_env "${prefix}_PASSWORD")

      # Database name environment variable name format: [NAME]_[DATABASE_TYPE]_DATABASE
      database=$(find_env "${prefix}_DATABASE")

      if [ -z $jndi ] || [ -z $username ] || [ -z $password ] || [ -z $database ]; then
        echo "Ooops, there is a problem with the ${db,,} datasource!"
        echo "In order to configure ${db,,} datasource for $prefix service you need to provide following environment variables: ${prefix}_USERNAME, ${prefix}_PASSWORD, ${prefix}_DATABASE."
        echo
        echo "Current values:"
        echo
        echo "${prefix}_USERNAME: $username"
        echo "${prefix}_PASSWORD: $password"
        echo "${prefix}_DATABASE: $database"
        echo
        echo "WARNING! The ${db,,} datasource for $prefix service WILL NOT be configured."
        continue
      fi

      # Transaction isolation level environment variable name format: [NAME]_[DATABASE_TYPE]_TX_ISOLATION
      tx_isolation=$(find_env "${prefix}_TX_ISOLATION")

      # min pool size environment variable name format: [NAME]_[DATABASE_TYPE]_MIN_IDLE
      min_Idle=$(find_env "${prefix}_MIN_IDLE" 1)

      # max pool size environment variable name format: [NAME]_[DATABASE_TYPE]_MIN_IDLE
      max_Idle=$(find_env "${prefix}_MAX_IDLE" 5)

      # max active pool size environment variable name format: [NAME]_[DATABASE_TYPE]_MAX_ACTIVE
      max_Active=$(find_env "${prefix}_MAX_ACTIVE" 5)

      # min wait time environment variable name format: [NAME]_[DATABASE_TYPE]_MAX_WAIT
      max_Wait=$(find_env "${prefix}_MAX_WAIT" 5000)

      min_Evictable_Idle_TimeMillis=$(find_env "${prefix}_MIN_EVICTABLE_IDLE_TIMEMILLIS" 30000)
      time_Between_Eviction_RunsMillis=$(find_env "${prefix}_TIME_BETWEEN_EVICTION_RUNMILLIS" 30000)
      remove_Abandoned=$(find_env "${prefix}_REMOVE_ABANDONED" true)
      remove_Abandoned_Timeout=$(find_env "${prefix}_REMOVE_ABANDONED_TIMEOUT" 30)

      url="jdbc:${db,,}://$(find_env "${service}_SERVICE_HOST"):$(find_env "${service}_SERVICE_PORT")/$database"

      if [ "$db" = "MYSQL" ]; then
        driver="com.mysql.jdbc.Driver"
      elif [ "$db" = "POSTGRESQL" ]; then
        driver="org.postgresql.Driver"
      elif [ "$db" = "ORACLE" ]; then
        driver="oracle.jdbc.driver.OracleDriver"
	url="jdbc:oracle:thin:@(description=(address=(host=$(find_env "${service}_SERVICE_HOST"))(protocol=tcp)(port=$(find_env "${service}_SERVICE_PORT")))(connect_data=(service_name=$database)))" 
      fi

      datasources="$datasources$(generate_datasource $jndi $username $password $driver $url)\n\n"
    fi
  done

  sed -i "s|<!-- ##DATASOURCES## -->|$datasources|" $JWS_HOME/conf/context.xml
}

function configure_administration() {
  if [ -n "${JWS_ADMIN_PASSWORD+_}" ]; then
      # default management username 'jwsadmin'
      JWS_ADMIN_USERNAME=${JWS_ADMIN_USERNAME:-jwsadmin}
      sed -i "/username=\"${JWS_ADMIN_USERNAME}\"/d" $JWS_HOME/conf/tomcat-users.xml
      sed -i -e"s#</tomcat-users>#\n<user username=\"${JWS_ADMIN_USERNAME}\" password=\"${JWS_ADMIN_PASSWORD}\" roles=\"manager-jmx,manager-script\"/>\n</tomcat-users>#" $JWS_HOME/conf/tomcat-users.xml
  fi
}

function configure_https() {
  https="<!-- No HTTPS configuration discovered -->"
  if [ -n "${JWS_HTTPS_CERTIFICATE_DIR}" -a -n "${JWS_HTTPS_CERTIFICATE}" -a -n "${JWS_HTTPS_CERTIFICATE_KEY}" ] ; then
      password=""
      if [ -n "${JWS_HTTPS_CERTIFICATE_PASSWORD}" ] ; then
          password=" SSLPassword=\"${JWS_HTTPS_CERTIFICATE_PASSWORD}\" "
      fi
      https="<Connector \
             protocol=\"org.apache.coyote.http11.Http11AprProtocol\" \
             port=\"8443\" maxThreads=\"200\" \
             scheme=\"https\" secure=\"true\" SSLEnabled=\"true\" \
             SSLCertificateFile=\"${JWS_HTTPS_CERTIFICATE_DIR}/${JWS_HTTPS_CERTIFICATE}\" \
             SSLCertificateKeyFile=\"${JWS_HTTPS_CERTIFICATE_DIR}/${JWS_HTTPS_CERTIFICATE_KEY}\" \
             ${password}  \
             SSLVerifyClient=\"optional\" SSLProtocol=\"TLSv1+TLSv1.1+TLSv1.2\"/>"
  elif [ -n "${JWS_HTTPS_CERTIFICATE_DIR}" -o -n "${JWS_HTTPS_CERTIFICATE}" -o -n "${JWS_HTTPS_CERTIFICATE_KEY}" ] ; then
      echo "WARNING! Partial HTTPS configuration, the https connector WILL NOT be configured."
  fi
  sed -i "s|### HTTPS_CONNECTOR ###|${https}|" $JWS_HOME/conf/server.xml
}

# user-overrideable, defaults to jdbc/auth
JWS_REALM_DATASOURCE_NAME="${JWS_REALM_DATASOURCE_NAME:-jdbc/auth}"

configure_realms() {
  realms="<!-- no additional realms configured -->"
  if [ -n "$JWS_REALM_USERTABLE" -a -n "$JWS_REALM_USERNAME_COL" -a -n "$JWS_REALM_USERCRED_COL" -a -n "$JWS_REALM_USERROLE_TABLE" -a -n "$JWS_REALM_ROLENAME_COL" ]; then
      realms="<Realm \
        className=\"org.apache.catalina.realm.DataSourceRealm\"\
        userTable=\"$JWS_REALM_USERTABLE\"\
        userNameCol=\"$JWS_REALM_USERNAME_COL\"\
        userCredCol=\"$JWS_REALM_USERCRED_COL\"\
        userRoleTable=\"$JWS_REALM_USERROLE_TABLE\"\
        roleNameCol=\"$JWS_REALM_ROLENAME_COL\"\
        dataSourceName=\"$JWS_REALM_DATASOURCE_NAME\"\
        localDataSource=\"true\"\
      />" # ^ must match a Resource definition. TODO: check that there is one.
  elif [ -n "$JWS_REALM_USERTABLE" -o -n "$JWS_REALM_USERNAME_COL" -o -n "$JWS_REALM_USERCRED_COL" -o -n "$JWS_REALM_USERROLE_TABLE" -o -n "$JWS_REALM_ROLENAME_COL" ]; then
      echo "WARNING! Partial Realm configuration, additional realms WILL NOT be configured."
  fi
  sed -i "s|<!--### ADDITIONAL_REALMS ###-->|$realms|" $JWS_HOME/conf/server.xml
}

expand_catalina_opts() {
    CATALINA_OPTS="$CATALINA_OPTS $CATALINA_OPTS_APPEND -javaagent:$JWS_HOME/lib/jolokia.jar=port=8778,protocol=https,caCert=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt,clientPrincipal=cn=system:master-proxy,useSslClientAuthentication=true,extraClientCheck=true,host=0.0.0.0,discoveryEnabled=false"
    
    MAX_HEAP=`get_heap_size`
    if [ -n "$MAX_HEAP" ]; then
      CATALINA_OPTS="$CATALINA_OPTS -Xms${MAX_HEAP}m -Xmx${MAX_HEAP}m"
    fi

    export CATALINA_OPTS
}

#generate server config of tomcat
# Arguments:
# $1 - server port
# $2 - server connectionTimeout
# $3 - server redirectPort
# $4 - server protocol
function generate_server() {
  server="  <Connector port=\"$1\" connectionTimeout=\"$2\" redirectPort=\"$3\" protocol=\"$4\""
  if [ -n "$max_Threads" ]; then
     server="$server maxThreads=\"$max_Threads\""
  fi
  if [ -n "$min_Spare_Threads" ]; then
     server="$server minSpareThreads=\"$min_Spare_Threads\""
  fi
  if [ -n "$accept_Count" ]; then
     server="$server acceptCount=\"$accept_Count\""
  fi
  if [ -n "$append_Option" ]; then
     server="$server $append_Option"
  fi
  server="$server />"
  echo "$server"
}

# change server.xml
function set_server_conf() {

# set server vars prefix, may support multiple ports future
serverprefix=SERVER

# Set the basic parameters
port=$(find_env "${serverprefix}_PORT" "8080")
protocol=$(find_env "${serverprefix}_PROTOCOL" "org.apache.coyote.http11.Http11NioProtocol")
connection_Timeout=$(find_env "${serverprefix}_CONNECTION_TIMEOUT" "10000")
redirect_Port=$(find_env "${serverprefix}_REDIRECT_PORT" "8443")

# Set up additional parameters
max_Threads=$(find_env "${serverprefix}_MAX_THREADS")
min_Spare_Threads=$(find_env "${serverprefix}_MIN_SPARE_THREADS")
accept_Count=$(find_env "${serverprefix}_ACCEPT_COUNT")

# Users can customize additional parameters,format: parameters_name=\"parameters_value\",Multiple parameters are separated with Spaces
append_Option=$(find_env "${serverprefix}_APPEND_OPTION")

# change server.xml
dataserver=$(generate_server $port $connection_Timeout $redirect_Port $protocol)

# Determine the number,then change server.xml
mark72=`sed -n '72p' $JWS_HOME/conf/server.xml | grep connectionTimeout | wc -l`
mark73=`sed -n '73p' $JWS_HOME/conf/server.xml | grep redirectPort | wc -l`
sign=`expr $mark72 \* $mark73`
if [ "$sign" == "1" ];then
  sed -i '72,73d' $JWS_HOME/conf/server.xml
  sed -i "s#<Connector port=\"8080\" protocol=\"HTTP/1.1\"#${dataserver}#" $JWS_HOME/conf/server.xml
else
  selectdata=`sed -n '71p' $JWS_HOME/conf/server.xml`
  sed -i "s#${selectdata}#${dataserver}#" $JWS_HOME/conf/server.xml
fi

echo "Tomcat server used the '$protocol' protocol running on port '$port'."
}

war_deploy() {
  echo "WAR_URI: $WAR_URI"
  if [ "x" != "x$WAR_URI" ]; then
    PKG_NAME=`basename $WAR_URI`
    echo ">> Downloading WAR [$WAR_URI]"
    curl -v $WAR_URI -o $JWS_HOME/webapps/$PKG_NAME
  else
    echo ">> \$WAR_URI is empty, skip download WAR"
  fi
}

change_unset_file() {
  for i in "$@"
  do
    var=`printenv "$i"`
    if [ -n "$var" ];then
      state=`grep "unset $i" ~/.bashrc | wc -l`
      if [ "$state" = "0" ];then
        sed -i '$a unset '$i'' ~/.bashrc
      fi
    fi
  done
}

unset_env() {
  all_vars="${ALL_UNSET_VARS}"
  if [ -n "$all_vars" ];then
    change_unset_file $all_vars
  fi
}


war_deploy
inject_datasources
set_server_conf
configure_administration
configure_https
configure_realms
expand_catalina_opts
unset_env

echo "Running $JBOSS_IMAGE_NAME image, version $JBOSS_IMAGE_VERSION-$JBOSS_IMAGE_RELEASE"

exec $JWS_HOME/bin/catalina.sh run
