#!/bin/bash
# Install KIND KUBERNETES 

CLUSTER=kube-central
PUB=`curl http://169.254.169.254/latest/meta-data/public-ipv4`
MinIO=`ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1`
HIP=`ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1`

# Install packages
echo "Installing Packges"
yum install -q -y git curl wget bind-utils jq httpd-tools zip unzip nfs-utils dos2unix telnet java-1.8.0-openjdk

# Install Docker
echo "Installing Docker"
amazon-linux-extras install docker -y
#curl -s https://releases.rancher.com/install-docker/19.03.sh | sh
systemctl enable docker;systemctl start docker
docker ps -a

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

wget https://dl.min.io/client/mc/release/linux-amd64/mc; chmod +x mc; mv -v mc /usr/local/bin/mc
mc config host add minio http://$MinIO:9000 admin admin2675 --insecure
mc mb minio/monitoring --insecure
mc mb minio/logging --insecure
mc mb minio/tracing --insecure

# Clone Git
git clone https://github.com/prasenforu/CLT.git

# Kubernetes Cluster Creation

HIP=`ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1`
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
kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission
kubectl delete ValidatingWebhookConfiguration ingress-nginx-admission
sleep 15
kubectl delete job.batch/ingress-nginx-admission-patch -n kube-router

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
find ./CLT/ -type f -exec sed -i -e "s/kube-one/$CLUSTER/g" {} \;

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
