VM_SAVE_DIR="/var/lib/pewpew"
SAVE_LVS="lv_utility1_1 lv_utility1_2"

if [[ $(type -t deactivate) == "function" ]] ; then  deactivate ; fi

for VM in $(virsh list --uuid) ; do
  virsh shutdown --mode acpi ${VM}
done

until [[ "$(virsh list | grep -c running)" -eq 0 ]] ; do
  echo Being nice...
  virsh list --all
  sleep 1
done

for VM in $(virsh list --uuid --all) ; do
  virsh undefine ${VM}
done

for LV in ${SAVE_LVS} ; do
  echo "Saving ${LV} ..."
  pv -B 16M "/dev/vg_libvirt/${LV}" | pigz > "${VM_SAVE_DIR}/${LV}.gz"
done
lvremove -y vg_libvirt

rm -v /usr/local/bin/kubectl
rm -v /root/.kube/config
rm -rvf /var/lib/libvirt/qemu/cloud-init/ /var/lib/libvirt/qemu/console/

for BRIDGE in br-mgmt br-kube br-ex ; do
  ip link set ${BRIDGE} down
  brctl delbr ${BRIDGE}
done

rm -rvf /opt/genestack
rm -rvf ~/.venvs/kubespray 

rm -v /root/.ssh/known_hosts
