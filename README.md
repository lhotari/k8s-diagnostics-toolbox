# Kubernetes Diagnostics Toolbox for JVM applications

## Installing in remote environments such as AWS EKS

One-liner command to installing to `~/k8s-diagnostics-toolbox` when there's `curl` and `tar` available:
```bash
mkdir -p ~/k8s-diagnostics-toolbox && cd ~/k8s-diagnostics-toolbox && curl -L https://github.com/lhotari/k8s-diagnostics-toolbox/archive/refs/heads/master.tar.gz | tar -zxv --strip-components=1 -f -
```

### Installing in GCP/GKE

In GKE, the root filesystem on k8s worker nodes is read-only. As a workaround, the tooling can be installed by creating a directory in a suitable location which allows writing and executing files. One such location is under `/home/kubernetes/bin`.

Run this before installing with the above command:
```
mkdir /home/kubernetes/bin/k8sdiag
export HOME=/home/kubernetes/bin/k8sdiag
cd 
```

## Usage

The tool is designed for running on a k8s node with sudo or as the root user. 
When using microk8s, the local machine is the k8s node.

The tool has also support for profiling applications running as normal processes or within docker.
When the given parameter is a numeric value, it is expected to be a process id on the host machine.
Profiling in docker containers requires that the container has been started with `--cap-add SYS_ADMIN` 
since the [default seccomp profile for docker](https://github.com/moby/moby/blob/master/profiles/seccomp/default.json) blocks `perf_event_open` calls.

### Listing all available tools

```
sudo ./k8s-diagnostics-toolbox.sh [tool] [tool arguments]
```

Pass `--help` as the argument to get usage information for a tool.

Most tools use the pod name as the condition for finding the container for a pod.
The tool doesn't currently support multiple containers for a pod, or filtering
by the k8s namespace.

### Getting a thread dump

First, find out the pod name you are interested in. Listing all pods:
```
sudo ./k8s-diagnostics-toolbox.sh crictl pods
```
or list all Java process ids on the host:
```
sudo ./k8s-diagnostics-toolbox.sh list_java_pids
```

Example: Get the thread dump for `pulsar-broker-0`
```
sudo ./k8s-diagnostics-toolbox.sh get_threaddump pulsar-broker-0
```

Example: Get the thread dump for process id `1234`
```
sudo ./k8s-diagnostics-toolbox.sh get_threaddump 1234
```


### Getting a heap dump

Example: Get the heap dump for `pulsar-broker-0`
```
sudo ./k8s-diagnostics-toolbox.sh get_heapdump pulsar-broker-0
```

### Running async-profiler

Example: Start and stop async-profiler for `pulsar-broker-0`
```
sudo ./k8s-diagnostics-toolbox.sh async_profiler_profile pulsar-broker-0 jfr
```
This will record CPU, allocations and locks in JFR format and create a flamegraph in html format.


Example: Profile the CPU used by `pulsar-broker-0` for 30 seconds
```
./k8s-diagnostics-toolbox.sh async_profiler pulsar-broker-0 -t -e cpu,lock -d 30 -f /tmp/profile.jfr 1
```
This will record CPU and create a flamegraph in JFR format in the toolbox home. The resulting flamegraph file name is 
```
profile_cpu-lock_<docker_image_of_profiled_container>_pulsar-broker-0_<hourMinuteSecond_of_observation>.jfr
```
> Note: the file passed to the `diag_async_profiler` via the flag `-f` must be specified as an absolute path.
JFR files can be further analysed in [JDK Mission Control](https://adoptium.net/jmc/).

### Running Java Flight Recorder

Please notice that you need to have `-XX:+UnlockDiagnosticVMOptions -XX:+DebugNonSafepoints -XX:FlightRecorderOptions=stackdepth=1024` in your application's JVM options to get accurate results with JFR.

Example: Start and stop JFR for `pulsar-broker-0`
```
sudo ./k8s-diagnostics-toolbox.sh jfr pulsar-broker-0 start
sleep 10
sudo ./k8s-diagnostics-toolbox.sh jfr pulsar-broker-0 stop
```

Opening the file in [JDK Mission Control](https://adoptium.net/jmc/):
```
# open the file in JDK Mission Control (JMC)
# download JMC from https://adoptium.net/jmc/
jmc -open recording*.jfr
```
