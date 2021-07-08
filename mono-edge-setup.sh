#!/bin/bash
# Install KIND Edge KUBERNETES 

PUB=`curl http://169.254.169.254/latest/meta-data/public-ipv4`
HIP=`ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1`
CLUSTER=$1
#CLUSTER=kube-edge1
# Central Cluster Ingress IP
#INGIP=172.31.25.28

# Install packages
echo "Installing Packges"
yum install -q -y git curl wget bind-utils jq httpd-tools zip unzip nfs-utils dos2unix telnet java-1.8.0-openjdk

# Install Docker
echo "Installing Docker"
amazon-linux-extras install docker -y
#curl -s https://releases.rancher.com/install-docker/19.03.sh | sh
systemctl enable docker;systemctl start docker
docker ps -a

# Install Docker Compose
curl -sSL "https://github.com/docker/compose/releases/download/1.26.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Install KIND
echo "Installing Kind"
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.10.0/kind-linux-amd64
chmod +x ./kind
mv ./kind /usr/local/bin/kind

# Install Kubectl
echo "Installing Kubectl"
K8S_VER=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
wget -q https://storage.googleapis.com/kubernetes-release/release/$K8S_VER/bin/linux/amd64/kubectl
chmod +x ./kubectl
mv ./kubectl /usr/bin/kubectl
echo "alias oc=/usr/bin/kubectl" >> /root/.bash_profile

# Clone Git
git clone https://github.com/prasenforu/CLT.git

# Kubernetes Cluster Creation

cat <<EOF > kind-kube-install.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER
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
kind create cluster --config kind-kube-install.yaml

# Waiting Cluster UP
echo "Waiting Cluster UP ..."
kubectl  wait --for=condition=Ready node --all --timeout 60s

echo "Waiting for Cluster PODs are ready .."
kubectl wait pods/etcd-$CLUSTER-control-plane --for=condition=Ready --timeout=5m -n kube-system
kubectl wait pods/kube-scheduler-$CLUSTER-control-plane --for=condition=Ready --timeout=5m -n kube-system
kubectl wait pods/kube-apiserver-$CLUSTER-control-plane --for=condition=Ready --timeout=5m -n kube-system

# Setup Helm Chart
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh

# Install Ingress
kubectl apply -f https://raw.githubusercontent.com/prasenforu/CLT/main/kube-kind-ingress.yaml
sleep 15
kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission

# Files edit
find ./CLT/ -type f -exec sed -i -e "s/172.31.14.138/$INGIP/g" {} \;
find ./CLT/ -type f -exec sed -i -e "s/3.16.154.209/$PUB/g" {} \;
find ./CLT/ -type f -exec sed -i -e "s/kube-one/$CLUSTER/g" {} \;

# Agent Deployment
kubectl create ns monitoring
kubectl create -f CLT/single/02-kube-state-metrics.yaml -n monitoring
kubectl create -f CLT/single/02-node-exporter.yaml -n monitoring
kubectl create -f CLT/client/agent.yaml -n monitoring
kubectl create -f CLT/client/prometheus.yaml -n monitoring
kubectl create -f CLT/client/promtail.yaml -n monitoring
#kubectl create -f CLT/client/fluent-bit-ds.yaml -n monitoring

# Demo App Deployment
kubectl create ns hotrod
kubectl create -f CLT/demo/hotrod.yaml -n hotrod
kubectl create ns demo
kubectl create -f CLT/demo/mongo-employee.yaml -n demo

# Setup Velero Backup
wget https://raw.githubusercontent.com/cloudcafetech/kubesetup/master/misc/backup-setup.sh
chmod +x ./backup-setup.sh
#./backup-setup.sh

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
