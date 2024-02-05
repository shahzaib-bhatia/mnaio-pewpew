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

export CONTAINER_DISTRO_NAME=ubuntu
export CONTAINER_DISTRO_VERSION=jammy
export OPENSTACK_RELEASE=2023.1
export OSH_DEPLOY_MULTINODE=True

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

# Take these devices on the storage nodes for the cinder VG
# the rest will get borg'd by rook
CINDER_LVM_PVS="/dev/vdb /dev/vdc"

# 1 for safer 0 for faster
VM_ROOT_DISKS_RAID=0
VM_EXTRA_DISKS_RAID=0

# Doing /24s because 200 vms ought to be enough for anybody...
# and it means we can lazily just string assemble the addrs
MGMT_BRIDGE="br-mgmt"
MGMT_IP_PREFIX="192.168.100"
MGMT_MAC_PREFIX="de:ad:be:ef:00"

KUBE_BRIDGE="br-kube"
KUBE_IP_PREFIX="192.168.120"
KUBE_MAC_PREFIX="de:ad:be:ef:11"

BREX_BRIDGE="br-ex"
# br-ex IPs go to neutron not the vms but we still need the space reserved
BREX_IP_PREFIX="192.168.140" 
BREX_MAC_PREFIX="de:ad:be:ef:22"

STOR_BRIDGE="br-storage"
STOR_IP_PREFIX="192.168.160"
STOR_MAC_PREFIX="de:ad:be:ef:33"

IPTABLES_V4_CONF="/etc/iptables/rules.v4"
IPTABLES_V6_CONF="/etc/iptables/rules.v6"

LOG_FILE="/root/pewpew.log"

TEMP_INVENTORY="$(mktemp)"
INVENTORY="/opt/genestack/inventory.ini"

# these get filled in later
LIST_OF_VMS=""
declare -A VM_IP_MGMT
declare -A VM_MAC_MGMT
declare -A VM_IP_KUBE
declare -A VM_MAC_KUBE
declare -A VM_IP_BREX
declare -A VM_MAC_BREX
declare -A VM_IP_STOR
declare -A VM_MAC_STOR

# sometimes bash gets confused after a reboot
if [[ -z "${HOME}" ]] ; then
  export HOME="/root"
fi

# supposedly this is a default too
export KUBECONFIG='/root/.kube/config'

#### helpers ####

wrap_func () {
  local START="$(date +%s)"
  echo "$(date --rfc-3339=seconds) - Starting $@" >> ${LOG_FILE}
  $@
  local END="$(date +%s)"
  echo "$(date --rfc-3339=seconds) - Finished $@ (took $(( ${END} - ${START} )) seconds)" >> ${LOG_FILE}
}

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

wait_for_a_kube_thing () {
  NAMESPACE=$1
  OBJECT_TYPE=$2
  OBJECT_NAME=$3
  CONDITION_PATH=${4:-}
  CONDITION_WANT=${5:-True}
  SLEEP=${6:-1}

  # wait for object to exist
  until kubectl -n ${NAMESPACE} get ${OBJECT_TYPE} ${OBJECT_NAME} 2>&- ; do 
    echo "Waiting for ${OBJECT_TYPE} ${OBJECT_NAME} to exist..."
    sleep 1
  done

  # print condition
  kubectl -n ${NAMESPACE} get ${OBJECT_TYPE} ${OBJECT_NAME} -o json | jq -c '.status'

  # wait for condition to be met
  if [[ ! -z ${CONDITION_PATH} ]] ; then
    # The sane thing would be to do "kubectl wait" but it can't filter for objects in an array until 1.31 and this initially targets 1.26
    # ref: https://github.com/kubernetes/kubernetes/pull/118748
    # And the whole reason we're in this function is "kubectl wait" can't wait for a thing that doesn't exist yet so we might as well keep at it
    # until kubectl -n ${NAMESPACE} wait ${OBJECT_TYPE} ${OBJECT_NAME} --for=jsonpath="${CONDITION_PATH}"=${CONDITION_WANT} --timeout 10s ; do
    until [[ "$(kubectl -n ${NAMESPACE} get ${OBJECT_TYPE} ${OBJECT_NAME} -o json | jq -r "${CONDITION_PATH}")" == "${CONDITION_WANT}" ]] ; do
      echo "Still waiting for ${NAMESPACE} ${OBJECT_TYPE} ${OBJECT_NAME} check back in ${SLEEP}..."
      echo "  ${OBJECT_NAME} ${CONDITION_PATH} = $(kubectl -n ${NAMESPACE} get ${OBJECT_TYPE} ${OBJECT_NAME} -o json | jq -r "${CONDITION_PATH}") want ${CONDITION_WANT}"
      kubectl -n ${NAMESPACE} get ${OBJECT_TYPE} ${OBJECT_NAME}
      sleep ${SLEEP}
    done
  kubectl -n ${NAMESPACE} get ${OBJECT_TYPE} ${OBJECT_NAME} -o json | jq -c '.status'
  fi

  echo "Finished waiting for ${NAMESPACE} ${OBJECT_TYPE} ${OBJECT_NAME}"

}

remove_service () {
  if (systemctl -q is-enabled mnaio_pewpew.service 2>&-) ; then
    systemctl disable mnaio_pewpew.service
  fi

  if [[ -f /etc/systemd/system/mnaio_pewpew.service ]] ; then
    rm /etc/systemd/system/mnaio_pewpew.service
  fi
}

force_tmux () {
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
}

setup_host () {
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

  DEBIAN_FRONTEND=noninteractive apt-get -y install libvirt-daemon-system virtinst jq make python3-venv bridge-utils genisoimage pv pwgen iptables-persistent


  #### networking ####

  HOST_MGMT_IP="${MGMT_IP_PREFIX}.1"
  HOST_KUBE_IP="${KUBE_IP_PREFIX}.1"
  HOST_BREX_IP="${BREX_IP_PREFIX}.1"
  HOST_STOR_IP="${STOR_IP_PREFIX}.1"

  MGMT_NET="${MGMT_IP_PREFIX}.0/24"
  KUBE_NET="${KUBE_IP_PREFIX}.0/24"
  BREX_NET="${BREX_IP_PREFIX}.0/24"
  STOR_NET="${STOR_IP_PREFIX}.0/24"

  if ip link show dev ${MGMT_BRIDGE} 2>&- ; then ip link set ${MGMT_BRIDGE} down && brctl delbr ${MGMT_BRIDGE} ; fi
  if ip link show dev ${KUBE_BRIDGE} 2>&- ; then ip link set ${KUBE_BRIDGE} down && brctl delbr ${KUBE_BRIDGE} ; fi
  if ip link show dev ${BREX_BRIDGE} 2>&- ; then ip link set ${BREX_BRIDGE} down && brctl delbr ${BREX_BRIDGE} ; fi
  if ip link show dev ${STOR_BRIDGE} 2>&- ; then ip link set ${STOR_BRIDGE} down && brctl delbr ${STOR_BRIDGE} ; fi

  brctl addbr ${MGMT_BRIDGE}
  brctl addbr ${KUBE_BRIDGE}
  brctl addbr ${BREX_BRIDGE}
  brctl addbr ${STOR_BRIDGE}

  ip addr add ${HOST_MGMT_IP}/24 dev ${MGMT_BRIDGE}
  ip addr add ${HOST_KUBE_IP}/24 dev ${KUBE_BRIDGE}
  ip addr add ${HOST_BREX_IP}/24 dev ${BREX_BRIDGE}
  #ip addr add ${HOST_STOR_IP}/24 dev ${STOR_BRIDGE}

  ip link set ${MGMT_BRIDGE} up
  ip link set ${KUBE_BRIDGE} up
  ip link set ${BREX_BRIDGE} up
  ip link set ${STOR_BRIDGE} up

  cat <<EOF > ${IPTABLES_V4_CONF}
*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
COMMIT

*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:AIO_FWI - [0:0]
:AIO_FWO - [0:0]
:AIO_FWX - [0:0]
:AIO_INP - [0:0]
:AIO_OUT - [0:0]
-A INPUT -i ${MGMT_BRIDGE} -j AIO_INP
-A INPUT -i ${KUBE_BRIDGE} -j AIO_INP
-A INPUT -i ${BREX_BRIDGE} -j AIO_INP
-A INPUT -i ${STOR_BRIDGE} -j DROP
-A FORWARD -i ${MGMT_BRIDGE} -o ${MGMT_BRIDGE} -j AIO_FWX
-A FORWARD -i ${KUBE_BRIDGE} -o ${KUBE_BRIDGE} -j AIO_FWX
-A FORWARD -i ${BREX_BRIDGE} -o ${BREX_BRIDGE} -j AIO_FWX
-A FORWARD -o ${MGMT_BRIDGE} -j AIO_FWI
-A FORWARD -o ${KUBE_BRIDGE} -j AIO_FWI
-A FORWARD -o ${BREX_BRIDGE} -j AIO_FWI
-A FORWARD -i ${MGMT_BRIDGE} -j AIO_FWO
-A FORWARD -i ${KUBE_BRIDGE} -j AIO_FWO
-A FORWARD -i ${BREX_BRIDGE} -j AIO_FWO
-A OUTPUT  -o ${MGMT_BRIDGE} -j AIO_OUT
-A OUTPUT  -o ${KUBE_BRIDGE} -j AIO_OUT
-A OUTPUT  -o ${BREX_BRIDGE} -j AIO_OUT
-A AIO_FWI -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A AIO_FWI -j REJECT --reject-with icmp-port-unreachable
-A AIO_FWO -i ${MGMT_BRIDGE} -s ${MGMT_NET} -j ACCEPT
-A AIO_FWO -i ${KUBE_BRIDGE} -s ${KUBE_NET} -j REJECT --reject-with icmp-port-unreachable
-A AIO_FWO -i ${BREX_BRIDGE} -s ${BREX_NET} -j ACCEPT
-A AIO_FWO -j REJECT --reject-with icmp-port-unreachable
-A AIO_FWX -j ACCEPT
-A AIO_INP -p udp -m udp --dport 53 -j ACCEPT
-A AIO_INP -p tcp -m tcp --dport 53 -j ACCEPT
-A AIO_INP -p udp -m udp --dport 67 -j ACCEPT
-A AIO_INP -p tcp -m tcp --dport 67 -j ACCEPT
-A AIO_OUT -p udp -m udp --dport 53 -j ACCEPT
-A AIO_OUT -p tcp -m tcp --dport 53 -j ACCEPT
-A AIO_OUT -p udp -m udp --dport 68 -j ACCEPT
-A AIO_OUT -p tcp -m tcp --dport 68 -j ACCEPT
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
:AIO_PRT - [0:0]
-A POSTROUTING -j AIO_PRT
-A AIO_PRT -s ${MGMT_NET} -d 224.0.0.0/24 -j RETURN
-A AIO_PRT -s ${KUBE_NET} -d 224.0.0.0/24 -j RETURN
-A AIO_PRT -s ${BREX_NET} -d 224.0.0.0/24 -j RETURN
-A AIO_PRT -s ${MGMT_NET} -d 255.255.255.255/32 -j RETURN
-A AIO_PRT -s ${KUBE_NET} -d 255.255.255.255/32 -j RETURN
-A AIO_PRT -s ${BREX_NET} -d 255.255.255.255/32 -j RETURN
-A AIO_PRT -s ${MGMT_NET} ! -d ${MGMT_NET} -p tcp -j MASQUERADE --to-ports 1024-65535
-A AIO_PRT -s ${KUBE_NET} ! -d ${KUBE_NET} -p tcp -j MASQUERADE --to-ports 1024-65535
-A AIO_PRT -s ${BREX_NET} ! -d ${BREX_NET} -p tcp -j MASQUERADE --to-ports 1024-65535
-A AIO_PRT -s ${MGMT_NET} ! -d ${MGMT_NET} -p udp -j MASQUERADE --to-ports 1024-65535
-A AIO_PRT -s ${KUBE_NET} ! -d ${KUBE_NET} -p udp -j MASQUERADE --to-ports 1024-65535
-A AIO_PRT -s ${BREX_NET} ! -d ${BREX_NET} -p udp -j MASQUERADE --to-ports 1024-65535
-A AIO_PRT -s ${MGMT_NET} ! -d ${MGMT_NET} -j MASQUERADE
-A AIO_PRT -s ${KUBE_NET} ! -d ${KUBE_NET} -j MASQUERADE
-A AIO_PRT -s ${BREX_NET} ! -d ${BREX_NET} -j MASQUERADE
COMMIT
EOF

  cat <<EOF > ${IPTABLES_V6_CONF}
*mangle
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
COMMIT

*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i ${MGMT_BRIDGE} -j REJECT --reject-with icmp6-adm-prohibited
-A INPUT -i ${KUBE_BRIDGE} -j REJECT --reject-with icmp6-adm-prohibited
-A INPUT -i ${BREX_BRIDGE} -j REJECT --reject-with icmp6-adm-prohibited
-A INPUT -i ${STOR_BRIDGE} -j REJECT --reject-with icmp6-adm-prohibited
COMMIT

*nat
:PREROUTING DROP [0:0]
:INPUT DROP [0:0]
:OUTPUT DROP [0:0]
:POSTROUTING DROP [0:0]
COMMIT
EOF

  iptables-restore -v < ${IPTABLES_V4_CONF}
  ip6tables-restore -v < ${IPTABLES_V6_CONF}

}

make_vms () {
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
    for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
      NAME="${VM_TYPE}${SEQ}"
      FQDN="${NAME}.${CLUSTER_NAME}"
      sed -i "/ ${FQDN}$/d" /etc/hosts

      echo "==> ${NAME} <=="

      LIST_OF_VMS="${LIST_OF_VMS}${NAME} "
      # Get a (global) sequence number starting at 10
      NUM=$(( 9 + $(wc -w <<< ${LIST_OF_VMS} ) ))
      HEX_NUM="$(printf %02x ${NUM})"
      VM_IP_MGMT["${NAME}"]="${MGMT_IP_PREFIX}.${NUM}"
      VM_MAC_MGMT[${NAME}]="${MGMT_MAC_PREFIX}:${HEX_NUM}"
      VM_IP_KUBE[${NAME}]="${KUBE_IP_PREFIX}.${NUM}"
      VM_MAC_KUBE[${NAME}]="${KUBE_MAC_PREFIX}:${HEX_NUM}"
      VM_IP_BREX[${NAME}]="${BREX_IP_PREFIX}.${NUM}"
      VM_MAC_BREX[${NAME}]="${BREX_MAC_PREFIX}:${HEX_NUM}"
      VM_IP_STOR[${NAME}]="${STOR_IP_PREFIX}.${NUM}"
      VM_MAC_STOR[${NAME}]="${STOR_MAC_PREFIX}:${HEX_NUM}"

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

    cat <<EOF > network-config
network:
  version: 2
  ethernets:
    eth0:
      match:
        macaddress: '${VM_MAC_MGMT[${NAME}]}'
      set-name: eth0
    eth1:
      match:
        macaddress: '${VM_MAC_KUBE[${NAME}]}'
      set-name: eth1
    eth2:
      match:
        macaddress: '${VM_MAC_BREX[${NAME}]}'
      set-name: eth2
    eth3:
      match:
        macaddress: '${VM_MAC_STOR[${NAME}]}'
      set-name: eth3
  bridges:
    ${MGMT_BRIDGE}:
      interfaces: [eth0]
      addresses: [ ${VM_IP_MGMT[${NAME}]}/24 ]
      nameservers:
        search: [${CLUSTER_NAME}]
        addresses: [69.20.0.164, 1.1.1.1]
      routes:
        - to: default
          via: ${HOST_MGMT_IP}
    ${KUBE_BRIDGE}:
      interfaces: [eth1]
      addresses: [ ${VM_IP_KUBE[${NAME}]}/24 ]
    ${STOR_BRIDGE}:
      interfaces: [eth3]
      addresses: [ ${VM_IP_STOR[${NAME}]}/24 ]
EOF

      genisoimage -quiet -output cidata.iso -V cidata -r -J user-data meta-data network-config

      EXTRA_DISKS=""
      if [[ ! -z ${VM_EXTRA_DISKS[${VM_TYPE}]-} ]] ; then
        for EXTRA_DISK in $( seq 1 ${VM_EXTRA_DISKS[${VM_TYPE}]} ) ; do
          lvcreate --type raid${VM_EXTRA_DISKS_RAID} -L "${VM_EXTRA_DISKS_SIZE[${VM_TYPE}]}G" --nosync -n "lv_${NAME}_${EXTRA_DISK}" vg_libvirt
          EXTRA_DISKS="${EXTRA_DISKS} --disk path=/dev/vg_libvirt/lv_${NAME}_${EXTRA_DISK},bus=virtio,sparse=false,format=raw"
        done
      fi

      lvcreate --type raid${VM_ROOT_DISKS_RAID} -L "${VM_ROOT_DISK["${VM_TYPE}"]}G" --nosync -n "lv_${NAME}" vg_libvirt
      dd if=/root/jammy-server-cloudimg-amd64.raw bs=16M of="/dev/vg_libvirt/lv_${NAME}"

      virt-install \
        --name="${NAME}" \
        --ram="$(( ${VM_RAM["${VM_TYPE}"]} * 1024 ))" \
        --vcpus="${VM_CPUS["${VM_TYPE}"]}" \
        --import \
        --disk path=/dev/vg_libvirt/lv_${NAME},bus=virtio,sparse=false,format=raw \
        --disk path=/var/lib/libvirt/qemu/cloud-init/${NAME}/cidata.iso,device=cdrom \
        ${EXTRA_DISKS} \
        --os-variant=ubuntu22.04 \
        --network bridge=${MGMT_BRIDGE},mac=${VM_MAC_MGMT[${NAME}]},model=virtio \
        --network bridge=${KUBE_BRIDGE},mac=${VM_MAC_KUBE[${NAME}]},model=virtio \
        --network bridge=${BREX_BRIDGE},mac=${VM_MAC_BREX[${NAME}]},model=virtio \
        --network bridge=${STOR_BRIDGE},mac=${VM_MAC_STOR[${NAME}]},model=virtio \
        --graphics none \
        --serial file,path=/var/lib/libvirt/qemu/console/${NAME}.log \
        --noautoconsole
    done
  done
}

wait_for_vms () {
  echo "waiting for vms to boot..."
  for VM_TYPE in ${VM_TYPES} ; do
    for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
      NAME="${VM_TYPE}${SEQ}"
      FQDN="${NAME}.${CLUSTER_NAME}"
      echo "Checking ${FQDN} ..."
      until grep -q "${NAME} login:" /var/lib/libvirt/qemu/console/${NAME}.log ; do
        echo "Still waiting for ${FQDN} to boot..."
        sleep 1
      done
      echo "${FQDN} OK"
    done
  done
}

make_inventory () {
  echo "[all]" > ${TEMP_INVENTORY}

  for NAME in ${LIST_OF_VMS} ; do
    FQDN="${NAME}.${CLUSTER_NAME}"
    echo "Adding ${FQDN} to inventory"
    echo "${FQDN} ansible_host=${VM_IP_MGMT[${NAME}]} ip=${VM_IP_KUBE[${NAME}]} ansible_user=ubuntu ansible_become=true" >> ${TEMP_INVENTORY}
    echo "${VM_IP_MGMT[${NAME}]} ${NAME} ${FQDN}" >> /etc/hosts
  done

  cat <<EOF >> ${TEMP_INVENTORY}
[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
cluster_name=${CLUSTER_NAME}
# note: for ansible reasons True is a bool and true is a string
kubectl_localhost=True
kubeconfig_localhost=True
download_run_once=True
upstream_dns_servers=["69.20.0.164","1.1.1.1"]
# deps
kube_network_plugin=kube-ovn
cert_manager_enabled=True
kube_proxy_strict_arp=True
metallb_enabled=True
EOF

  echo "[bastion]" >> ${TEMP_INVENTORY}
  WANT_TYPES="bastion"
  for VM_TYPE in ${WANT_TYPES} ; do
    if [[ ! -z ${NUM_VMS[${VM_TYPE}]-} ]] ; then
      for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
        NAME="${VM_TYPE}${SEQ}"
        FQDN="${NAME}.${CLUSTER_NAME}"
        echo "${FQDN}" >> ${TEMP_INVENTORY}
      done
    fi
  done

  echo "[kube_control_plane]" >> ${TEMP_INVENTORY}
  WANT_TYPES="controller"
  for VM_TYPE in ${WANT_TYPES} ; do
    if [[ ! -z ${NUM_VMS[${VM_TYPE}]-} ]] ; then
      for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
        NAME="${VM_TYPE}${SEQ}"
        FQDN="${NAME}.${CLUSTER_NAME}"
        echo "${FQDN}" >> ${TEMP_INVENTORY}
      done
    fi
  done

  echo "[etcd]" >> ${TEMP_INVENTORY}
  WANT_TYPES="controller"
  for VM_TYPE in ${WANT_TYPES} ; do
    if [[ ! -z ${NUM_VMS[${VM_TYPE}]-} ]] ; then
      for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
        NAME="${VM_TYPE}${SEQ}"
        FQDN="${NAME}.${CLUSTER_NAME}"
        echo "${FQDN}" >> ${TEMP_INVENTORY}
      done
    fi
  done

  echo "[kube_node]" >> ${TEMP_INVENTORY}
  WANT_TYPES="compute network storage"
  for VM_TYPE in ${WANT_TYPES} ; do
    if [[ ! -z ${NUM_VMS[${VM_TYPE}]-} ]] ; then
      for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
        NAME="${VM_TYPE}${SEQ}"
        FQDN="${NAME}.${CLUSTER_NAME}"
        echo "${FQDN}" >> ${TEMP_INVENTORY}
      done
    fi
  done

  echo "[cinder_storage_nodes]" >> ${TEMP_INVENTORY}
  WANT_TYPES="storage"
  for VM_TYPE in ${WANT_TYPES} ; do
    if [[ ! -z ${NUM_VMS[${VM_TYPE}]-} ]] ; then
      for SEQ in $( seq 1 ${NUM_VMS[${VM_TYPE}]}) ; do
        NAME="${VM_TYPE}${SEQ}"
        FQDN="${NAME}.${CLUSTER_NAME}"
        echo "${FQDN}" >> ${TEMP_INVENTORY}
      done
    fi
  done

  cat <<EOF >> ${TEMP_INVENTORY}
[k8s_cluster:children]
kube_control_plane
kube_node
EOF
}


get_genestack () {
  if [[ ! -d "/opt/genestack" ]] ; then
    git clone --recurse-submodules -j4 https://github.com/cloudnull/genestack /opt/genestack
  fi

  # kubespray venv
  export LC_ALL=C.UTF-8
  mkdir -p ~/.venvs
  python3 -m venv ~/.venvs/kubespray
  ~/.venvs/kubespray/bin/pip install pip  --upgrade
  source ~/.venvs/kubespray/bin/activate
  pip install -r /opt/genestack/submodules/kubespray/requirements.txt
  cd /opt/genestack/submodules/kubespray/inventory

  # copy inventory to final location
  cp ${TEMP_INVENTORY} ${INVENTORY}
  rm ${TEMP_INVENTORY}

  # get helm if not already installed
  if [[ -z "$(which helm)" ]] ; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

make_genestack () {
  cd /opt/genestack/submodules/openstack-helm
  make all

  cd /opt/genestack/submodules/openstack-helm-infra
  make all

  # override default cluster name
  set +f
  sed -i "s/cluster_domain_suffix: cluster.local/cluster_domain_suffix: ${CLUSTER_NAME}/" /opt/genestack/helm-configs/*/*.yaml
  set -f
}

prepare_vms () {
  source ~/.venvs/kubespray/bin/activate
  # add self to /etc/hosts (sometimes sudo times out due to name resolution)
  ansible -m shell -a "echo 127.0.0.1 {{ inventory_hostname_short }} {{ inventory_hostname }} >> /etc/hosts" -i ${INVENTORY} all
  # set fqdn to make kube happy
  ansible -m shell -a 'hostnamectl set-hostname {{ inventory_hostname }}' -i ${INVENTORY} all
  # force facts (on dirty systems old facts can confuse ansible)
  ansible -m setup -i ${INVENTORY} all
  # add cinder pvs to vg
  ansible -m shell -a "pvcreate ${CINDER_LVM_PVS}" -i ${INVENTORY} cinder_storage_nodes
  ansible -m shell -a "vgcreate cinder-volumes-1 ${CINDER_LVM_PVS}" -i ${INVENTORY} cinder_storage_nodes
}

spray_kube () {
  cd /opt/genestack/submodules/kubespray
  source ~/.venvs/kubespray/bin/activate
  ansible-playbook -i ${INVENTORY} cluster.yml
}

steal_kube_conf () {
  cd /opt/genestack/submodules/kubespray
  source ~/.venvs/kubespray/bin/activate

  # ansible copy has non-overrideable behavior changes based on src/dest strings so we need this to be a dir for ... reasons (it saves an ansible step)
  KUBE_TMP_CONF="$(mktemp --directory)"
  mkdir -p /root/.kube
  chmod 0700 /root/.kube
  ansible 'kube_control_plane[0]' -i ${INVENTORY} -m fetch -a 'src=/usr/local/bin/kubectl dest=/usr/local/bin/kubectl flat=true'
  ansible 'kube_control_plane[0]' -i ${INVENTORY} -m fetch -a "src=/root/.kube/config dest=${KUBE_TMP_CONF}/ flat=true"
  sed "s/127\.0\.0\.1/controller1.${CLUSTER_NAME}/" "${KUBE_TMP_CONF}/config" > /root/.kube/config
  chmod +x /usr/local/bin/kubectl
  chmod 0600 /root/.kube/config

  # now that we have working kubectl here shove the internal ip in the conf and distribute it to cluster members
  KUBE_INT_IP="$(kubectl get service kubernetes -o jsonpath='{.spec.clusterIP}')"
  sed -i "s/127\.0\.0\.1:6443/${KUBE_INT_IP}:443/" "${KUBE_TMP_CONF}/config"
  ansible 'all:!kube_control_plane' -i ${INVENTORY} -m copy -a "src=${KUBE_TMP_CONF}/config dest=/root/.kube/ mode=0600 directory_mode=0700"
  rm "${KUBE_TMP_CONF}/config"
  rmdir ${KUBE_TMP_CONF}
  kubectl get nodes -o wide
}

label_nodes () {
  # un-taint controllers (let openstack control plane sleep on kube's couch) and label nodes
  kubectl taint nodes $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o 'jsonpath={.items[*].metadata.name}' ) node-role.kubernetes.io/control-plane:NoSchedule-

  # Label the storage nodes - optional and only used when deploying ceph for K8S infrastructure shared storage
  kubectl label node $(kubectl get nodes | awk '/storage|ceph/ {print $1}') role=storage-node

  # Label the openstack controllers
  kubectl label node $(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' -o 'jsonpath={.items[*].metadata.name}') openstack-control-plane=enabled

  # Label the openstack compute nodes
  kubectl label node $(kubectl get nodes | awk '/compute/ {print $1}') openstack-compute-node=enabled

  # Label the openstack network nodes
  kubectl label node $(kubectl get nodes | awk '/network/ {print $1}') openstack-network-node=enabled

  # Label the openstack storage nodes
  kubectl label node $(kubectl get nodes | awk '/storage/ {print $1}') openstack-storage-node=enabled

  # With OVN we need the compute nodes to be "network" nodes as well.
  kubectl label node $(kubectl get nodes | awk '/compute/ {print $1}') openstack-network-node=enabled

  # Label all workers - Recommended and used when deploying Kubernetes specific services 
  kubectl label node $(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' -o 'jsonpath={.items[*].metadata.name}') node-role.kubernetes.io/worker=worker

  # Might as well annotate for ovn while we're in the area
  ALL_NODES=$(kubectl get nodes -l 'openstack-network-node=enabled' -o 'jsonpath={.items[*].metadata.name}')
  kubectl annotate nodes ${ALL_NODES} ovn.openstack.org/bridges="${BREX_BRIDGE}"
  kubectl annotate nodes ${ALL_NODES} ovn.openstack.org/int_bridge='br-int'
  kubectl annotate nodes ${ALL_NODES} ovn.openstack.org/ports="${BREX_BRIDGE}:eth2"
  kubectl annotate nodes ${ALL_NODES} ovn.openstack.org/mappings="physnet1:${BREX_BRIDGE}"
  kubectl annotate nodes ${ALL_NODES} ovn.openstack.org/availability_zones='nova'

  # If we have network nodes use them as gateways, otherwise let the computes be gateways
  if [[ ${NUM_VMS["network"]:-0} -eq 0 ]] ; then
    kubectl annotate node $(kubectl get nodes -l 'openstack-network-node=enabled' | awk '/compute/ {print $1}') ovn.openstack.org/gateway='enabled'
  else
    kubectl annotate node $(kubectl get nodes -l 'openstack-network-node=enabled' | awk '/network/ {print $1}') ovn.openstack.org/gateway='enabled'
  fi

  kubectl get nodes -o wide
}

prepare_kube () {
  #### ceph ####

  kubectl apply -k /opt/genestack/kustomize/rook-operator/ --wait

  wait_for_a_kube_thing kube-public apiservice v1.ceph.rook.io ".status.conditions[0].status" True
  wait_for_a_kube_thing kube-public apiservice v1alpha1.objectbucket.io ".status.conditions[0].status" True
  wait_for_a_kube_thing rook-ceph crd cephclusters.ceph.rook.io ".status.conditions[] | select(.type==\"Established\").status" "True"
  wait_for_a_kube_thing rook-ceph crd cephclusters.ceph.rook.io ".status.acceptedNames.kind" "CephCluster"


  kubectl apply -k /opt/genestack/kustomize/rook-cluster/  --wait

  wait_for_a_kube_thing rook-ceph cephclusters.ceph.rook.io rook-ceph ".status.phase" Ready 30

  kubectl apply -k /opt/genestack/kustomize/rook-defaults

  kubectl -n rook-ceph exec -it $(kubectl -n rook-ceph get pod -l "app=rook-ceph-tools" -o jsonpath='{.items[*].metadata.name}') -- ceph status

  #### openstack (just the namespace for now) ####

  kubectl apply -k /opt/genestack/kustomize/openstack


  #### mariadb ####

  kubectl --namespace openstack \
          create secret generic mariadb \
          --type Opaque \
          --from-literal=root-password="$(pwgen -s 32 1)" \
          --from-literal=password="$(pwgen -s 32 1)"

                                                                            # very cloud
  kubectl kustomize --enable-helm /opt/genestack/kustomize/mariadb-operator | sed "s/cluster\.local/${CLUSTER_NAME}/g"| kubectl --namespace mariadb-system apply --server-side --force-conflicts -f -
  # persist changes
  sed -i "s/^clusterName: .*$/clusterName: ${CLUSTER_NAME}/" /opt/genestack/kustomize/mariadb-operator/charts/mariadb-operator/values.yaml

  wait_for_a_kube_thing kube-public apiservice v1alpha1.mariadb.mmontes.io
  wait_for_a_kube_thing openstack crd backups.mariadb.mmontes.io ".status.conditions[] | select(.type==\"Established\").status" "True"
  wait_for_a_kube_thing openstack crd mariadbs.mariadb.mmontes.io ".status.conditions[] | select(.type==\"Established\").status" "True"
  wait_for_a_kube_thing mariadb-system deployment mariadb-operator ".status.conditions[] | select(.type==\"Available\").status" "True"
  wait_for_a_kube_thing mariadb-system deployment mariadb-operator-webhook ".status.conditions[] | select(.type==\"Available\").status" "True"

  kubectl --namespace openstack apply -k /opt/genestack/kustomize/mariadb-cluster/base

  kubectl -n openstack get mariadb mariadb-galera


  #### rabbitmq ####

  kubectl apply -k /opt/genestack/kustomize/rabbitmq-operator

  kubectl apply -k /opt/genestack/kustomize/rabbitmq-topology-operator

  wait_for_a_kube_thing kube-public apiservice v1alpha1.rabbitmq.com
  wait_for_a_kube_thing kube-public apiservice v1beta1.rabbitmq.com
  wait_for_a_kube_thing rabbitmq-system deployment rabbitmq-cluster-operator ".status.conditions[] | select(.type==\"Available\").status" "True"
  wait_for_a_kube_thing rabbitmq-system deployment messaging-topology-operator ".status.conditions[] | select(.type==\"Available\").status" "True"
  wait_for_a_kube_thing openstack crd rabbitmqclusters.rabbitmq.com ".status.conditions[] | select(.type==\"Established\").status" "True"
  wait_for_a_kube_thing openstack crd rabbitmqclusters.rabbitmq.com ".status.acceptedNames.kind" "RabbitmqCluster"

  kubectl apply -k /opt/genestack/kustomize/rabbitmq-cluster/base


  #### memcached ####

  kubectl kustomize --enable-helm /opt/genestack/kustomize/memcached/base | kubectl apply --namespace openstack -f -


  #### ingress controllers ####

  kubectl kustomize --enable-helm /opt/genestack/kustomize/ingress/external | kubectl apply --namespace ingress-nginx -f -

  kubectl kustomize --enable-helm /opt/genestack/kustomize/ingress/internal | kubectl apply --namespace openstack -f -


  #### metallb ####

  kubectl apply -f /opt/genestack/manifests/metallb/metallb-openstack-service-lb.yml

  kubectl --namespace openstack patch service ingress -p '{"metadata":{"annotations":{"metallb.universe.tf/allow-shared-ip": "openstack-external-svc", "metallb.universe.tf/address-pool": "openstack-external"}}}'
  kubectl --namespace openstack patch service ingress -p '{"spec": {"type": "LoadBalancer"}}'

  kubectl --namespace openstack get services ingress


  #### libvirt ####

  kubectl kustomize --enable-helm /opt/genestack/kustomize/libvirt | kubectl apply --namespace openstack -f -


  #### ovn ####

  kubectl --namespace openstack apply -k /opt/genestack/kustomize/ovn


  #### wait for everything to be ready before we return ####

  wait_for_a_kube_thing openstack statefulset mariadb-galera ".status.availableReplicas" 3 30
  wait_for_a_kube_thing openstack rabbitmqclusters.rabbitmq.com rabbitmq ".status.conditions[] | select(.type==\"AllReplicasReady\").status" "True" 3
}


install_keystone () {
  kubectl --namespace openstack \
          create secret generic keystone-rabbitmq-password \
          --type Opaque \
          --from-literal=username="keystone" \
          --from-literal=password="$(pwgen -s 64 1)"
  kubectl --namespace openstack \
          create secret generic keystone-db-password \
          --type Opaque \
          --from-literal=password="$(pwgen -s 32 1)"
  kubectl --namespace openstack \
          create secret generic keystone-admin \
          --type Opaque \
          --from-literal=password="$(pwgen -s 32 1)"
  kubectl --namespace openstack \
          create secret generic keystone-credential-keys \
          --type Opaque \
          --from-literal=password="$(pwgen -s 32 1)"

  helm upgrade --install keystone ./keystone \
               --namespace=openstack \
               --wait \
               --timeout 120m \
               -f /opt/genestack/helm-configs/keystone/keystone-helm-overrides.yaml \
               --set endpoints.identity.auth.admin.password="$(kubectl --namespace openstack get secret keystone-admin -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.oslo_db.auth.admin.password="$(kubectl --namespace openstack get secret mariadb -o jsonpath='{.data.root-password}' | base64 -d)" \
               --set endpoints.oslo_db.auth.keystone.password="$(kubectl --namespace openstack get secret keystone-db-password -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.oslo_messaging.auth.admin.password="$(kubectl --namespace openstack get secret rabbitmq-default-user -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.oslo_messaging.auth.keystone.password="$(kubectl --namespace openstack get secret keystone-rabbitmq-password -o jsonpath='{.data.password}' | base64 -d)" \
               --post-renderer /opt/genestack/kustomize/kustomize.sh \
               --post-renderer-args keystone/base

  kubectl --namespace openstack apply -f /opt/genestack/manifests/utils/utils-openstack-client-admin.yaml

  wait_for_a_kube_thing openstack pod openstack-admin-client ".status.phase" "Running"

  kubectl --namespace openstack exec -ti openstack-admin-client -- openstack user list
}

install_glance () {
  kubectl --namespace openstack \
          create secret generic glance-rabbitmq-password \
          --type Opaque \
          --from-literal=username="glance" \
          --from-literal=password="$(pwgen -s 64 1)"
  kubectl --namespace openstack \
          create secret generic glance-db-password \
          --type Opaque \
          --from-literal=password="$(pwgen -s 32 1)"
  kubectl --namespace openstack \
          create secret generic glance-admin \
          --type Opaque \
          --from-literal=password="$(pwgen -s 32 1)"

  helm upgrade --install glance ./glance \
               --namespace=openstack \
               --wait \
               --timeout 120m \
               -f /opt/genestack/helm-configs/glance/glance-helm-overrides.yaml \
               --set endpoints.identity.auth.admin.password="$(kubectl --namespace openstack get secret keystone-admin -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.identity.auth.glance.password="$(kubectl --namespace openstack get secret glance-admin -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.oslo_db.auth.admin.password="$(kubectl --namespace openstack get secret mariadb -o jsonpath='{.data.root-password}' | base64 -d)" \
               --set endpoints.oslo_db.auth.glance.password="$(kubectl --namespace openstack get secret glance-db-password -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.oslo_messaging.auth.admin.password="$(kubectl --namespace openstack get secret rabbitmq-default-user -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.oslo_messaging.auth.glance.password="$(kubectl --namespace openstack get secret glance-rabbitmq-password -o jsonpath='{.data.password}' | base64 -d)" \
               --post-renderer /opt/genestack/kustomize/kustomize.sh \
               --post-renderer-args glance/base

  kubectl --namespace openstack exec -ti openstack-admin-client -- openstack image list
}

install_cinder () {
  kubectl --namespace openstack \
          create secret generic cinder-rabbitmq-password \
          --type Opaque \
          --from-literal=username="cinder" \
          --from-literal=password="$(pwgen -s 64 1)"
  kubectl --namespace openstack \
          create secret generic cinder-db-password \
          --type Opaque \
          --from-literal=password="$(pwgen -s 32 1)"
  kubectl --namespace openstack \
          create secret generic cinder-admin \
          --type Opaque \
          --from-literal=password="$(pwgen -s 32 1)"

  helm upgrade --install cinder ./cinder \
               --namespace=openstack \
               --wait \
               --timeout 120m \
               -f /opt/genestack/helm-configs/cinder/cinder-helm-overrides.yaml \
               --set endpoints.identity.auth.admin.password="$(kubectl --namespace openstack get secret keystone-admin -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.identity.auth.cinder.password="$(kubectl --namespace openstack get secret cinder-admin -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.oslo_db.auth.admin.password="$(kubectl --namespace openstack get secret mariadb -o jsonpath='{.data.root-password}' | base64 -d)" \
               --set endpoints.oslo_db.auth.cinder.password="$(kubectl --namespace openstack get secret cinder-db-password -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.oslo_messaging.auth.admin.password="$(kubectl --namespace openstack get secret rabbitmq-default-user -o jsonpath='{.data.password}' | base64 -d)" \
               --set endpoints.oslo_messaging.auth.cinder.password="$(kubectl --namespace openstack get secret cinder-rabbitmq-password -o jsonpath='{.data.password}' | base64 -d)" \
               --post-renderer /opt/genestack/kustomize/kustomize.sh \
               --post-renderer-args cinder/base

  # cinder needs some non kube stuff to happen
  source ~/.venvs/kubespray/bin/activate
  # fix in place For Now(TM)
  sed -i '/delegate_to:/d' /opt/genestack/ansible/playbooks/deploy-cinder-volumes-reference.yaml
  sed -i 's/ansible_fqdn/inventory_hostname/' /opt/genestack/ansible/playbooks/deploy-cinder-volumes-reference.yaml
  ansible-playbook -i ${INVENTORY} /opt/genestack/ansible/playbooks/deploy-cinder-volumes-reference.yaml
  kubectl --namespace openstack exec -ti openstack-admin-client -- openstack volume type create lvmdriver-1
  kubectl --namespace openstack exec -ti openstack-admin-client -- openstack volume service list
}

install_neutron () {
	kubectl --namespace openstack \
					create secret generic neutron-rabbitmq-password \
					--type Opaque \
					--from-literal=username="neutron" \
					--from-literal=password="$(pwgen -s 32 1)"
	kubectl --namespace openstack \
					create secret generic neutron-db-password \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"
	kubectl --namespace openstack \
					create secret generic neutron-admin \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"

	# need nova and related secrets early.
	kubectl --namespace openstack \
					create secret generic placement-db-password \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"
	kubectl --namespace openstack \
					create secret generic placement-admin \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"

	kubectl --namespace openstack \
					create secret generic nova-db-password \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"
	kubectl --namespace openstack \
					create secret generic nova-admin \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"
	kubectl --namespace openstack \
					create secret generic nova-rabbitmq-password \
					--type Opaque \
					--from-literal=username="nova" \
					--from-literal=password="$(pwgen -s 32 1)"

	# Ironic (NOT IMPLEMENTED YET)
	kubectl --namespace openstack \
					create secret generic ironic-admin \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"

	# Designate (NOT IMPLEMENTED YET)
	kubectl --namespace openstack \
					create secret generic designate-admin \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"

	helm upgrade --install neutron ./neutron \
		--namespace=openstack \
			--timeout 120m \
			-f /opt/genestack/helm-configs/neutron/neutron-helm-overrides.yaml \
			--set endpoints.identity.auth.admin.password="$(kubectl --namespace openstack get secret keystone-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.neutron.password="$(kubectl --namespace openstack get secret neutron-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.nova.password="$(kubectl --namespace openstack get secret nova-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.placement.password="$(kubectl --namespace openstack get secret placement-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.designate.password="$(kubectl --namespace openstack get secret designate-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.ironic.password="$(kubectl --namespace openstack get secret ironic-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_db.auth.admin.password="$(kubectl --namespace openstack get secret mariadb -o jsonpath='{.data.root-password}' | base64 -d)" \
			--set endpoints.oslo_db.auth.neutron.password="$(kubectl --namespace openstack get secret neutron-db-password -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_messaging.auth.admin.password="$(kubectl --namespace openstack get secret rabbitmq-default-user -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_messaging.auth.neutron.password="$(kubectl --namespace openstack get secret neutron-rabbitmq-password -o jsonpath='{.data.password}' | base64 -d)" \
			--set conf.neutron.ovn.ovn_nb_connection="tcp:$(kubectl --namespace kube-system get service ovn-nb -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')" \
			--set conf.neutron.ovn.ovn_sb_connection="tcp:$(kubectl --namespace kube-system get service ovn-sb -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')" \
			--set conf.plugins.ml2_conf.ovn.ovn_nb_connection="tcp:$(kubectl --namespace kube-system get service ovn-nb -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')" \
			--set conf.plugins.ml2_conf.ovn.ovn_sb_connection="tcp:$(kubectl --namespace kube-system get service ovn-sb -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')" \
			--post-renderer /opt/genestack/kustomize/kustomize.sh \
			--post-renderer-args neutron/base

	kubectl --namespace openstack exec -ti openstack-admin-client -- openstack network agent list
}

install_nova () {
	kubectl --namespace openstack \
					create secret generic placement-db-password \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"
	kubectl --namespace openstack \
					create secret generic placement-admin \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"

	kubectl --namespace openstack \
					create secret generic nova-db-password \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"
	kubectl --namespace openstack \
					create secret generic nova-admin \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"
	kubectl --namespace openstack \
					create secret generic nova-rabbitmq-password \
					--type Opaque \
					--from-literal=username="nova" \
					--from-literal=password="$(pwgen -s 32 1)"

	helm upgrade --install placement ./placement --namespace=openstack \
		--namespace=openstack \
			--timeout 120m \
			-f /opt/genestack/helm-configs/placement/placement-helm-overrides.yaml \
			--set endpoints.identity.auth.admin.password="$(kubectl --namespace openstack get secret keystone-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.placement.password="$(kubectl --namespace openstack get secret placement-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_db.auth.admin.password="$(kubectl --namespace openstack get secret mariadb -o jsonpath='{.data.root-password}' | base64 -d)" \
			--set endpoints.oslo_db.auth.placement.password="$(kubectl --namespace openstack get secret placement-db-password -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_db.auth.nova_api.password="$(kubectl --namespace openstack get secret nova-db-password -o jsonpath='{.data.password}' | base64 -d)" \
			--post-renderer /opt/genestack/kustomize/kustomize.sh \
			--post-renderer-args placement/base
	helm upgrade --install nova ./nova \
		--namespace=openstack \
			--timeout 120m \
			-f /opt/genestack/helm-configs/nova/nova-helm-overrides.yaml \
			--set endpoints.identity.auth.admin.password="$(kubectl --namespace openstack get secret keystone-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.nova.password="$(kubectl --namespace openstack get secret nova-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.neutron.password="$(kubectl --namespace openstack get secret neutron-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.ironic.password="$(kubectl --namespace openstack get secret ironic-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.placement.password="$(kubectl --namespace openstack get secret placement-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.identity.auth.cinder.password="$(kubectl --namespace openstack get secret cinder-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_db.auth.admin.password="$(kubectl --namespace openstack get secret mariadb -o jsonpath='{.data.root-password}' | base64 -d)" \
			--set endpoints.oslo_db.auth.nova.password="$(kubectl --namespace openstack get secret nova-db-password -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_db_api.auth.admin.password="$(kubectl --namespace openstack get secret mariadb -o jsonpath='{.data.root-password}' | base64 -d)" \
			--set endpoints.oslo_db_api.auth.nova.password="$(kubectl --namespace openstack get secret nova-db-password -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_db_cell0.auth.admin.password="$(kubectl --namespace openstack get secret mariadb -o jsonpath='{.data.root-password}' | base64 -d)" \
			--set endpoints.oslo_db_cell0.auth.nova.password="$(kubectl --namespace openstack get secret nova-db-password -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_messaging.auth.admin.password="$(kubectl --namespace openstack get secret rabbitmq-default-user -o jsonpath='{.data.password}' | base64 -d)" \
			--set endpoints.oslo_messaging.auth.nova.password="$(kubectl --namespace openstack get secret nova-rabbitmq-password -o jsonpath='{.data.password}' | base64 -d)" \
			--post-renderer /opt/genestack/kustomize/kustomize.sh \
			--post-renderer-args nova/base

	kubectl --namespace openstack exec -ti openstack-admin-client -- openstack compute service list
}

install_horizon () {
	kubectl --namespace openstack \
					create secret generic horizon-secrete-key \
					--type Opaque \
					--from-literal=username="horizon" \
					--from-literal=password="$(pwgen -s 64 1)"
	kubectl --namespace openstack \
					create secret generic horizon-db-password \
					--type Opaque \
					--from-literal=password="$(pwgen -s 32 1)"

	helm upgrade --install horizon ./horizon \
			--namespace=openstack \
			--wait \
			--timeout 120m \
			-f /opt/genestack/helm-configs/horizon/horizon-helm-overrides.yaml \
			--set endpoints.identity.auth.admin.password="$(kubectl --namespace openstack get secret keystone-admin -o jsonpath='{.data.password}' | base64 -d)" \
			--set conf.horizon.local_settings.config.horizon_secret_key="$(kubectl --namespace openstack get secret horizon-secrete-key -o jsonpath='{.data.root-password}' | base64 -d)" \
			--set endpoints.oslo_db.auth.admin.password="$(kubectl --namespace openstack get secret mariadb -o jsonpath='{.data.root-password}' | base64 -d)" \
			--set endpoints.oslo_db.auth.horizon.password="$(kubectl --namespace openstack get secret horizon-db-password -o jsonpath='{.data.password}' | base64 -d)" \
			--post-renderer /opt/genestack/kustomize/kustomize.sh \
			--post-renderer-args horizon/base
}

install_skyline () {
	kubectl --namespace openstack \
					create secret generic skyline-apiserver-secrets \
					--type Opaque \
					--from-literal=service-username="skyline" \
					--from-literal=service-password="$(pwgen -s 32 1)" \
					--from-literal=service-domain="service" \
					--from-literal=service-project="service" \
					--from-literal=service-project-domain="service" \
					--from-literal=db-endpoint="mariadb-galera-primary.openstack.svc.${CLUSTER_NAME}" \
					--from-literal=db-name="skyline" \
					--from-literal=db-username="skyline" \
					--from-literal=db-password="$(pwgen -s 32 1)" \
					--from-literal=secret-key="$(pwgen -s 32 1)" \
					--from-literal=keystone-endpoint="http://keystone-api.openstack.svc.cluster.local:5000" \
					--from-literal=default-region="RegionOne"

	kubectl --namespace openstack apply -k /opt/genestack/kustomize/skyline/base
}

install_openstack () {
  cd /opt/genestack/submodules/openstack-helm
  wrap_func install_keystone
  wrap_func install_glance
  wrap_func install_cinder
  wrap_func install_neutron
  wrap_func install_nova
  #wrap_func install_horizon
  wrap_func install_skyline
}


#### Allow source or dot invocation (bash only for now) ####

if [[ $0 == "-bash" ]] ; then
  echo "pew pew"
  return 0
fi

#### Safety Third ####

set -euf
set -o pipefail

wrap_func remove_service
wrap_func force_tmux
wrap_func setup_host
wrap_func make_vms
wrap_func wait_for_vms
wrap_func make_inventory
wrap_func get_genestack
wrap_func make_genestack
wrap_func prepare_vms
wrap_func spray_kube
wrap_func steal_kube_conf
wrap_func label_nodes
wrap_func prepare_kube
wrap_func install_openstack
