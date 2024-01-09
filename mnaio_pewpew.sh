#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
  echo 'be root pls'
  exit 1
fi

#### config ####

WANT_HOST_DISTRIB_CODENAME="jammy"
GUEST_OS_IMAGE="http://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"

STORAGE_DEVICES="/dev/sdc /dev/sdd"

VM_CPUS=4
VM_RAM="$(( 8 * 1024 ))"
VM_DISK="20G"

NUM_CONTROLLER=3
NUM_COMPUTE=3
NUM_NETWORK=3
NUM_STORAGE=3

NUM_STORAGE_VOLS=4
SIZE_STORAGE_VOL="50G"


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

#### start work ####

if [[ ! -f "/root/.ssh/id_rsa" ]] ; then
  ssh-keygen -f /root/.ssh/id_rsa -P ""
fi

apt -y install libvirt-daemon-system virtinst jq make python3-venv bridge-utils genisoimage pv


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

if ! which helm >&- ; then
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

PREFIX="controller"
for SEQ in $( seq 1 ${NUM_CONTROLLER} ) ; do
  NAME="${PREFIX}${SEQ}"
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
      - $(cat ~/.ssh/id_rsa.pub)
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: sudo
    shell: /bin/bash
EOF

  genisoimage -output cidata.iso -V cidata -r -J user-data meta-data

  lvcreate --type raid0 -L "${VM_DISK}" --nosync -n "lv_${NAME}" vg_libvirt
  pv /root/jammy-server-cloudimg-amd64.raw | dd bs=16M of="/dev/vg_libvirt/lv_${NAME}"

  virt-install \
    --name="${NAME}" \
    --ram="${VM_RAM}" \
    --vcpus="${VM_CPUS}" \
    --import \
    --disk path=/dev/vg_libvirt/lv_${NAME},bus=virtio,sparse=false,format=raw \
    --disk path=/var/lib/libvirt/qemu/cloud-init/${NAME}/cidata.iso,device=cdrom \
    --os-variant=ubuntu22.04 \
    --network bridge=virbr0,model=virtio \
    --graphics none \
    --serial file,path=/var/lib/libvirt/qemu/console/${NAME}.log \
    --noautoconsole
done

PREFIX="compute"
for SEQ in $( seq 1 ${NUM_COMPUTE} ) ; do
  NAME="${PREFIX}${SEQ}"
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
      - $(cat ~/.ssh/id_rsa.pub)
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: sudo
    shell: /bin/bash
EOF

  genisoimage -output cidata.iso -V cidata -r -J user-data meta-data

  lvcreate --type raid0 -L "${VM_DISK}" --nosync -n "lv_${NAME}" vg_libvirt
  pv /root/jammy-server-cloudimg-amd64.raw | dd bs=16M of="/dev/vg_libvirt/lv_${NAME}"

  virt-install \
    --name="${NAME}" \
    --ram="${VM_RAM}" \
    --vcpus="${VM_CPUS}" \
    --import \
    --disk path=/dev/vg_libvirt/lv_${NAME},bus=virtio,sparse=false,format=raw \
    --disk path=/var/lib/libvirt/qemu/cloud-init/${NAME}/cidata.iso,device=cdrom \
    --os-variant=ubuntu22.04 \
    --network bridge=virbr0,model=virtio \
    --graphics none \
    --serial file,path=/var/lib/libvirt/qemu/console/${NAME}.log \
    --noautoconsole
done

PREFIX="network"
for SEQ in $( seq 1 ${NUM_NETWORK} ) ; do
  NAME="${PREFIX}${SEQ}"
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
      - $(cat ~/.ssh/id_rsa.pub)
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: sudo
    shell: /bin/bash
EOF

  genisoimage -output cidata.iso -V cidata -r -J user-data meta-data

  lvcreate --type raid0 -L "${VM_DISK}" --nosync -n "lv_${NAME}" vg_libvirt
  pv /root/jammy-server-cloudimg-amd64.raw | dd bs=16M of="/dev/vg_libvirt/lv_${NAME}"

  virt-install \
    --name="${NAME}" \
    --ram="${VM_RAM}" \
    --vcpus="${VM_CPUS}" \
    --import \
    --disk path=/dev/vg_libvirt/lv_${NAME},bus=virtio,sparse=false,format=raw \
    --disk path=/var/lib/libvirt/qemu/cloud-init/${NAME}/cidata.iso,device=cdrom \
    --os-variant=ubuntu22.04 \
    --network bridge=virbr0,model=virtio \
    --graphics none \
    --serial file,path=/var/lib/libvirt/qemu/console/${NAME}.log \
    --noautoconsole
done

PREFIX="storage"
for SEQ in $( seq 1 ${NUM_STORAGE} ) ; do
  NAME="${PREFIX}${SEQ}"
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
      - $(cat ~/.ssh/id_rsa.pub)
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    groups: sudo
    shell: /bin/bash
EOF

  genisoimage -output cidata.iso -V cidata -r -J user-data meta-data

  lvcreate --type raid0 -L "${VM_DISK}" --nosync -n "lv_${NAME}" vg_libvirt
  pv /root/jammy-server-cloudimg-amd64.raw | dd bs=16M of="/dev/vg_libvirt/lv_${NAME}"

  EXTRA_DISKS=""
  for STORAGE_VOL in $( seq 1 ${NUM_STORAGE_VOLS} ) ; do
    lvcreate --type raid0 -L "${SIZE_STORAGE_VOL}" --nosync -n "lv_${NAME}_${STORAGE_VOL}" vg_libvirt
    EXTRA_DISKS="${EXTRA_DISKS} --disk path=/dev/vg_libvirt/lv_${NAME}_${STORAGE_VOL},bus=virtio,sparse=false,format=raw"
  done

  virt-install \
    --name="${NAME}" \
    --ram="${VM_RAM}" \
    --vcpus="${VM_CPUS}" \
    --import \
    --disk path=/dev/vg_libvirt/lv_${NAME},bus=virtio,sparse=false,format=raw \
    --disk path=/var/lib/libvirt/qemu/cloud-init/${NAME}/cidata.iso,device=cdrom \
    ${EXTRA_DISKS} \
    --os-variant=ubuntu22.04 \
    --network bridge=virbr0,model=virtio \
    --graphics none \
    --serial file,path=/var/lib/libvirt/qemu/console/${NAME}.log \
    --noautoconsole

done


#### TODO: generate an inventory file ####
