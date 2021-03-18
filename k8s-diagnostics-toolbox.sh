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

function diag_nsenter_pod() {
  if [[ "$1" == "--desc" || "$1" == "--help" ]]; then
    echo "Uses nsenter to run a program in the pod's OS namespace"
    if [ "$1" == "--help" ]; then
      echo "usage: $0 diag_nsenter_pod [pod_name]"
    fi
    return 0
  fi
  local PODNAME="$1"
  shift
  local CONTAINER="$(_diag_find_container_for_pod $PODNAME)"
  [ -n "$CONTAINER" ] || return 1
  local CONTAINER_PID="$(_diag_find_container_pid $CONTAINER)"
  [ -n "$CONTAINER_PID" ] || return 2
  nsenter -t "$CONTAINER_PID" "$@"
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
  local CONTAINER="$(_diag_find_container_for_pod $PODNAME)"
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
  local CONTAINER="$(_diag_find_container_for_pod $PODNAME)"
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
  local CONTAINER="$(_diag_find_container_for_pod $PODNAME)"
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
  local CONTAINER="$(_diag_find_container_for_pod $PODNAME)"
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
  local CONTAINER="$(_diag_find_container_for_pod $PODNAME)"
  [ -n "$CONTAINER" ] || return 1
  local ROOT_PATH=$(_diag_find_root_path $CONTAINER)
  [ -n "$ROOT_PATH" ] || return 2
  if [ ! -d "$ROOT_PATH/tmp/async-profiler" ]; then
    cp -Rdvp "$(_diag_tool_cache_dir async-profiler)/." $ROOT_PATH/tmp/async-profiler
  fi
  echo 1 > /proc/sys/kernel/perf_event_paranoid
  echo 0 > /proc/sys/kernel/kptr_restrict
  (diag_crictl exec -is $CONTAINER /tmp/async-profiler/profiler.sh "$@" && echo "Done.") || echo "Failed."
  echo "Rootpath $ROOT_PATH"
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
  "$(_diag_tool_path crictl)" "$@"
  )
}

function _diag_find_container_for_pod() {
  local PODNAME="$1"
  diag_crictl ps --label "io.kubernetes.pod.name=${PODNAME}" -q
}

function _diag_inspect_container_with_template() {
  local CONTAINER="$1"
  local TEMPLATE="$2"
  diag_crictl inspect --template "$TEMPLATE" -o go-template "$CONTAINER"
}

function _diag_find_container_pid() {
  _diag_inspect_container_with_template "$1" '{{.info.pid}}'
}

function _diag_chown_sudo_user() {
  local file="$1"
  if [[ -f "$file" && -n "$SUDO_USER" ]]; then
    chown $SUDO_USER "$file"
  fi
}

function _diag_find_root_path() {
  local CONTAINER="$1"
  local ROOT_PATH=$(_diag_inspect_container_with_template "$CONTAINER" '{{.info.runtimeSpec.root.path}}')
  if [ "$ROOT_PATH" = "rootfs" ]; then
    ROOT_PATH=/proc/$(_diag_find_container_pid "$CONTAINER")/root
  fi
  echo $ROOT_PATH
}

function _diag_jattach_container() {
  local CONTAINER="$1"
  shift
  local CONTAINER_PID="$(_diag_find_container_pid $CONTAINER)"
  [ -n "$CONTAINER_PID" ] || return 1
  "$(_diag_tool_path jattach)" $CONTAINER_PID "$@"
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
  _diag_download_tool jattach "https://github.com/apangin/jattach/releases/download/v1.5/jattach"
  _diag_download_tool async-profiler "https://github.com/jvm-profiling-tools/async-profiler/releases/download/v2.0/async-profiler-2.0-linux-x64.tar.gz" 1
  _diag_download_tool crictl "https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.20.0/crictl-v1.20.0-linux-amd64.tar.gz" 1 0
}

function _diag_list_functions() {
  for function_name in $(declare -F | awk '{print $NF}' | sort | egrep '^diag_'); do
    printf '%-20s\t%s\n' $function_name "$(eval $function_name --desc)"
  done
}

diag_function_name=$1
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
  if ! [ $(id -u) = 0 ]; then
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
