#!/bin/bash

#### do it in a tmux ####

if [[ ! -n ${TMUX} ]] ; then
  echo not tmuxin
  tmux new-session -s mnaio_pewpew -d
  tmux send-keys -t mnaio_pewpew C-c
  tmux send-keys -t mnaio_pewpew "bash $(realpath $0)" C-m
  tmux attach -t mnaio_pewpew
  exit 0
else
  echo tmuxin
fi

set -euf
set -o pipefail

#### get space ####

if [[ ! $(pvs /dev/sdc) ]] ; then
  pvcreate /dev/sdc
fi
if [[ ! $(pvs /dev/sdd) ]] ; then
  pvcreate /dev/sdd
fi
if [[ ! $(vgs vg_data) ]] ; then
  vgcreate vg_data /dev/sdc /dev/sdd
fi
if [[ ! $(lvs vg_data/lv_data 2>&-) ]] ; then
  lvcreate --type raid0 -l 25%FREE --nosync -n lv_data vg_data
fi
if [[ ! $(blkid /dev/vg_data/lv_data) ]] ; then
  mkfs.ext4 /dev/vg_data/lv_data
fi

mkdir -p /data

if [[ ! $(grep -q ^/dev/vg_data/lv_data /etc/fstab) ]] ; then
  echo '/dev/vg_data/lv_data /data auto defaults,,noatime,barrier=0 0 2' >> /etc/fstab
fi

mount -a

#### update stuff ####

apt update
apt -y upgrade

if [[ -f /var/run/reboot-required ]] ; then
  cat /var/run/reboot-required
  reboot
fi

#### canonical pls ####

apt -y install nginx python3-pip
mkdir -p /var/www/pxe/ubuntu
if [[ ! -f /var/www/pxe/ubuntu/ubuntu-22.04.3-live-server-amd64.iso ]] ; then
  cd /var/www/pxe/ubuntu
  wget http://releases.ubuntu.com/jammy/ubuntu-22.04.3-live-server-amd64.iso
fi
TMPDIR=$(mktemp -d)
mount /var/www/pxe/ubuntu/ubuntu-22.04.3-live-server-amd64.iso ${TMPDIR}
cp ${TMPDIR}/casper/{vmlinuz,initrd} /var/www/pxe/ubuntu/
mv /var/www/pxe/ubuntu/vmlinuz /var/www/pxe/ubuntu/linux
gzip -f /var/www/pxe/ubuntu/initrd
umount ${TMPDIR}
rmdir ${TMPDIR}

#### start work ####

if [[ -d /opt/openstack-ansible-ops ]] ; then
  rm -rvf /opt/openstack-ansible-ops
fi

git clone https://github.com/shahzaib-bhatia/openstack-ansible-ops.git /opt/openstack-ansible-ops

#### set vars ####
export MNAIO_ANSIBLE_PARAMETERS=""
export MNAIO_ANSIBLE_PARAMETERS="${MNAIO_ANSIBLE_PARAMETERS} -e osa_enable_networking_ovs_dvr=true"
export MNAIO_ANSIBLE_PARAMETERS="${MNAIO_ANSIBLE_PARAMETERS} -e osa_no_containers=true"

export ENABLE_CEPH_STORAGE="true"
export DEFAULT_IMAGE="ubuntu-22.04-amd64"
export OSA_BRANCH="stable/yoga"
export COMPUTE_VM_SERVER_RAM="16384"

#### patch ####
# TODO: do the good git thing
sed -i 's/openstack.cloud.os_nova_flavor/openstack.cloud.compute_flavor/' /opt/openstack-ansible-ops/multi-node-aio/playbooks/openstack-service-setup.yml
sed -i 's/openstack.cloud.os_/openstack.cloud./' /opt/openstack-ansible-ops/multi-node-aio/playbooks/openstack-service-setup.yml

cd /opt/openstack-ansible-ops/multi-node-aio

./build.sh
