#!/bin/bash

usage() {
  >&2 echo "Usage: restore.sh <path_to_archive_to_restore> <target_path> [components_to_strip]"
  >&2 echo "For example:"
  >&2 echo "restore.sh /archive/backup.tar.gz /backup/grafana-data 2"
  >&2 echo ""
}

if [ $# -lt 2 ]; then
    usage
    exit 2
fi

ARCHIVE_PATH=$1
RESTORE_TARGET=$2
strip_n=$3
COMPONENTS_TO_STRIP=${strip_n:-0}

if ! [ -e $ARCHIVE_PATH ]; then
    >&2 echo "Archive file $ARCHIVE_PATH does not exist"
    exit 3
fi

function info {
  bold="\033[1m"
  reset="\033[0m"
  echo -e "\n$bold[INFO] $1$reset\n"
}

read -p "This operation will remove everything under $RESTORE_TARGET. This operation is DESTRUCTIVE and cannot be undone. Are you sure (y/N)? " -n 1 -r
echo    # (optional) move to a new line
if [[ $REPLY =~ ^[Yy]$ ]]
then
    >&2 echo "Restoration confirmed. Let's continue..."
else 
    >&2 echo "Restore procedure cancelled!"
    exit 1
fi


info "Restore starting"
TIME_START="$(date +%s.%N)"
DOCKER_SOCK="/var/run/docker.sock"
BACKUP_WAIT_SECONDS=0

if [ -S "$DOCKER_SOCK" ]; then
  # Containers to stop
  TEMPFILE="$(mktemp)"
  docker ps --format "{{.ID}}" --filter "label=docker-volume-backup.stop-during-restore=true" > "$TEMPFILE"
  CONTAINERS_TO_STOP="$(cat $TEMPFILE | tr '\n' ' ')"
  CONTAINERS_TO_STOP_TOTAL="$(cat $TEMPFILE | wc -l)"
  CONTAINERS_TOTAL="$(docker ps --format "{{.ID}}" | wc -l)"
  rm "$TEMPFILE"
  echo "$CONTAINERS_TOTAL containers running on host in total"
  echo "$CONTAINERS_TO_STOP_TOTAL containers marked to be stopped during restore"

  # Services to stop
  TEMPFILE="$(mktemp)"
  docker service ls --format "{{.ID}}" --filter "label=docker-volume-backup.stop-during-restore=true" > "$TEMPFILE"
  SERVICES_TO_STOP="$(cat $TEMPFILE | tr '\n' ' ')"
  SERVICES_TO_STOP_TOTAL="$(cat $TEMPFILE | wc -l)"
  SERVICES_TOTAL="$(docker service ls --format "{{.ID}}" | wc -l)"
  rm "$TEMPFILE"
  echo "$SERVICES_TOTAL services running on host in total"
  echo "$SERVICES_TO_STOP_TOTAL services marked to be stopped during restore"

else
  CONTAINERS_TO_STOP_TOTAL="0"
  CONTAINERS_TOTAL="0"
  echo "Cannot access \"$DOCKER_SOCK\", won't look for containers or services to stop"
fi

if [ "$CONTAINERS_TO_STOP_TOTAL" != "0" ]; then
  info "Stopping containers"
  docker stop $CONTAINERS_TO_STOP
fi

if [ "$SERVICES_TO_STOP_TOTAL" != "0" ]; then
  info "Stopping services"
  for SERVICE in ${SERVICES_TO_STOP[@]}
  do
    docker service update --replicas 0 $SERVICE
  done
fi

info "Restoring backup"
TIME_RESTORE="$(date +%s.%N)"
RESTORE_SIZE="$(du --bytes $RESTORE_FILENAME | sed 's/\s.*$//')"


#TODO Support restoring to multiple destinations. 
# For now only one dest is supported, so all the volumes should me monted into the same location during backup
rm -rf $RESTORE_TARGET/..?* $RESTORE_TARGET/.[!.]* $RESTORE_TARGET/*
tar -C $RESTORE_TARGET/ -xzvf $ARCHIVE_PATH --strip-components=$COMPONENTS_TO_STRIP

TIME_RESTORED="$(date +%s.%N)"

if [ "$CONTAINERS_TO_STOP_TOTAL" != "0" ]; then
  info "Starting containers back up"
  docker start $CONTAINERS_TO_STOP
fi

if [ "$SERVICES_TO_STOP_TOTAL" != "0" ]; then
  info "Starting services back up"
  for SERVICE in ${SERVICES_TO_STOP[@]}
  do
    docker service update --replicas 1 $SERVICE
  done
fi

info "Collecting metrics"
TIME_FINISH="$(date +%s.%N)"
INFLUX_LINE="$INFLUXDB_MEASUREMENT\
,host=$BACKUP_HOSTNAME\
\
 size_compressed_bytes=$RESTORE_SIZE\
,containers_total=$CONTAINERS_TOTAL\
,containers_stopped=$CONTAINERS_TO_STOP_TOTAL\
,time_wall=$(perl -E "say $TIME_FINISH - $TIME_START")\
,time_total=$(perl -E "say $TIME_FINISH - $TIME_START - $BACKUP_WAIT_SECONDS")\
,time_compress=$(perl -E "say $TIME_RESTORED - $TIME_RESTORE")\
"
echo "$INFLUX_LINE" | sed 's/ /,/g' | tr , '\n'

if [ ! -z "$INFLUXDB_URL" ]; then
  info "Shipping metrics"
  curl \
    --silent \
    --include \
    --request POST \
    --user "$INFLUXDB_CREDENTIALS" \
    "$INFLUXDB_URL/write?db=$INFLUXDB_DB" \
    --data-binary "$INFLUX_LINE"
fi

info "Restore finished"
