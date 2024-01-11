#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
  echo 'be root pls'
  exit 1
fi

#### config ####

WANT_HOST_DISTRIB_CODENAME="jammy"
GUEST_OS_IMAGE="http://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"

STORAGE_DEVICES="/dev/sdc /dev/sdd"

CLUSTER_NAME="lab.local"

VM_TYPES="utility controller compute network storage"

declare -A NUM_VMS
NUM_VMS["utility"]=1
NUM_VMS["controller"]=3
NUM_VMS["compute"]=4
NUM_VMS["network"]=3
NUM_VMS["storage"]=3

declare -A VM_CPUS
VM_CPUS["utility"]=2
VM_CPUS["controller"]=4
VM_CPUS["compute"]=6
VM_CPUS["storage"]=2
VM_CPUS["network"]=2

declare -A VM_RAM
VM_RAM["utility"]=4
VM_RAM["controller"]=8
VM_RAM["compute"]=8
VM_RAM["storage"]=4
VM_RAM["network"]=4

declare -A VM_ROOT_DISK
VM_ROOT_DISK["utility"]=20
VM_ROOT_DISK["controller"]=20
VM_ROOT_DISK["compute"]=20
VM_ROOT_DISK["storage"]=20
VM_ROOT_DISK["network"]=20

declare -A VM_EXTRA_DISKS
VM_EXTRA_DISKS["storage"]=4

declare -A VM_EXTRA_DISKS_SIZE
VM_EXTRA_DISKS_SIZE["storage"]="50"

# Eventually we'll do public/private bridges but for now...
LIBVIRT_PUBLIC_BRIDGE_NAME="default"
LIBVIRT_PUBLIC_BRIDGE_DEVICE="virbr0"
LIBVIRT_PRIVATE_BRIDGE_NAME=""
LIBVIRT_PRIVATE_BRIDGE_DEVICE=""

SLEEP_BETWEEN_VMS=0

#### helpers ####

reboot_and_rerun () {
  chmod +x $(realpath $0)
  cat > /etc/systemd/system/mnaio_pewpew.service <<EOF
[Service]
ExecStart=$(realpath $0)
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=default.target
EOF
  systemctl daemon-reload
  systemctl enable mnaio_pewpew.service
  reboot
}


#### be nice ####

if (systemctl -q is-enabled mnaio_pewpew.service 2>&-) ; then
  systemctl disable mnaio_pewpew.service
fi

if [[ -f /etc/systemd/system/mnaio_pewpew.service ]] ; then
  rm /etc/systemd/system/mnaio_pewpew.service
fi


#### do it in a tmux ####

if [[ ! -n ${TMUX} ]] ; then
  echo not tmuxin
  tmux new-session -s mnaio_pewpew -d
  tmux send-keys -t mnaio_pewpew C-c
  tmux send-keys -t mnaio_pewpew "bash $(realpath $0)" C-m
  if [[ -t 1 ]] ; then tmux attach -t mnaio_pewpew ; else echo "not a terminal"; fi
  exit 0
else
  echo tmuxin
fi

set -euf
set -o pipefail


#### get space ####

for STORAGE_DEVICE in ${STORAGE_DEVICES} ; do
  if [[ ! $(pvs ${STORAGE_DEVICE}) ]] ; then
    pvcreate ${STORAGE_DEVICE}
  fi
done

if [[ ! $(vgs vg_libvirt) ]] ; then
  vgcreate vg_libvirt ${STORAGE_DEVICES}
fi


#### update stuff ####

apt update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" dist-upgrade -q -y --allow-downgrades --allow-remove-essential --allow-change-held-packages

if [[ -f /var/run/reboot-required ]] ; then
  cat /var/run/reboot-required
  reboot_and_rerun
fi

source /etc/lsb-release

if [[ "${DISTRIB_CODENAME}" != "${WANT_HOST_DISTRIB_CODENAME}" ]] ; then
  do-release-upgrade -m server -f DistUpgradeViewNonInteractive
  reboot_and_rerun
fi


#### prereqs ####

if [[ ! -f "/root/.ssh/id_rsa" ]] ; then
  ssh-keygen -f /root/.ssh/id_rsa -P ""
fi

apt -y install libvirt-daemon-system virtinst jq make python3-venv bridge-utils genisoimage pv

#### make vms ####

cd /tmp/
if [[ ! -f /tmp/jammy-server-cloudimg-amd64.img ]] ; then
  wget http://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
fi
qemu-img convert jammy-server-cloudimg-amd64.img jammy-server-cloudimg-amd64.raw

mkdir -p /var/lib/libvirt/qemu/console
chown libvirt-qemu:kvm /var/lib/libvirt/qemu/console

mkdir -p /var/lib/libvirt/qemu/cloud-init
chown libvirt-qemu:kvm /var/lib/libvirt/qemu/cloud-init

for VM_TYPE in ${VM_TYPES} ; do
  echo
  for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
    NAME="${VM_TYPE}${SEQ}"
    FQDN="${NAME}.${CLUSTER_NAME}"
    sed -i "/ ${FQDN}$/d" /etc/hosts

    echo "==> ${NAME} <=="
    mkdir -p "/var/lib/libvirt/qemu/cloud-init/${NAME}"
    cd "/var/lib/libvirt/qemu/cloud-init/${NAME}"

    cat <<EOF > meta-data
instance-id: ${NAME}
local-hostname: ${NAME}
EOF

    cat <<EOF > user-data
#cloud-config

users:
  - name: ubuntu
    ssh_authorized_keys:
      - >-
        $(cat /root/.ssh/id_rsa.pub)
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    groups: sudo
    shell: /bin/bash
EOF

    genisoimage -quiet -output cidata.iso -V cidata -r -J user-data meta-data

    EXTRA_DISKS=""
    if [[ ! -z ${VM_EXTRA_DISKS[${VM_TYPE}]-} ]] ; then
      for EXTRA_DISK in $( seq 1 ${VM_EXTRA_DISKS[${VM_TYPE}]} ) ; do
        lvcreate --type raid0 -L "${VM_EXTRA_DISKS_SIZE[${VM_TYPE}]}G" --nosync -n "lv_${NAME}_${EXTRA_DISK}" vg_libvirt
        EXTRA_DISKS="${EXTRA_DISKS} --disk path=/dev/vg_libvirt/lv_${NAME}_${EXTRA_DISK},bus=virtio,sparse=false,format=raw"
      done
    fi

    lvcreate --type raid0 -L "${VM_ROOT_DISK["${VM_TYPE}"]}G" --nosync -n "lv_${NAME}" vg_libvirt
    dd if=/root/jammy-server-cloudimg-amd64.raw bs=16M of="/dev/vg_libvirt/lv_${NAME}" status=progress

    virt-install \
      --name="${NAME}" \
      --ram="$(( ${VM_RAM["${VM_TYPE}"]} * 1024 ))" \
      --vcpus="${VM_CPUS["${VM_TYPE}"]}" \
      --import \
      --disk path=/dev/vg_libvirt/lv_${NAME},bus=virtio,sparse=false,format=raw \
      --disk path=/var/lib/libvirt/qemu/cloud-init/${NAME}/cidata.iso,device=cdrom \
      ${EXTRA_DISKS} \
      --os-variant=ubuntu22.04 \
      --network bridge=virbr0,model=virtio \
      --graphics none \
      --serial file,path=/var/lib/libvirt/qemu/console/${NAME}.log \
      --noautoconsole

    sleep ${SLEEP_BETWEEN_VMS}
  done
done

echo "waiting for vms to boot..."
for VM_TYPE in ${VM_TYPES} ; do
  for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
    NAME="${VM_TYPE}${SEQ}"
    FQDN="${NAME}.${CLUSTER_NAME}"
    echo "Checking ${FQDN} ..."
    until grep -q "${NAME} login:" /var/lib/libvirt/qemu/console/${NAME}.log ; do
      echo "Still waiting for ${FQDN} to boot..."
      sleep 2
    done
    echo "${FQDN} OK"
  done
done


#### make inventory ####

INVENTORY=$(mktemp)

echo "[all]" > ${INVENTORY}

for VM_TYPE in ${VM_TYPES} ; do
  for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
    NAME="${VM_TYPE}${SEQ}"
    FQDN="${NAME}.${CLUSTER_NAME}"
    echo "Adding ${FQDN} to inventory"
    # taking the long way around because sometimes dnsmasq gets confused about names
    #IP="$(virsh net-dhcp-leases default | grep ${NAME} | awk '{print $5}' | cut -d'/' -f1)"
    IP="$(virsh net-dhcp-leases default | grep $(virsh domiflist ${NAME} | awk "/virbr0/ {print \$5}") | awk '{print $5}' | cut -d'/' -f1)"
    echo "${FQDN} ansible_host=${IP} ip=${IP} ansible_user=ubuntu ansible_become=true" >> ${INVENTORY}
    echo "${IP} ${NAME} ${FQDN}" >> /etc/hosts
  done
done

cat <<EOF >> ${INVENTORY}
[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
cluster_name=${CLUSTER_NAME}
download_run_once=True
#kube_ovn_iface=ens4
#kube_ovn_default_interface_name=ens3
EOF

echo "[bastion]" >> ${INVENTORY}
WANT_TYPES="bastion"
for VM_TYPE in ${WANT_TYPES} ; do
  if [[ ! -z ${NUM_VMS[${VM_TYPE}]-} ]] ; then
    for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
      NAME="${VM_TYPE}${SEQ}"
      FQDN="${NAME}.${CLUSTER_NAME}"
      echo "${FQDN}" >> ${INVENTORY}
    done
  fi
done

echo "[kube_control_plane]" >> ${INVENTORY}
WANT_TYPES="controller"
for VM_TYPE in ${WANT_TYPES} ; do
  if [[ ! -z ${NUM_VMS[${VM_TYPE}]-} ]] ; then
    for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
      NAME="${VM_TYPE}${SEQ}"
      FQDN="${NAME}.${CLUSTER_NAME}"
      echo "${FQDN}" >> ${INVENTORY}
    done
  fi
done

echo "[etcd]" >> ${INVENTORY}
WANT_TYPES="controller"
for VM_TYPE in ${WANT_TYPES} ; do
  if [[ ! -z ${NUM_VMS[${VM_TYPE}]-} ]] ; then
    for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
      NAME="${VM_TYPE}${SEQ}"
      FQDN="${NAME}.${CLUSTER_NAME}"
      echo "${FQDN}" >> ${INVENTORY}
    done
  fi
done

echo "[kube_node]" >> ${INVENTORY}
WANT_TYPES="compute network storage"
for VM_TYPE in ${WANT_TYPES} ; do
  if [[ ! -z ${NUM_VMS[${VM_TYPE}]-} ]] ; then
    for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
      NAME="${VM_TYPE}${SEQ}"
      FQDN="${NAME}.${CLUSTER_NAME}"
      echo "${FQDN}" >> ${INVENTORY}
    done
  fi
done

cat <<EOF >> ${INVENTORY}
[k8s_cluster:children]
kube_control_plane
kube_node
EOF


#### get the helm stuff ####

if [[ ! -d "/opt/genestack" ]] ; then
  git clone --recurse-submodules -j4 https://github.com/cloudnull/genestack /opt/genestack
fi

export LC_ALL=C.UTF-8
mkdir -p ~/.venvs
python3 -m venv ~/.venvs/kubespray
~/.venvs/kubespray/bin/pip install pip  --upgrade
source ~/.venvs/kubespray/bin/activate
pip install -r /opt/genestack/submodules/kubespray/requirements.txt
cd /opt/genestack/submodules/kubespray/inventory
ln -sf /opt/genestack/openstack-flex .


#### copy inventory ####

cp ${INVENTORY} /opt/genestack/inventory.ini
cp ${INVENTORY} /opt/genestack/openstack-flex/inventory.ini
cp ${INVENTORY} /opt/genestack/submodules/kubespray/inventory/inventory.ini
rm ${INVENTORY}
INVENTORY=/opt/genestack/openstack-flex/inventory.ini

if [[ -z "$(which helm)" ]] ; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

export CONTAINER_DISTRO_NAME=ubuntu
export CONTAINER_DISTRO_VERSION=jammy
export OPENSTACK_RELEASE=2023.1
export OSH_DEPLOY_MULTINODE=True

cd /opt/genestack/submodules/openstack-helm
make all

cd /opt/genestack/submodules/openstack-helm-infra
make all

cd /opt/genestack/submodules/kubespray
#ansible -m wait_for -a 'port=22 timeout=300' -i ${INVENTORY} all
# set fqdn to make kube happy
ansible -m shell -a 'hostnamectl set-hostname {{ inventory_hostname }}' -i ${INVENTORY} all
# force facts (on dirty systems old facts can confuse ansible)
ansible -m setup -i ${INVENTORY} all

ansible-playbook -i ${INVENTORY} cluster.yml


#### steal the cluster tools and secrets so we can run them from here ####

mkdir -p /root/.kube
chmod 0700 /root/.kube
ansible 'kube_control_plane[0]' -i ${INVENTORY} -m fetch -a 'src=/usr/local/bin/kubectl dest=/usr/local/bin/kubectl flat=true'
ansible 'kube_control_plane[0]' -i ${INVENTORY} -m fetch -a 'src=/root/.kube/config dest=/root/.kube/config flat=true'
chmod +x /usr/local/bin/kubectl
chmod 0600 /root/.kube/config
sed -i "s/127\.0\.0\.1/controller1.${CLUSTER_NAME}/" /root/.kube/config

cd ~
kubectl get nodes -o wide


#### start configuring for openstack ####

kubectl taint nodes $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o 'jsonpath={.items[*].metadata.name}' ) node-role.kubernetes.io/control-plane:NoSchedule-

# Label the storage nodes - optional and only used when deploying ceph for K8S infrastructure shared storage
kubectl label node $(kubectl get nodes | awk '/ceph/ {print $1}') role=storage-node

# Label the openstack controllers
kubectl label node $(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' -o 'jsonpath={.items[*].metadata.name}') openstack-control-plane=enabled

# Label the openstack compute nodes
kubectl label node $(kubectl get nodes | awk '/compute/ {print $1}') openstack-compute-node=enabled

# Label the openstack network nodes
kubectl label node $(kubectl get nodes | awk '/network/ {print $1}') openstack-network-node=enabled

# Label the openstack storage nodes
kubectl label node $(kubectl get nodes | awk '/storage/ {print $1}') openstack-storage-node=enabled

# With OVN we need the compute nodes to be "network" nodes as well. While they will be configured for networking, they wont be gateways.
kubectl label node $(kubectl get nodes | awk '/compute/ {print $1}') openstack-network-node=enabled

# Label all workers - Recommended and used when deploying Kubernetes specific services
kubectl label node $(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' -o 'jsonpath={.items[*].metadata.name}') node-role.kubernetes.io/worker=worker

kubectl get nodes -o wide


#### we're kubin now, do the ceph thing ####

kubectl apply -k /opt/genestack/kustomize/rook-operator/
kubectl apply -k /opt/genestack/kustomize/rook-cluster/

# todo: wait for this to be ready
kubectl --namespace rook-ceph get cephclusters.ceph.rook.io
