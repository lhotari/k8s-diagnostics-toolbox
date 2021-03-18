# Kubernetes Diagnostics Toolbox for JVM applications

## Usage

The tool is designed for running on a k8s node with sudo or as the root user. 
When using microk8s, the local machine is the k8s node. 

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
kubectl get pods -A
```

Example: Get the thread dump for `pulsar-broker-0`
```
sudo ./k8s-diagnostics-toolbox.sh diag_get_threaddump pulsar-broker-0
```

### Getting a heap dump

Example: Get the heap dump for `pulsar-broker-0`
```
sudo ./k8s-diagnostics-toolbox.sh diag_get_heapdump pulsar-broker-0
```

### Running async-profiler

Example: Profile CPU for 10 seconds for `pulsar-broker-0` and create a flamegraph
```
sudo ./k8s-diagnostics-toolbox.sh diag_async_profiler pulsar-broker-0 -d 10 -f /tmp/profile.html 1
# open the flamegraph in a browser
xdg-open profile*.html
```

### Running Java Flight Recorder

Example: Start and stop JFR for `pulsar-broker-0`
```
sudo ./k8s-diagnostics-toolbox.sh diag_jfr pulsar-broker-0 start
sleep 10
sudo ./k8s-diagnostics-toolbox.sh diag_jfr pulsar-broker-0 stop
```

Opening the file in [JDK Mission Control](https://adoptopenjdk.net/jmc.html):
```
# open the file in JDK Mission Control (JMC)
# download JMC from https://adoptopenjdk.net/jmc.html
jmc -open recording*.jfr
```