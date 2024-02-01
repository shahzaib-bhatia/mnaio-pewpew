if [[ $(type -t deactivate) == "function" ]] ; then  deactivate ; fi

for VM in $(virsh list --uuid --all) ; do
  virsh destroy ${VM}
  virsh undefine ${VM}
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
