# unhealthy_pod_isolate
Isolate unhealthy pod base on readiness of kubernetes. 
## usage
###1) create pod-isolate clusterrole <br>
$ oc create -f pod-isolate-clusterrole.yaml<br>
###2) add clusterrole to serviceaccount default in project<br>
$ oadm policy add-clusterrole-to-user pod-isolate -z default  -n project_name<br>
note: add role to serviceaccount which your pod using.<br>
###3) add configuraton in deploymentconfig as below:<br>
```yaml
......
- containerPort: 8080
  name: http
  protocol: TCP
readinessProbe:
  exec:
    command:
    - /bin/bash
    - -c
    - /opt/webserver/bin/probe-check.sh
  failureThreshold: 3
  initialDelaySeconds: 10
  periodSeconds: 10
  successThreshold: 1
  timeoutSeconds: 2
resources: {}
terminationMessagePath: /dev/termination-log
volumeMounts:
......
```
## image
image must contains scripts under path CHECK_SCRIPT_PATH which define in image's ENV
