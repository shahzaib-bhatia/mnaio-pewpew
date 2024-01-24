for VM in $(virsh list --uuid) ; do
  virsh destroy ${VM}
  virsh undefine ${VM}
done
lvremove -y vg_libvirt

rm -v /usr/local/bin/kubectl
rm -v /root/.kube/config

virsh net-destroy default
> /var/lib/libvirt/dnsmasq/virbr0.status
virsh net-start default

for BRIDGE in br-mgmt br-kube br-ex ; do
  ip link set ${BRIDGE} down
  brctl delbr ${BRIDGE}
done

rm -rvf /opt/genestack
rm -rvf ~/.venvs/kubespray 

rm -v /root/.ssh/known_hosts
