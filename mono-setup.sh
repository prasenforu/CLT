#!/bin/bash
# Install KIND KUBERNETES

function setup_arch_and_os(){
  ARCH=$(uname -m)
  case $ARCH in
    armv5*) ARCH="armv5";;
    armv6*) ARCH="armv6";;
    armv7*) ARCH="arm";;
    aarch64) ARCH="arm64";;
    x86) ARCH="386";;
    x86_64) ARCH="amd64";;
    i686) ARCH="386";;
    i386) ARCH="386";;
    *) echo "Error architecture '${ARCH}' unknown"; exit 1 ;;
  esac

  OS=$(uname |tr '[:upper:]' '[:lower:]')
  case "$OS" in
    # Minimalist GNU for Windows
    "mingw"*) OS='windows'; return ;;
  esac

  # list is available for kind at https://github.com/kubernetes-sigs/kind/releases
  # kubectl supported architecture list is a superset of the Kind one. No need to further compatibility check.
  local supported="darwin-amd64\n\nlinux-amd64\nlinux-arm64\nlinux-ppc64le\nwindows-amd64"
  if ! echo "${supported}" | grep -q "${OS}-${ARCH}"; then
    echo "Error: No version of kind for '${OS}-${ARCH}'"
    return 1
  fi

}

setup_arch_and_os

CLUSTER0=kube-central
CLUSTER1=kube-one
PUB=`curl http://169.254.169.254/latest/meta-data/public-ipv4`
MinIO=`ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1`
HIP=`ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1`
velver=v1.4.2

# Install packages
echo "Installing Packges"
yum install -q -y git curl wget bind-utils jq httpd-tools zip unzip nfs-utils dos2unix telnet java-1.8.0-openjdk

# Install Docker
if ! command -v docker &> /dev/null;
then
  echo "MISSING REQUIREMENT: docker engine could not be found on your system. Please install docker engine to continue: https://docs.docker.com/get-docker/"
  echo "Trying to Install Docker..."
  if [[ $(uname -a | grep amzn) ]]; then
    echo "Installing Docker for Amazon Linux"
    amazon-linux-extras install docker -y
    systemctl enable docker;systemctl start docker
    docker ps -a
  else
    curl -s https://releases.rancher.com/install-docker/19.03.sh | sh
    systemctl enable docker;systemctl start docker
    docker ps -a
  fi    
fi


# Install KIND
if ! command -v kind &> /dev/null;
then
 echo "Installing Kind"
 curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.10.0/kind-linux-amd64
 chmod +x ./kind; mv ./kind /usr/local/bin/kind
fi

# Install Kubectl
if ! command -v kubectl &> /dev/null;
then
 echo "Installing Kubectl"
 K8S_VER=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
 wget -q https://storage.googleapis.com/kubernetes-release/release/$K8S_VER/bin/linux/amd64/kubectl
 chmod +x ./kubectl; mv ./kubectl /usr/bin/kubectl
 echo "alias oc=/usr/bin/kubectl" >> /root/.bash_profile
fi 

# Install Minio CLI
if ! command -v mc &> /dev/null;
then
 echo "Installing Minio CLI"
 wget https://dl.min.io/client/mc/release/linux-amd64/mc; chmod +x mc; mv -v mc /usr/local/bin/mc
fi

# Install Backup tool
if ! command -v velero &> /dev/null;
then
 echo "Installing Backup tool"
 wget https://github.com/vmware-tanzu/velero/releases/download/$velver/velero-$velver-linux-amd64.tar.gz
 tar -xvzf velero-$velver-linux-amd64.tar.gz
 mv -v velero-$velver-linux-amd64/velero /usr/local/bin/velero
 echo "alias vel=/usr/local/bin/velero" >> /root/.bash_profile
 rm -rf velero-$velver-linux-amd64*
fi

# Setup Minio
mkdir -p /root/minio/data
mkdir -p /root/minio/config

chcon -Rt svirt_sandbox_file_t /root/minio/data
chcon -Rt svirt_sandbox_file_t /root/minio/config

docker run -d -p 9000:9000 --restart=always --name minio \
  -e "MINIO_ACCESS_KEY=admin" \
  -e "MINIO_SECRET_KEY=admin2675" \
  -v /root/minio/data:/data \
  -v /root/minio/config:/root/.minio \
  minio/minio server /data

sleep 25
# Checks Mino Container running or not
if [ $(docker inspect -f '{{.State.Running}}' minio) = "true" ]; then echo Running; else echo Not Running; fi

# Creating Bucket in Minio
mc config host add minio http://$MinIO:9000 admin admin2675 --insecure
mc mb minio/monitoring --insecure
mc mb minio/logging --insecure
mc mb minio/tracing --insecure
mc mb minio/backup --insecure

# Clone Git
git clone https://github.com/prasenforu/CLT.git
wget https://raw.githubusercontent.com/prasenforu/CLT/main/kube-kind-ingress.yaml
cp kube-kind-ingress.yaml kube-kind-ingress-$CLUSTER0.yaml
cp kube-kind-ingress.yaml kube-kind-ingress-$CLUSTER1.yaml
sed -i "s/30080/31080/g" kube-kind-ingress-$CLUSTER1.yaml
sed -i "s/30443/31443/g" kube-kind-ingress-$CLUSTER1.yaml

# Kubernetes Cluster Creation
for CTX in kube-central kube-one
do
cat <<EOF > kind-kube-$CTX.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerPort: 19091
  apiServerAddress: $HIP
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 80
  - containerPort: 30443
    hostPort: 443
  extraMounts:
  - hostPath: /var/run/docker.sock
    containerPath: /var/run/docker.sock
- role: worker
EOF
done

# Cluster Creation

sed -i "s/hostPort: 80/hostPort: 8080/g" kind-kube-$CLUSTER1.yaml
sed -i "s/hostPort: 443/hostPort: 6443/g" kind-kube-$CLUSTER1.yaml
sed -i "s/30080/31080/g" kind-kube-$CLUSTER1.yaml
sed -i "s/30443/31443/g" kind-kube-$CLUSTER1.yaml
sed -i "s/19091/19092/g" kind-kube-$CLUSTER1.yaml
sed -i '$d' kind-kube-$CLUSTER1.yaml
kind create cluster --name $CLUSTER0 --kubeconfig $CLUSTER0-kubeconf --config kind-kube-$CLUSTER0.yaml --wait 2m
kind create cluster --name $CLUSTER1 --kubeconfig $CLUSTER1-kubeconf --config kind-kube-$CLUSTER1.yaml --wait 2m

# Setup Helm Chart
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh

# Setup Ingress
echo "Setting Ingress for $CLUSTER0"
export KUBECONFIG=$CLUSTER0-kubeconf
kubectl apply -f kube-kind-ingress-$CLUSTER0.yaml
sleep 15
kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission

# Setup Certificate & Password for Ingress
cat <<EOF > req.conf
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $HIP.nip.io
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = cortex.$HIP.nip.io
DNS.2 = loki.$HIP.nip.io
DNS.3 = tempo.$HIP.nip.io
EOF

openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -config req.conf -keyout nip.key -out nip.crt

# Modify files for setup observability
find ./CLT/ -type f -exec sed -i -e "s/172.31.14.138/$HIP/g" {} \;
find ./CLT/ -type f -exec sed -i -e "s/3.16.154.209/$PUB/g" {} \;
find ./CLT/ -type f -exec sed -i -e "s/kube-one/$CLUSTER0/g" {} \;

# Create namespaces
kubectl create ns monitoring

# Create secrets from Certificate for Ingress
kubectl create secret tls nip-tls --cert=nip.crt --key=nip.key -n monitoring

# Deployment Observability
kubectl create -f CLT/single/. -n monitoring

# Client Setup
kubectl create -f CLT/client/agent.yaml -n monitoring
kubectl create -f CLT/client/prometheus.yaml -n monitoring
kubectl create -f CLT/client/promtail.yaml -n monitoring
#kubectl create -f CLT/client/fluent-bit-ds.yaml -n monitoring

# Demo
kubectl create ns hotrod
kubectl create -f CLT/demo/hotrod.yaml -n hotrod

echo "Setting Ingress for $CLUSTER1"
export KUBECONFIG=$CLUSTER1-kubeconf
kubectl apply -f kube-kind-ingress-$CLUSTER1.yaml
sleep 15
kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission
find ./CLT/ -type f -exec sed -i -e "s/$CLUSTER0/$CLUSTER1/g" {} \;

# Agent Deployment
echo "Agent Deployment in $CLUSTER1"
kubectl create ns monitoring
kubectl create -f CLT/single/02-kube-state-metrics.yaml -n monitoring
kubectl create -f CLT/single/02-node-exporter.yaml -n monitoring
kubectl create -f CLT/client/agent.yaml -n monitoring
kubectl create -f CLT/client/prometheus.yaml -n monitoring
#kubectl create -f CLT/client/promtail.yaml -n monitoring
kubectl create -f CLT/client/fluent-bit-ds.yaml -n monitoring

# Demo App Deployment
echo "App Deployment in $CLUSTER1"
kubectl create ns demo 
sed -i "s/employee.$PUB.nip.io/employee-$CLUSTER1.$PUB.nip.io/g" CLT/demo/mongo-employee.yaml
kubectl create -f CLT/demo/mongo-employee.yaml -n demo
kubectl create ns hotrod
sed -i "s/hotrod.$PUB.nip.io/hotrod-$CLUSTER1.$PUB.nip.io/g" CLT/demo/hotrod.yaml
kubectl create -f CLT/demo/hotrod.yaml -n hotrod

# Merging Kubeconfig
export KUBECONFIG=$CLUSTER0-kubeconf:$CLUSTER1-kubeconf
kubectl config view --raw > merge-config
cp merge-config .kube/config

# Install Krew
set -x; cd "$(mktemp -d)" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.{tar.gz,yaml}" &&
  tar zxvf krew.tar.gz &&
  KREW=./krew-"$(uname | tr '[:upper:]' '[:lower:]')_amd64" &&
  "$KREW" install --manifest=krew.yaml --archive=krew.tar.gz &&
  "$KREW" update

export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

kubectl krew install modify-secret
kubectl krew install ctx
kubectl krew install ns

echo 'export PATH="${PATH}:${HOME}/.krew/bin"' >> /root/.bash_profile
exit
