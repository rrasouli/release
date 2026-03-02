#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

function create_winc_test_configmap()
{
  oc create configmap winc-test-config -n winc-test --from-literal=primary_windows_image="${1}" --from-literal=primary_windows_container_image="${2}"

  # Display pods and configmap
  oc get pod -owide -n winc-test
  oc get cm winc-test-config -oyaml -n winc-test
}

function create_workloads()
{
  oc new-project winc-test
  # turn off the automatic label synchronization required for PodSecurity admission
  # set pods security profile to privileged. See https://kubernetes.io/docs/concepts/security/pod-security-admission/#pod-security-levels
  oc label namespace winc-test security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged  --overwrite

  # Create Windows workload
  oc create -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: win-webserver
  labels:
    app: win-webserver
spec:
  ports:
  # the port that this service should serve on
  - port: 80
    targetPort: 80
  selector:
    app: win-webserver
  type: LoadBalancer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: win-webserver
  name: win-webserver
spec:
  selector:
    matchLabels:
      app: win-webserver
  replicas: 5
  template:
    metadata:
      labels:
        app: win-webserver
      name: win-webserver
    spec:
      nodeSelector:
        kubernetes.io/os: windows
      tolerations:
        - key: "os"
          value: "Windows"
          Effect: "NoSchedule"
      containers:
        - name: win-webserver
          image: ${1}
          imagePullPolicy: IfNotPresent
          command:
            - pwsh.exe
            - -command
            - \$listener = New-Object System.Net.HttpListener; \$listener.Prefixes.Add('http://*:80/'); \$listener.Start();Write-Host('Listening at http://*:80/'); while (\$listener.IsListening) { \$context = \$listener.GetContext(); \$response = \$context.Response; \$content='<html><body><H1>Windows Container Web Server</H1></body></html>'; \$buffer = [System.Text.Encoding]::UTF8.GetBytes(\$content); \$response.ContentLength64 = \$buffer.Length; \$response.OutputStream.Write(\$buffer, 0, \$buffer.Length); \$response.Close(); };
          securityContext:
            runAsNonRoot: false
            windowsOptions:
              runAsUserName: "ContainerAdministrator"
EOF

  # Wait up to 15 minutes for Windows workload to be ready
  # Windows containers take longer to pull (5GB+ images) and start than Linux containers
  oc wait deployment win-webserver -n winc-test --for condition=Available=True --timeout=15m

  # Create Linux workload
  oc create -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: linux-webserver
  labels:
    app: linux-webserver
spec:
  ports:
  # the port that this service should serve on
  - port: 8080
    targetPort: 8080
  selector:
    app: linux-webserver
  type: LoadBalancer
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: linux-webserver
  name: linux-webserver
spec:
  selector:
    matchLabels:
      app: linux-webserver
  replicas: 1
  template:
    metadata:
      labels:
        app: linux-webserver
      name: linux-webserver
    spec:
      containers:
      - name: linux-webserver
        image: quay.io/openshifttest/hello-openshift:multiarch-winc
        ports:
        - containerPort: 8080
EOF
  # Wait up to 5 minutes for Linux workload to be ready
  oc wait deployment linux-webserver -n winc-test --for condition=Available=True --timeout=5m
}

echo "=== BYOH Windows Test Environment Setup ==="

# Windows nodes are already provisioned and Ready (verified by windows-byoh-provision step)
# No need to wait for MachineSets - they don't exist for BYOH/UPI

# Get Windows OS image ID from SHARED_DIR (saved by provision step)
# For AWS UPI: aws-windows-ami-discover saves AMI ID
# For other platforms: use descriptive placeholder
if [[ -f "${SHARED_DIR}/AWS_WINDOWS_AMI" ]]; then
    windows_os_image_id=$(cat "${SHARED_DIR}/AWS_WINDOWS_AMI")
    echo "Using Windows AMI from SHARED_DIR: ${windows_os_image_id}"
else
    # Fallback: get from node labels or use placeholder
    windows_os_image_id="byoh-windows-$(oc get nodes -l 'kubernetes.io/os=windows' -o=jsonpath="{.items[0].status.nodeInfo.osImage}" | grep -oP '\d{4}' || echo '2022')"
    echo "Using Windows OS image placeholder: ${windows_os_image_id}"
fi

# Choose the Windows container version depending on the Windows version
# installed on the Windows workers
os_version=$(oc get nodes -l 'kubernetes.io/os=windows' -o=jsonpath="{.items[0].status.nodeInfo.osImage}")

windows_container_image="mcr.microsoft.com/powershell:lts-nanoserver-ltsc2022"
if [[ "$os_version" == *"2019"* ]]
then
    windows_container_image="mcr.microsoft.com/powershell:lts-nanoserver-1809"
fi

echo "Windows OS version: ${os_version}"
echo "Windows OS image ID: ${windows_os_image_id}"
echo "Windows container image: ${windows_container_image}"

create_workloads "$windows_container_image"

create_winc_test_configmap "$windows_os_image_id" "$windows_container_image"

echo "=== BYOH Windows Test Environment Ready ==="
