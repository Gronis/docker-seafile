#!/bin/bash

DATADIR=${DATADIR:-"/seafile"}
BASEPATH=${BASEPATH:-"/opt/haiwen"}
INSTALLPATH=${INSTALLPATH:-"${BASEPATH}/$(ls -1 ${BASEPATH} | grep -E '^seafile-server-[0-9.-]+')"}
VERSION=$(echo $INSTALLPATH | grep -oE [0-9.]+)
OLD_VERSION=$(cat $DATADIR/version 2> /dev/null || echo $VERSION)
MAJOR_VERSION=$(echo $VERSION | cut -d. -f 1-2)
OLD_MAJOR_VERSION=$(echo $OLD_VERSION | cut -d. -f 1-2)
VIRTUAL_PORT=${VIRTUAL_PORT:-"8000"}

python3 --version
ldd --version
ls ${BASEPATH}/ccnet


set -e
set -u
set -o pipefail

trapped() {
  control_seahub "stop"
  control_seafile "stop"
}

autorun() {
  # Update if neccessary
  if [ $OLD_VERSION != $VERSION ]; then
    full_update
  fi
  echo $VERSION > $DATADIR/version
  # Needed to check the return code
  set +e
  control_seafile "start"
  local RET=$?
  set -e
  # Try an initial setup on error
  if [ ${RET} -eq 255 ]
  then
    choose_setup
    control_seafile "start"
  elif [ ${RET} -gt 0 ]
  then
    exit 1
  fi

  update_gunicorn_config
  update_seahub_config

  if [ ${SEAFILE_FASTCGI:-} ]
  then
    control_seahub "start-fastcgi"
  else
    control_seahub "start"
  fi
  keep_in_foreground
}

run_only() {
  local SH_DB_DIR="${DATADIR}/${SEAHUB_DB_DIR}"
  control_seafile "start"
  control_seahub "start"
  keep_in_foreground
}

choose_setup() {
  set +u
  # If $MYSQL_SERVER is set, we assume MYSQL setup is intended,
  # otherwise sqlite
  if [ -n "${MYSQL_SERVER}" ]
  then
    set -u
    setup_mysql
  else
    set -u
    setup_sqlite
  fi

}

setup_mysql() {
  echo "setup_mysql"

  # Wait for MySQL to boot up
  DOCKERIZE_TIMEOUT=${DOCKERIZE_TIMEOUT:-"60s"}
  dockerize -timeout ${DOCKERIZE_TIMEOUT} -wait tcp://${MYSQL_SERVER}:${MYSQL_PORT:-3306}

  set +u
  OPTIONAL_PARMS="$([ -n "${MYSQL_ROOT_PASSWORD}" ] && printf '%s' "-r ${MYSQL_ROOT_PASSWORD}")"
  set -u

  su - seafile -c  ". /tmp/seafile.env; ${INSTALLPATH}/setup-seafile-mysql.sh auto \
    -n "${SEAFILE_NAME}" \
    -i "${SEAFILE_ADDRESS}" \
    -p "${SEAFILE_PORT}" \
    -d "${SEAFILE_DATA_DIR}" \
    -o "${MYSQL_SERVER}" \
    -t "${MYSQL_PORT:-3306}" \
    -u "${MYSQL_USER}" \
    -w "${MYSQL_USER_PASSWORD}" \
    -q "${MYSQL_USER_HOST:-"%"}" \
    ${OPTIONAL_PARMS}"

  setup_seahub
  move_and_link
}

setup_sqlite() {
  echo "setup_sqlite"
  # Setup Seafile
  su - seafile -c  ". /tmp/seafile.env; ${INSTALLPATH}/setup-seafile.sh auto \
    -n "${SEAFILE_NAME}" \
    -i "${SEAFILE_ADDRESS}" \
    -p "${SEAFILE_PORT}" \
    -d "${SEAFILE_DATA_DIR}""

  setup_seahub
  move_and_link
}

setup_seahub() {
  # Setup Seahub

  # From https://github.com/haiwen/seafile-server-installer-cn/blob/master/seafile-server-ubuntu-14-04-amd64-http
  sed -i 's/= ask_admin_email()/= '"\"${SEAFILE_ADMIN}\""'/' ${INSTALLPATH}/check_init_admin.py
  sed -i 's/= ask_admin_password()/= '"\"${SEAFILE_ADMIN_PW}\""'/' ${INSTALLPATH}/check_init_admin.py

  control_seafile "start"

  su - seafile -c  ". /tmp/seafile.env; python3 -t ${INSTALLPATH}/check_init_admin.py"
  # su - seafile -c ". /tmp/seafile.env; python3 -m trace -t ${INSTALLPATH}/check_init_admin.py | tee -a /seafile/check_init_admin.log"
}

move_and_link() {
  # As seahub.db is normally in the root dir of seafile (/opt/haiwen)
  # SEAHUB_DB_DIR needs to be defined if it should be moved elsewhere under /seafile
  local SH_DB_DIR="${DATADIR}/${SEAHUB_DB_DIR}"
  # Stop Seafile/hub instances if running
  control_seahub "stop"
  control_seafile "stop"

  move_files "${SH_DB_DIR}"
  link_files "${SH_DB_DIR}"

  if ! su - seafile -c "test -w ${DATADIR}"; then
    echo "Updating file permissions"
    chown -R seafile:seafile ${DATADIR}/
  fi
}

update_config() {
  VARIABLE_NAME=$1
  CONFIG_FILE=$2
  if [ $# -ge 3 ]; then
    VARIABLE_VALUE=$3
  else
    # Grab variable value from environment if not passed as argument.
    set +e
    env | grep $VARIABLE_NAME > /dev/null
    EXISTS_IN_ENV=$?
    set -e
    if [[ $EXISTS_IN_ENV -ne 0 ]]; then
      # Not passed as argument and not in env, no configuration needed.
      return
    fi
    VARIABLE_VALUE=$(env | grep $VARIABLE_NAME | sed "s/${VARIABLE_NAME}=//g")
  fi
  echo "Updating $VARIABLE_NAME in $CONFIG_FILE."
  ESCAPED_VALUE=$(printf '%s\n' "$VARIABLE_VALUE" | sed -e 's/[\/&]/\\&/g')
  set +e
  grep $VARIABLE_NAME $CONFIG_FILE > /dev/null
  EXISTS=$?
  set -e
  if [[ "${EXISTS}" -eq 0 ]]; then
    OLD="$VARIABLE_NAME = .*$"
    NEW="$VARIABLE_NAME = \"${ESCAPED_VALUE}\""
  sed -i "s/${OLD}/${NEW}/g" $CONFIG_FILE
  else
    NEW="$VARIABLE_NAME = \"${VARIABLE_VALUE}\""
    echo ${NEW} >> $CONFIG_FILE
  fi
}


update_gunicorn_config() {
  # Must bind 0.0.0.0 instead of 127.0.0.1
  CONFIG_FILE=/seafile/conf/gunicorn.conf.py
  update_config "bind" $CONFIG_FILE "0.0.0.0:${VIRTUAL_PORT}"
}

update_seahub_config(){
  CONFIG_FILE=/seafile/conf/seahub_settings.py
  update_config "FILE_SERVER_ROOT" $CONFIG_FILE
  update_config "SERVICE_URL" $CONFIG_FILE
}

move_files() {
  MOVE_LIST=(
    "${BASEPATH}/ccnet:${DATADIR}/ccnet"
    "${BASEPATH}/conf:${DATADIR}/conf"
    "${BASEPATH}/seafile-data:${DATADIR}/seafile-data"
    "${BASEPATH}/seahub-data:${DATADIR}/seahub-data"
    "${INSTALLPATH}/seahub/media/avatars:${DATADIR}/seahub-data/avatars"
  )
  for SEADIR in ${MOVE_LIST[@]}
  do
    ARGS=($(echo $SEADIR | tr ":" "\n"))
    if [ -e "${ARGS[0]}" ] && [ ! -e "${ARGS[1]}" ]
    then
      echo "Copying ${ARGS[0]} => ${ARGS[1]}"
      local PARENT=$(dirname ${ARGS[1]})
      if [ ! -e $PARENT ]
      then
        mkdir -p $PARENT
      fi
      cp -a ${ARGS[0]}/ ${ARGS[1]}
    fi
    if [ -e "${ARGS[0]}" ] && [ ! -L "${ARGS[0]}" ]
    then
      echo "Dropping ${ARGS[0]}"
      rm -rf ${ARGS[0]}
    fi
  done

  if [ -e "${BASEPATH}/seahub.db" -a ! -L "${BASEPATH}/seahub.db" ]
  then
    mv ${BASEPATH}/seahub.db ${1}/
  fi
}

link_files() {
  LINK_LIST=(
    "${DATADIR}/ccnet:${BASEPATH}/ccnet"
    "${DATADIR}/conf:${BASEPATH}/conf"
    "${DATADIR}/seafile-data:${BASEPATH}/seafile-data"
    "${DATADIR}/seahub-data:${BASEPATH}/seahub-data"
    "${DATADIR}/seahub-data/avatars:${INSTALLPATH}/seahub/media/avatars"
  )
  for SEADIR in ${LINK_LIST[@]}
  do
    ARGS=($(echo $SEADIR | tr ":" "\n"))
    if [ -e "${ARGS[0]}" ]
    then
      echo "Linking ${ARGS[1]} => ${ARGS[0]}"
      su - seafile -c "ln -sf ${ARGS[0]} ${ARGS[1]}"
    fi
  done
  if [ -e "${SH_DB_DIR}/seahub.db" -a ! -L "${BASEPATH}/seahub.db" ]
  then
    ln -s ${1}/seahub.db ${BASEPATH}/seahub.db
  fi

}

keep_in_foreground() {
  # As there seems to be no way to let Seafile processes run in the foreground we
  # need a foreground process. This has a dual use as a supervisor script because
  # as soon as one process is not running, the command returns an exit code >0
  # leading to a script abortion thanks to "set -e".
  while true
  do
    for SEAFILE_PROC in "seafile-control" "seaf-server" "gunicorn"
    do
      pkill -0 -f "${SEAFILE_PROC}"
      sleep 1
    done
    sleep 5
  done
}

prepare_env() {
  cat << _EOF_ > /tmp/seafile.env
  export LANG='en_US.UTF-8'
  export LC_ALL='en_US.UTF-8'
  export CCNET_CONF_DIR="${BASEPATH}/ccnet"
  export SEAFILE_CONF_DIR="${SEAFILE_DATA_DIR}"
  export SEAFILE_CENTRAL_CONF_DIR="${BASEPATH}/conf"
  export PYTHONPATH=${INSTALLPATH}/seafile/lib/python3.6/site-packages:${INSTALLPATH}/seafile/lib64/python3.6/site-packages:${INSTALLPATH}/seahub:${INSTALLPATH}/seahub/thirdpart:${INSTALLPATH}/seafile/lib/python3.6/site-packages:${INSTALLPATH}/seafile/lib64/python3.6/site-packages:${PYTHONPATH:-}

_EOF_
}

control_seafile() {
  su - seafile -c ". /tmp/seafile.env; ${INSTALLPATH}/seafile.sh "$@""
  local RET=$?
  if [ $RET -gt 0 ]; then
    print_log
  fi
  return ${RET}
}

control_seahub() {
  su - seafile -c ". /tmp/seafile.env; ${INSTALLPATH}/seahub.sh "$@""
  local RET=$?
  if [ $RET -gt 0 ]; then
    print_log
  fi
  return ${RET}
}

print_log() {
    if [ -e $INSTALLPATH/../logs ]
    then
      sleep 2
      echo ""
      echo "---------------------------------------"
      echo "seafile.log:"
      echo "---------------------------------------"
      cat $INSTALLPATH/../logs/seafile.log
      echo ""
      echo "---------------------------------------"
      echo "controller.log:"
      echo "---------------------------------------"
      cat $INSTALLPATH/../logs/controller.log
      echo ""
      echo "---------------------------------------"
      echo "ccnet.log:"
      echo "---------------------------------------"
      cat $INSTALLPATH/../logs/ccnet.log
    fi
}

full_update(){
  EXECUTE=""
  echo ""
  echo "---------------------------------------"
  echo "Upgrading from $OLD_VERSION to $VERSION"
  echo "---------------------------------------"
  echo ""
  # Iterate through all the major upgrade scripts and apply them
  for i in `ls ${INSTALLPATH}/upgrade/`; do
    if [ `echo $i | grep "upgrade_${OLD_MAJOR_VERSION}"` ]; then
      EXECUTE=1
    fi
    if [ $EXECUTE ] && [ `echo $i | grep upgrade` ]; then
      echo "Running update $i"
      update $i || exit
    fi
  done
  # When all the major upgrades are done, perform a minor upgrade
  if [ -z $EXECUTE ]; then
    update minor-upgrade.sh
    echo $VERSION > $DATADIR/version
  fi
}

update(){
  su - seafile -c ". /tmp/seafile.env; echo -ne '\n' | ${INSTALLPATH}/upgrade/$@"
  local RET=$?
  sleep 1
  return ${RET}
}

collect_garbage(){
  su - seafile -c ". /tmp/seafile.env; ${INSTALLPATH}/seaf-gc.sh $@"
  local RET=$?
  sleep 1
  return ${RET}
}

diagnose(){
  su - seafile -c ". /tmp/seafile.env; ${INSTALLPATH}/seaf-fsck.sh $@"
  local RET=$?
  sleep 1
  return ${RET}
}

maintenance(){
  local SH_DB_DIR="${DATADIR}/${SEAHUB_DB_DIR}"
  # Linking must always be done
  link_files "${SH_DB_DIR}"
  echo ""
  echo "---------------------------------------"
  echo "Running in maintenance mode"
  echo "---------------------------------------"
  echo ""
  tail -f /dev/null
}


# Fill vars with defaults if empty
if [ -z ${MODE+x} ]; then
  MODE=${1:-"run"}
fi

SEAFILE_DATA_DIR=${SEAFILE_DATA_DIR:-"${DATADIR}/seafile-data"}
SEAFILE_PORT=${SEAFILE_PORT:-8082}
SEAHUB_DB_DIR=${SEAHUB_DB_DIR:-}

prepare_env

trap trapped SIGINT SIGTERM
move_and_link
case $MODE in
  "autorun" | "run")
    autorun
  ;;
  "setup" | "setup_mysql")
    setup_mysql
  ;;
  "setup_sqlite")
    setup_sqlite
  ;;
  "setup_seahub")
    setup_seahub
  ;;
  "setup_only")
    choose_setup
  ;;
  "run_only")
    run_only
  ;;
  "update")
    full_update
  ;;
  "diagnose")
    diagnose
  ;;
  "collect_garbage")
    collect_garbage
  ;;
  "maintenance")
    maintenance
  ;;
esac
