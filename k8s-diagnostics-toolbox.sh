#!/bin/bash
# Tool for diagnosing k8s containers on a k8s node
# Uses crictl from https://github.com/kubernetes-sigs/cri-tools/releases to inspect the containers
# tested with microk8s, which uses containerd
#
# Downloads crictl, async-profiler and jattach automatically and stores to ~/.cache/k8s-diagnostics-toolbox directory
# jattach is used for triggering threaddumps and heapdumps and controlling Java Flight Recorder (jfr)
# async-profiler can be used to profile Java processes running in a container
#
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

function diag_nsenter() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Uses nsenter to run a program in the pod's OS namespace"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_nsenter [pod_name]"
    fi
    return 0
  fi
  local PODNAME="$1"
  shift
  local CONTAINER="$(_diag_find_container $PODNAME)"
  [ -n "$CONTAINER" ] || return 1
  local CONTAINER_PID="$(_diag_find_container_pid $CONTAINER)"
  [ -n "$CONTAINER_PID" ] || return 2
  nsenter -t "$CONTAINER_PID" "$@"
}

function diag_shell() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Get a root shell inside the pod"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_shell [pod_name]"
    fi
    return 0
  fi
  local PODNAME="$1"
  shift
  diag_nsenter "$PODNAME" --all "$@"
}

function diag_netstat_all() {
  if [ "$1" == "--desc" ]; then
    echo "Run netstat for all containers."
    return 0
  fi
  ip -all netns exec bash -c "ip a; netstat -tapn"
}

function diag_jattach() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Run jattach for the initial pid of the pod"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_jattach [pod_name]"
    fi
    return 0
  fi
  local PODNAME="$1"
  shift
  local CONTAINER="$(_diag_find_container $PODNAME)"
  [ -n "$CONTAINER" ] || return 1
  _diag_jattach_container "$CONTAINER"
}

function diag_get_heapdump() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Gets a heapdump for the pod's initial pid"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_get_heapdump [pod_name]"
    fi
    return 0
  fi
  local PODNAME="$1"
  shift
  local CONTAINER="$(_diag_find_container $PODNAME)"
  [ -n "$CONTAINER" ] || return 1
  local ROOT_PATH=$(_diag_find_root_path $CONTAINER)
  [ -n "$ROOT_PATH" ] || return 2
  _diag_jattach_container $CONTAINER dumpheap /tmp/heapdump.hprof
  [ $? -eq 0 ] || return 3
  local HEAPDUMP_FILE="heapdump_${PODNAME}_$(date +%F-%H%M%S).hprof"
  mv $ROOT_PATH/tmp/heapdump.hprof "${HEAPDUMP_FILE}"
  [ -f "${HEAPDUMP_FILE}" ] || return 4
  _diag_chown_sudo_user "${HEAPDUMP_FILE}"
  echo "${HEAPDUMP_FILE}"
}

function diag_get_threaddump() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Gets a threaddump for the pod's initial pid"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_get_threaddump [pod_name]"
    fi
    return 0
  fi
  local PODNAME="$1"
  shift
  local CONTAINER="$(_diag_find_container $PODNAME)"
  [ -n "$CONTAINER" ] || return 1
  _diag_jattach_container $CONTAINER threaddump -l
}

function diag_jfr() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Create JFR recordings for the pod's initial pid"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_jfr [pod_name] [start|stop|dump] [optional profiling settings file]"
    fi
    return 0
  fi
  local PODNAME="$1"
  local COMMAND="$2"
  local PROFILING_SETTINGS="${3:-$SCRIPT_DIR/jfr_profiling_settings.jfc}"
  local CONTAINER="$(_diag_find_container $PODNAME)"
  [ -n "$CONTAINER" ] || return 1
  local ROOT_PATH=$(_diag_find_root_path $CONTAINER)
  [ -n "$ROOT_PATH" ] || return 2
  local JCMD="_diag_jattach_container $CONTAINER jcmd"
  if [ "$COMMAND" = "stop" ] || [ "$COMMAND" = "dump" ]; then
    $JCMD "JFR.${COMMAND} name=recording filename=/tmp/recording.jfr"
    local JFR_FILE=recording_$(date +%F-%H%M%S).jfr
    mv $ROOT_PATH/tmp/recording.jfr ${JFR_FILE}
    [ "$COMMAND" = "stop" ] && [ -f $ROOT_PATH/tmp/profiling.jfc ] && rm $ROOT_PATH/tmp/profiling.jfc
    if [ -f "$JFR_FILE" ]; then
      _diag_chown_sudo_user "$JFR_FILE"
      echo "$JFR_FILE"
    fi
  else
    if [ -f "$PROFILING_SETTINGS" ]; then
      echo "Using profiling settings from $PROFILING_SETTINGS"
      cp "$PROFILING_SETTINGS" $ROOT_PATH/tmp/profiling.jfc
      $JCMD "JFR.start name=recording settings=/tmp/profiling.jfc"
    else
      $JCMD "JFR.start name=recording settings=profile"
    fi
  fi
}

function diag_jfr_profile() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Run JFR profiling in interactive mode"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_jfr_profile [pod_name]"
    fi
    return 0
  fi
  local PODNAME="$1"
  [ -n "$PODNAME" ] || return 1
  echo "Starting JFR profiling..."
  diag_jfr "$PODNAME" start
  _diag_wait_for_any_key "Press any key to stop profiling..."
  diag_jfr "$PODNAME" stop | _diag_auto_convert_jfr_file
}

function _diag_auto_convert_jfr_file() {
  tee /tmp/jfrstop$$
  local jfr_file="$(tail -1 /tmp/jfrstop$$)"
  rm /tmp/jfrstop$$
  if [ -f "$jfr_file" ] && command -v java &> /dev/null; then
    diag_jfr_to_flamegraph "$jfr_file"
  fi
}

function diag_async_profiler() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Run async-profiler for the pod's initial pid"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_async_profiler [pod_name] [profile.sh arguments]"
    fi
    return 0
  fi
  local PODNAME="$1"
  shift
  local CONTAINER="$(_diag_find_container $PODNAME)"
  [ -n "$CONTAINER" ] || return 1
  local ROOT_PATH=$(_diag_find_root_path $CONTAINER)
  [ -n "$ROOT_PATH" ] || return 2
  if [ ! -d "$ROOT_PATH/tmp/async-profiler" ]; then
    cp -Rdvp "$(_diag_tool_cache_dir async-profiler)/." $ROOT_PATH/tmp/async-profiler
  fi
  echo 1 > /proc/sys/kernel/perf_event_paranoid
  echo 0 > /proc/sys/kernel/kptr_restrict
  local ASPROF=/tmp/async-profiler/asprof
  if [[ ! -x "$ASPROF" ]]; then
    ASPROF=/tmp/async-profiler/profiler.sh
  fi
  (_diag_exec_in_container $CONTAINER $ASPROF "$@" && echo "Done.") || echo "Failed."
  echo "Rootpath $ROOT_PATH"
  if [[ "$1" != "start" ]]; then
    local argc=$#
    local argv=("$@")
    for (( i=0; i<argc; i++ )); do
        if [[ "${argv[i]}" == "-f" ]]; then
          local nextarg=$((i+1))
          local fileparam="${argv[nextarg]}"
          if [ -f "$ROOT_PATH/$fileparam" ]; then
            local filename=$(basename -- "$fileparam")
            local extension="${filename##*.}"
            local filename="${filename%.*}"
            local target_filename="${filename}_$(date +%F-%H%M%S).${extension}"
            mv "$ROOT_PATH/$fileparam" "$target_filename"
            _diag_chown_sudo_user "$target_filename"
            echo "$target_filename"
          fi
        fi
    done
  fi
}

function _diag_exec_in_container() {
  local CONTAINER=$1
  shift
  if _diag_is_k8s_node; then
    diag_crictl exec -is $CONTAINER "$@"
  else
    if ! [[ "$CONTAINER" =~ ^[0-9]+$ ]]; then
      docker exec -i $CONTAINER "$@"
    else
      nsenter -t "$CONTAINER" -a "$@"
    fi
  fi
}



function diag_jfr_to_flamegraph() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Creates a flamegraph from a jfr recording"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_jfr_to_flamegraph [recording.jfr] [flamegraph.html]"
    fi
    return 0
  fi
  local JFR_FILE="$1"
  local FLAMEGRAPH_FILE="$2"
  if [ ! -f "$JFR_FILE" ]; then
    echo "File $JFR_FILE doesn't exist."
    return 1
  fi
  if [ -z "$FLAMEGRAPH_FILE" ]; then
    FLAMEGRAPH_FILE="${JFR_FILE%.*}.html"
  fi
  local async_profiler_dir="$(_diag_tool_cache_dir async-profiler)"
  local async_profiler_jar="$async_profiler_dir/build/converter.jar"
  if [ ! -f "$async_profiler_jar" ]; then
    async_profiler_jar="$async_profiler_dir/lib/converter.jar"
  fi
  java -cp "${async_profiler_jar}" jfr2flame "$JFR_FILE" "$FLAMEGRAPH_FILE"
  if [ $? -eq 0 ]; then
    _diag_chown_sudo_user "$FLAMEGRAPH_FILE"
    echo "Result in file://$(realpath "$FLAMEGRAPH_FILE")"
  fi
}

function _diag_wait_for_any_key() {
  read -n 1 -s -r -p "${1:-"Press any key to continue"}"
}


function diag_async_profiler_profile() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Run async-profiler profiling in interactive mode"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_async_profiler_profile [pod_name] [jfr|exceptions|status|]"
    fi
    return 0
  fi
  local PODNAME="$1"
  [ -n "$PODNAME" ] || return 1
  local COMMAND="$2"
  local PROFILEPID
  if [[ "$PODNAME" =~ ^[0-9]+$ ]]; then
    # get pid inside container
    PROFILEPID=$(grep NStgid /proc/"$PODNAME"/status | perl -p -e 's/^.*\s(\d+)$/$1/')
  else
    # default to pid 1, but allow overriding with JAVAPID variable
    PROFILEPID="${JAVAPID:-1}"
  fi
  ASYNC_PROFILER_OPTIONS="${ASYNC_PROFILER_OPTIONS:-"-e cpu,alloc,lock -i 1ms"}"
  case "$COMMAND" in
    jfr)
      echo "Profiling CPU, allocations and locks in JFR format with options $ASYNC_PROFILER_OPTIONS"
      diag_async_profiler "$PODNAME" start $ASYNC_PROFILER_OPTIONS -o jfr -f "/tmp/${PODNAME}_async_profiler.jfr" "$PROFILEPID"
      _diag_wait_for_any_key "Press any key to stop profiling..."
      diag_async_profiler "$PODNAME" stop -f "/tmp/${PODNAME}_async_profiler.jfr" "$PROFILEPID" | _diag_auto_convert_jfr_file
      ;;
    exceptions)
      echo "Profiling exceptions..."
      diag_async_profiler "$PODNAME" start -e Java_java_lang_Throwable_fillInStackTrace "$PROFILEPID"
      _diag_wait_for_any_key "Press any key to stop profiling..."
      diag_async_profiler "$PODNAME" stop -o tree --reverse -f "/tmp/${PODNAME}_exceptions.html" "$PROFILEPID"
      ;;
    exceptions_flamegraph)
      echo "Profiling exceptions with flamegraph output..."
      diag_async_profiler "$PODNAME" start -e Java_java_lang_Throwable_fillInStackTrace "$PROFILEPID"
      _diag_wait_for_any_key "Press any key to stop profiling..."
      diag_async_profiler "$PODNAME" stop -f "/tmp/${PODNAME}_exceptions.html" "$PROFILEPID"
      ;;
    stop)
      diag_async_profiler "$PODNAME" stop "$PROFILEPID"
      ;;
    status)
      diag_async_profiler "$PODNAME" status "$PROFILEPID"
      ;;
    *)
      echo "Unknown command"
      ;;
  esac
}

function diag_async_profiler_profile_many() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Run async-profiler profiling in interactive mode for all pods with a specific label"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_async_profiler_profile_many [label] [jfr|exceptions|status|]"
    fi
    return 0
  fi
  local LABEL="$1"
  [ -n "$LABEL" ] || return 1
  local COMMAND="$2"
  # default to pid 1, but allow overriding with JAVAPID variable
  local PROFILEPID="${JAVAPID:-1}"

  local PODNAMES="$(diag_crictl pods --label "$LABEL" -o json | "$(_diag_tool_path jq)" -r '.items[] | .metadata.name')"
  echo "Matching pods are $PODNAMES"

  ASYNC_PROFILER_OPTIONS="${ASYNC_PROFILER_OPTIONS:-"-e cpu,alloc,lock -i 1ms"}"

  case "$COMMAND" in
    jfr)
      echo "Profiling CPU, allocations and locks in JFR format with options $ASYNC_PROFILER_OPTIONS"
      for PODNAME in $PODNAMES; do
        diag_async_profiler "$PODNAME" start $ASYNC_PROFILER_OPTIONS -o jfr -f "/tmp/${PODNAME}_async_profiler.jfr" "$PROFILEPID"
      done
      _diag_wait_for_any_key "Press any key to stop profiling..."
      for PODNAME in $PODNAMES; do
        diag_async_profiler "$PODNAME" stop -f "/tmp/${PODNAME}_async_profiler.jfr" "$PROFILEPID" | _diag_auto_convert_jfr_file
      done
      ;;
    exceptions)
      echo "Profiling exceptions..."
      for PODNAME in $PODNAMES; do
        diag_async_profiler "$PODNAME" start -e Java_java_lang_Throwable_fillInStackTrace "$PROFILEPID"
      done
      _diag_wait_for_any_key "Press any key to stop profiling..."
      for PODNAME in $PODNAMES; do
        diag_async_profiler "$PODNAME" stop -o tree --reverse -f "/tmp/${PODNAME}_exceptions.html" "$PROFILEPID"
      done
      ;;
    exceptions_flamegraph)
      echo "Profiling exceptions with flamegraph output..."
      for PODNAME in $PODNAMES; do
        diag_async_profiler "$PODNAME" start -e Java_java_lang_Throwable_fillInStackTrace "$PROFILEPID"
      done
      _diag_wait_for_any_key "Press any key to stop profiling..."
      for PODNAME in $PODNAMES; do
        diag_async_profiler "$PODNAME" stop -f "/tmp/${PODNAME}_exceptions.html" "$PROFILEPID"
      done
      ;;
    stop)
      for PODNAME in $PODNAMES; do
        diag_async_profiler "$PODNAME" stop "$PROFILEPID"
      done
      ;;
    status)
      for PODNAME in $PODNAMES; do
        diag_async_profiler "$PODNAME" status "$PROFILEPID"
      done
      ;;
    *)
      echo "Unknown command"
      ;;
  esac
}

function diag_crictl() {
  if [ "$1" == "--desc" ]; then
    echo "Run crictl"
    return 0
  fi
  (
  if [ -z "$CONTAINER_RUNTIME_ENDPOINT" ] && [ -S /var/snap/microk8s/common/run/containerd.sock ]; then
    export CONTAINER_RUNTIME_ENDPOINT=unix:///var/snap/microk8s/common/run/containerd.sock
  fi
  if [ -z "$CONTAINER_RUNTIME_ENDPOINT" ] && [ -S /var/run/dockershim.sock ]; then
    export CONTAINER_RUNTIME_ENDPOINT=unix:///var/run/dockershim.sock
  fi
  "$(_diag_tool_path crictl)" "$@"
  )
}

function diag_list_pods() {
  if [ "$1" == "--desc" ]; then
    echo "Lists all pods running on the node"
    return 0
  fi
  diag_crictl pods
}

function gpg() {
  if ! type -P gpg &>/dev/null; then
    _diag_download_tool gpg "https://github.com/lhotari/lean-static-gpg/releases/download/v2.3.1/gnupg.tar.gz" 1 1
    # staticly compiled gpg expects to find other binaries in /tmp/gnupg
    if [ ! -e /tmp/gnupg ]; then
      ln -s "$(_diag_tool_path gpg .)" /tmp/gnupg
    fi
    if [ ! -f ~/.gnupg/gpg.conf ]; then
      mkdir -p ~/.gnupg
      chmod 0700 ~/.gnupg
      cat > ~/.gnupg/gpg.conf <<EOF
  keyserver keyserver.ubuntu.com
EOF
    fi
    /tmp/gnupg/bin/gpg "$@"
  else
    command gpg "$@"
  fi
}

function _diag_upload_encrypted() {
  local file_name="$1"
  local recipient="$2"
  gpg -k "$recipient" &> /dev/null || gpg --recv-key "$recipient" &> /dev/null || { echo "Searching for key for $recipient"; gpg --search-keys "$recipient"; }
  local transfer_url=$(gpg --encrypt --recipient "$recipient" --trust-model always \
    |curl --progress-bar -F "data=@-;filename=${file_name}.gpg" https://file.io \
    |"$(_diag_tool_path jq)" -r '.link')
  echo ""
  echo "command for receiving: curl $transfer_url | gpg --decrypt > ${file_name}"
}

function diag_transfer(){
    if [ "$1" == "--desc" ]; then
    echo "Transfers files with gpg encryption over file.io"
    return 0
  fi
  if [ $# -lt 2 ]; then
      echo "No arguments specified.\nUsage:\n diag_transfer <file|directory> recipient\n ... | diag_transfer <file_name> recipient">&2
      return 1
  fi
  if tty -s; then
    local file="$1"
    local recipient="$2"
    local file_name=$(basename "$file")
    if [ ! -e "$file" ]; then
      echo "$file: No such file or directory">&2
      return 1
    fi
    if [ -d "$file" ]; then
        file_name="${file_name}.tar.gz"
        tar zcf - "$file" | _diag_upload_encrypted $file_name $recipient
    else
        cat "$file" | _diag_upload_encrypted $file_name $recipient
    fi
  else
    local file_name=$1
    local recipient="$2"
    _diag_upload_encrypted $file_name $recipient
  fi
}


function _diag_find_container() {
  local PODNAME="$1"
  if _diag_is_k8s_node; then
    if [ -S /var/run/dockershim.sock ]; then
      docker ps -q --filter label=io.kubernetes.docker.type=container --filter label=io.kubernetes.pod.name="$PODNAME" | head -n 1
    else
      if [[ "$PODNAME" =~ ^[0-9a-f]+$ ]]; then
        local containerid=$(diag_crictl ps --id "$PODNAME" -q | head -n 1)
        if [[ -n "$containerid" ]]; then
          echo "$containerid"
          return 0
        fi
      fi
      diag_crictl ps --label "io.kubernetes.pod.name=${PODNAME}" -q | head -n 1
    fi
  else
    if [[ "$PODNAME" =~ ^[0-9]+$ ]]; then
      echo "$PODNAME"
    else
      { docker ps -q --filter id="$PODNAME"; docker ps -q --filter name="$PODNAME"; }|sort|uniq -u|head -n 1
    fi
  fi
}

function _diag_inspect_container_with_template() {
  local CONTAINER="$1"
  local TEMPLATE="$2"
  diag_crictl inspect --template "$TEMPLATE" -o go-template "$CONTAINER"
}

function _diag_docker_inspect_container_with_template() {
  local CONTAINER="$1"
  local TEMPLATE="$2"
  docker inspect "$CONTAINER" -f "$TEMPLATE"
}

function _diag_find_container_pid() {
  if _diag_is_k8s_node; then
    _diag_inspect_container_with_template "$1" '{{.info.pid}}' 2> /dev/null || _diag_docker_inspect_container_with_template "$1" '{{.State.Pid}}'
  else
    if [[ "$1" =~ ^[0-9]+$ ]]; then
      echo "$1"
    else
      _diag_docker_inspect_container_with_template "$1" '{{.State.Pid}}'
    fi
  fi
}

function _diag_chown_sudo_user() {
  local file="$1"
  if [[ -e "$file" && -n "$SUDO_USER" ]]; then
    chown -R $SUDO_USER "$file"
  fi
}

function _diag_find_root_path() {
  local CONTAINER="$1"
  if ! [[ "$CONTAINER" =~ ^[0-9]+$ ]]; then
    local ROOT_PATH=$(_diag_inspect_container_with_template "$CONTAINER" '{{.info.runtimeSpec.root.path}}' 2> /dev/null || echo rootfs)
    if [ "$ROOT_PATH" = "rootfs" ]; then
      ROOT_PATH=/proc/$(_diag_find_container_pid "$CONTAINER")/root
    fi
    echo $ROOT_PATH
  else
    echo "/proc/$CONTAINER/root"
  fi
}

function _diag_jattach_container() {
  local CONTAINER="$1"
  shift
  local JAVA_PID
  if ! [[ "$CONTAINER" =~ ^[0-9]+$ ]]; then
    local CONTAINER_PID="$(_diag_find_container_pid $CONTAINER)"
    [ -n "$CONTAINER_PID" ] || return 1
    JAVA_PID=$(pgrep --ns $CONTAINER_PID java | head -n 1 || echo $CONTAINER_PID)
  else
    JAVA_PID=$CONTAINER
  fi
  "$(_diag_tool_path jattach)" $JAVA_PID "$@"
}

function _diag_tool_path() {
  local toolname=$1
  local toolbinary=${2:-$1}
  echo $(_diag_tool_cache_dir $toolname)/$toolbinary
}

function _diag_tool_cache_dir() {
  local toolname=$1
  echo "$HOME/.cache/k8s-diagnostics-toolbox/$toolname"
}

function _diag_download_tool() {
  local toolname="$1"
  local toolurl="$2"
  local extract=${3:-0}
  local strip_components=${4:-1}
  local tooldir=$(_diag_tool_cache_dir $toolname)
  mkdir -p "$tooldir"
  if [ -z "$(ls -A -- "$tooldir")" ]; then
    (
    echo "Downloading and installing $toolname to $tooldir"
    set -e
    if [ $extract -ne 1 ]; then
      curl -L -o "$tooldir/$toolname" "$toolurl"
      if [[ "$toolurl" =~ .*\.gz$ ]]; then
        mv "$tooldir/$toolname" "$tooldir/${toolname}.gz"
        gunzip "$tooldir/${toolname}.gz"
      fi
      chmod a+rx "$tooldir/$toolname"
    else
      cd "$tooldir"
      curl -L "$toolurl" | tar -zxvf - --strip-components=$strip_components
    fi
    )
    if [ $? -ne 0 ]; then
      printf "Error downloading the tool.\n"
      return 1
    else
      printf "Done."
    fi
  fi
}

function _diag_download_tools() {
  local arch=$(uname -m | sed -r 's/aarch64/arm64/g' |  awk '!/arm64/{$0="amd64"}1')
  local arch_short=$(echo $arch | sed -r 's/amd64/x64/g')
  _diag_download_tool jattach "https://github.com/jattach/jattach/releases/download/v2.2/jattach-linux-${arch_short}.tgz" 1 0
  _diag_download_tool async-profiler "https://github.com/async-profiler/async-profiler/releases/download/v4.0/async-profiler-4.0-linux-${arch_short}.tar.gz" 1
  _diag_download_tool crictl "https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.24.2/crictl-v1.24.2-linux-${arch}.tar.gz" 1 0
  _diag_download_tool jq "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${arch}"
}

function _diag_list_functions() {
  for function_name in $(declare -F | awk '{print $NF}' | sort | egrep '^diag_' | sed 's/^diag_//'); do
    printf '%-20s\t%s\n' $function_name "$(eval "diag_${function_name}" --desc)"
  done
}

function _diag_is_k8s_node() {
  [ -n "${CONTAINER_RUNTIME_ENDPOINT}" ] || [ -n "${KUBERNETES_SERVICE_HOST}" ] || [ -S /var/snap/microk8s/common/run/containerd.sock ] || [ -S /var/run/dockershim.sock ]
}

function diag_collect_multiple_dumps() {
  (
  if [ "$1" == "--desc" ]; then
    echo "Collects multiple thread and heap dumps for all JVMs"
    return 0
  fi
  local PODNAME="$1"
  local CONTAINER="$(_diag_find_container $PODNAME)"
  [ -n "$CONTAINER" ] || return 1

  # create an inline script that is passed as a parameter to bash inside the container
  read -r -d '' diag_script <<'EOF'
  diagdir=$1
  mkdir $diagdir
  # loop 3 times
  for i in 1 2 3; do
      # wait 3 seconds (if not the 1. round)
      [ $i -ne 1 ] && { echo "Waiting 3 seconds..."; sleep 3; }
      # iterate all java processes
      for javapid in $(pgrep java 2> /dev/null || jps -q -J-XX:+PerfDisableSharedMem); do
          # on the first round, collect the full command line used to start the java process
          if [ $i -eq 1 ]; then
              java_commandline="$(cat /proc/$javapid/cmdline | xargs -0 echo)"
              echo "Collecting diagnostics for PID $javapid, ${java_commandline}"
              echo "${java_commandline}" > $diagdir/commandline_${javapid}.txt
              cat /proc/$javapid/environ | xargs -0 -n 1 echo > $diagdir/environment_${javapid}.txt
          fi
          # collect the threaddump with additional locking information
          echo "Creating threaddump..."
          jstack -l $javapid > $diagdir/threaddump_${javapid}_$(date +%F-%H%M%S).txt
          # collect a heap dump on 1. and 3. rounds
          if [ $i -ne 2 ]; then
              echo "Creating heapdump..."
              jmap -dump:format=b,file=$diagdir/heapdump_${javapid}_$(date +%F-%H%M%S).hprof $javapid
          fi
      done
  done
EOF

  # run the script and provide the target directory inside the container as an argument
  _diag_exec_in_container $CONTAINER bash -c "${diag_script}" bash /tmp/diagnostics$$

  # copy collected diagnostics from the container and remove files from the container
  diagnostics_dir="jvm_diagnostics_${PODNAME}_$(date +%F-%H%M%S)"
  local ROOT_PATH=$(_diag_find_root_path $CONTAINER)
  cp -r "${ROOT_PATH}/tmp/diagnostics$$" ${diagnostics_dir} && rm -rf "${ROOT_PATH}/tmp/diagnostics$$"
  _diag_chown_sudo_user ${diagnostics_dir}
  echo "diagnostics information in $diagnostics_dir"
  )
}

function diag_list_java_pids() {
  (
  if [ "$1" == "--desc" ]; then
    echo "Lists the host process ids for all Java processes"
    return 0
  fi
  pgrep -a java
  )
}


diag_function_name="diag_${1}"
if [ -z "$diag_function_name" ]; then
  echo "usage: $0 [tool name] [tool arguments]"
  echo "Pass --help as the argument to get usage information for a tool."
  echo "The script needs to be run as root."
  echo "Available diagnostics tools:"
  _diag_list_functions
  exit 1
fi
shift

if [[ "$(LC_ALL=C type -t $diag_function_name)" == "function" ]]; then
  allow_non_root=("diag_jfr_to_flamegraph" "diag_transfer")
  if [[ $(id -u) -ne 0 && ! (" ${allow_non_root[@]} " =~ " ${diag_function_name} ") ]]; then
    echo "The script needs to be run as root." >&2
    exit 1
  fi
  _diag_download_tools
  "$diag_function_name" "$@"
else
  echo "Invalid diagnostics tool"
  echo "Available diagnostics tools:"
  _diag_list_functions
  exit 1
fi
