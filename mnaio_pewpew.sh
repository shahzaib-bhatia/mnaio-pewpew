#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
  echo 'be root pls'
  exit 1
fi

#### config ####
DEVSTACK_BRANCH="stable/yoga"
WANT_DISTRIB_CODENAME="focal"

#### helpers ####

reboot_and_rerun () {
  chmod +x $(realpath $0)
  cat > /etc/systemd/system/mnaio_pewpew.service <<EOF
[Service]
ExecStart=$(realpath $0)
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
  tmux attach -t mnaio_pewpew
  exit 0
else
  echo tmuxin
fi

set -euf
set -o pipefail

#### get space ####

#if [[ ! $(pvs /dev/sdc) ]] ; then
#  pvcreate /dev/sdc
#fi
#if [[ ! $(pvs /dev/sdd) ]] ; then
#  pvcreate /dev/sdd
#fi
#if [[ ! $(vgs vg_data) ]] ; then
#  vgcreate vg_data /dev/sdc /dev/sdd
#fi
#if [[ ! $(lvs vg_data/lv_data 2>&-) ]] ; then
#  lvcreate --type raid0 -l 25%FREE --nosync -n lv_data vg_data
#fi
#if [[ ! $(blkid /dev/vg_data/lv_data) ]] ; then
#  mkfs.ext4 /dev/vg_data/lv_data
#fi
#
#mkdir -p /data
#
#if [[ ! $(grep -q ^/dev/vg_data/lv_data /etc/fstab) ]] ; then
#  echo '/dev/vg_data/lv_data /data auto defaults,,noatime,barrier=0 0 2' >> /etc/fstab
#fi
#
#mount -a

#### update stuff ####

apt update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" dist-upgrade -q -y --allow-downgrades --allow-remove-essential --allow-change-held-packages

if [[ -f /var/run/reboot-required ]] ; then
  cat /var/run/reboot-required
  reboot_and_rerun
fi

source /etc/lsb-release

if [[ "${DISTRIB_CODENAME}" != "${WANT_DISTRIB_CODENAME}" ]] ; then
  do-release-upgrade -m server -f DistUpgradeViewNonInteractive
  reboot_and_rerun
fi

apt -y install pwgen

mkdir -p /opt/stack
if [[ -d /opt/stack/devstack ]] ; then
  rm -rvf /opt/stack/devstack
fi
git clone https://opendev.org/openstack/devstack /opt/stack/devstack
bash /opt/stack/devstack/tools/create-stack-user.sh
cd /opt/stack/devstack
git checkout "${DEVSTACK_BRANCH}"

cat > "/opt/stack/devstack/local.conf" <<EOF
[[local|localrc]]
ADMIN_PASSWORD=$(pwgen -s 31 1)
DATABASE_PASSWORD=$(pwgen -s 31 1)
RABBIT_PASSWORD=$(pwgen -s 31 1)
SERVICE_PASSWORD=$(pwgen -s 31 1)
EOF

chown -R stack:stack /opt/stack
sudo -u stack /opt/stack/devstack/stack.sh
