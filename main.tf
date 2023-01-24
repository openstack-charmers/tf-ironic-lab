variable "ubuntu_focal_img" {
  type = string
  default = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
}

variable "num_maas_nodes" {
  description = "Number of VMs to create and register in MAAS"
  type        = number
  default     = 4
}

variable "num_ironic_nodes" {
  description = "Number of VMs to create and use as fake baremetal nodes"
  type        = number
  default     = 3
}

variable "kvm_host_username" {
  description = "KVM host username to use when configuring virsh"
  type = string
  default = "ubuntu"
}

variable "ironic_nodes_rootfs_size" {
  description = "Fake baremetal nodes rootfs disk size (in bytes)"
  type = number
  default = 21474836480  # 20GiB
}

variable "maas_nodes_rootfs_size" {
  description = "MAAS nodes rootfs disk size (in bytes)"
  type = number
  default = 42949672960  # 40GiB
}

variable "maas_nodes_vcpu" {
  description = "MAAS nodes number of vcpus"
  type = number
  default = 2
}

variable "maas_nodes_mem" {
  description = "MAAS nodes memory"
  type = string
  default = "8192"
}

terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
    maas = {
      source  = "anyonlabs/maas"
      version = "~>1.0"
    }
    remote = {
      source = "tenstad/remote"
      version = "0.1.1"
    }
    juju = {
      version = "~> 0.3.1"
      source  = "juju/juju"
    }
  }
}
provider "libvirt" {
  uri = "qemu:///system"
}

# networks
resource "libvirt_network" "oam_network" {
  name = "oam"
  mode = "nat"
  domain = "oam.libvirt"
  addresses = ["10.0.0.0/24"]
  bridge = "virt-oam"
  dhcp { enabled = false }  # dhcp provided by maas
}
resource "libvirt_network" "ironic_network" {
  name = "ironic"
  mode = "nat"
  domain = "ironic.libvirt"
  addresses = ["10.10.0.0/24"]
  bridge = "virt-ironic"
  dhcp { enabled = false }  # dhcp provided by Neutron
}
resource "libvirt_network" "external_network" {
  name = "external"
  mode = "nat"
  domain = "external.libvirt"
  addresses = ["10.20.0.0/24"]
  bridge = "virt-external"
  dhcp { enabled = true }
}
# Defining VM Volume
resource "libvirt_volume" "ubuntu_focal" {
  name = "ubuntu-focal.qcow2"
  pool = "default"
  source = var.ubuntu_focal_img
  format = "qcow2"
}
resource "libvirt_volume" "maas_controller_rootfs" {
  name = "maas-controller.qcow2"
  pool = "default"
  format = "qcow2"
  base_volume_id = libvirt_volume.ubuntu_focal.id
  size = 21474836480  # 20GiB
}

resource "libvirt_volume" "juju_controller_rootfs" {
  name = "juju-controller.qcow2"
  pool = "default"
  size = 21474836480  # 20GiB
}

resource "libvirt_volume" "node_rootfs" {
  count = var.num_maas_nodes
  name = "node${count.index + 1}.qcow2"
  pool = "default"
  size = var.maas_nodes_rootfs_size
}

resource "libvirt_volume" "node_osd_1" {
  count = var.num_maas_nodes
  name = "node${count.index + 1}-osd_1.qcow2"
  pool = "default"
  size = 32212254720  # 30GiB
}

resource "libvirt_volume" "node_osd_2" {
  count = var.num_maas_nodes
  name = "node${count.index + 1}-osd_2.qcow2"
  pool = "default"
  size = 32212254720  # 30GiB
}

resource "libvirt_volume" "ironic_node_rootfs" {
  count = var.num_ironic_nodes
  name = "baremetal${count.index + 1}.qcow2"
  pool = "default"
  size = var.ironic_nodes_rootfs_size
}

# cloud-init config for maas-controller
data "template_file" "user_data_maas_controller" {
  template = "${file("${path.module}/cloud_init_maas_controller.yaml")}"
}
data "template_file" "meta_data_maas_controller" {
  template = "${file("${path.module}/cloud_init_maas_controller_metadata.yaml")}"
}
data "template_file" "network_config_maas_controller" {
  template = "${file("${path.module}/cloud_init_maas_controller_network_config.yaml")}"
}
resource "libvirt_cloudinit_disk" "maas_controller_cloudinit" {
  name = "maas_controller_cloudinit.iso"
  pool = "default"
  user_data = "${data.template_file.user_data_maas_controller.rendered}"
  meta_data = "${data.template_file.meta_data_maas_controller.rendered}"
  network_config = "${data.template_file.network_config_maas_controller.rendered}"
}

# Define KVM domain to create
resource "libvirt_domain" "maas_controller" {
  name   = "maas-controller"
  memory = "4096"
  vcpu   = 2
  autostart = false

  network_interface {
    network_id     = libvirt_network.oam_network.id
    hostname       = "maas-controller"
    mac            = "52:54:00:01:01:02"
    wait_for_lease = false
  }

  network_interface {
    network_id     = libvirt_network.ironic_network.id
    mac            = "52:54:00:01:01:03"
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.maas_controller_rootfs.id
  }
  cloudinit = "${libvirt_cloudinit_disk.maas_controller_cloudinit.id}"

  connection {
    type     = "ssh"
    user     = "ubuntu"
    password = "ubuntu"
    host = "10.0.0.2"
  }
  provisioner "file" {
    source = "./config-maas.sh"
    destination = "/tmp/config-maas.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash -x",
      "cloud-init status --wait",
      "until nc -v -z localhost 5240; do sleep 5;done",
      "sudo cat /var/snap/maas/current/root/.ssh/id_rsa.pub | tee /home/ubuntu/.ssh/authorized_keys",
      "ssh-keyscan -t rsa -H 10.0.0.1 | sudo tee -a /var/snap/maas/current/root/.ssh/known_hosts",
      "sudo chmod 600 /var/snap/maas/current/root/.ssh/known_hosts",
      # TODO: rewrite this to take advantage of 'maas' terraform provider.
      "maas login admin http://localhost:5240/MAAS - < /home/ubuntu/admin-api-key >/dev/null",
      "until maas admin subnet read 10.0.0.0/24 | grep fabric- -m 1 ;do sleep 2;done",
      "bash -ex /tmp/config-maas.sh",
      "until [ -f /home/ubuntu/admin-api-key ]; do sleep 5; done",
      "maas admin tags create name=juju comment='Juju controller'",
      "set +x",
      "echo block until images have been imported, otherwise pxe booting will not succeed.",
      "until maas admin boot-resources is-importing | tail -1 | grep false;do sleep 10;done",
      "echo block until there is a ipxe.cfg available",
      "until wget -O - http://10.0.0.2:5248/ipxe.cfg; do sleep 5;done",
      "echo wait for images to be fully unpacked",
      # 20.04 is used for commissioning, if a different image is used, then change the URL accordingly
      "until wget -O /dev/null http://10.0.0.2:5248/images/ubuntu/amd64/ga-20.04/focal/stable/boot-initrd; do sleep 5;done",
      "until wget -O /dev/null http://10.0.0.2:5248/images/ubuntu/amd64/ga-20.04/focal/stable/boot-kernel; do sleep 5;done",
    ]
  }

  console {
    type = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type = "spice"
    listen_type = "address"
    autoport = true
  }
}

data "remote_file" "maas_ssh_key" {
  depends_on = [
    libvirt_domain.maas_controller
  ]
  conn {
    host     = "10.0.0.2"
    user     = "ubuntu"
    password = "ubuntu"
    sudo = true
  }

  path = "/var/snap/maas/current/root/.ssh/id_rsa.pub"
}

resource "null_resource" "append_maas_ssh_key" {
  depends_on = [
    data.remote_file.maas_ssh_key
  ]
  provisioner "local-exec" {
    command = "echo '${data.remote_file.maas_ssh_key.content}' | tee -a ~/.ssh/authorized_keys"
    when = create
  }
}

resource "libvirt_domain" "juju_controller" {
  depends_on = [
    libvirt_domain.maas_controller,
    libvirt_network.oam_network,
  ]
  name   = "juju-controller"
  memory = "4096"
  vcpu   = 2
  autostart = false
  boot_device {
    dev = ["network", "hd"]
  }

  network_interface {
    network_id     = libvirt_network.oam_network.id
    hostname       = "juju-controller"
    mac            = "52:54:00:02:01:01"
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.juju_controller_rootfs.id
  }

  console {
    type = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type = "spice"
    listen_type = "address"
    autoport = true
  }

  connection {
    type     = "ssh"
    user     = "ubuntu"
    password = "ubuntu"
    host = "10.0.0.2"
  }
  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash -x",
      "MAC_ADDR=52:54:00:02:01:01",
      "NODE_NAME=juju-controller",
      "until [[ $(maas admin machines read mac_address=$MAC_ADDR | jq -r 'length') == 1 ]];do sleep 5;done",
      "SYSTEM_ID=$(maas admin machines read mac_address=$MAC_ADDR | grep -i system_id -m 1 | cut -d '\"' -f 4)",
      "maas admin tag update-nodes juju add=$SYSTEM_ID",
      "maas admin machine update $SYSTEM_ID hostname=$NODE_NAME power_type=virsh power_parameters_power_address=qemu+ssh://${var.kvm_host_username}@10.0.0.1/system power_parameters_power_id=$NODE_NAME",
      "until [ \"$(maas admin machines read mac_address=$MAC_ADDR | jq -r '.[]|.status_name')\" == \"New\" ]; do sleep 10;done",
      "maas admin machine commission $SYSTEM_ID testing_scripts=none",
      "until [ \"$(maas admin machines read mac_address=$MAC_ADDR | jq -r '.[]|.status_name')\" == \"Ready\" ]; do sleep 10;done",
    ]
    when = create
  }
}

resource "libvirt_domain" "node" {
  depends_on = [
    libvirt_domain.maas_controller,
    libvirt_network.oam_network,
    libvirt_network.ironic_network,
  ]
  count = var.num_maas_nodes
  name   = "node${count.index + 1}"
  memory = var.maas_nodes_mem
  vcpu   = var.maas_nodes_vcpu
  autostart = false
  boot_device {
    dev = ["network", "hd"]
  }

  network_interface {
    network_id     = libvirt_network.oam_network.id
    hostname       = "node${count.index + 1}"
    mac            = "52:54:00:03:0${count.index + 1}:01"
    wait_for_lease = false
  }

  network_interface {
    network_id     = libvirt_network.oam_network.id
    hostname       = "node${count.index + 1}"
    mac            = "52:54:00:03:0${count.index + 1}:02"
    wait_for_lease = false
  }

  network_interface {
    network_id     = libvirt_network.ironic_network.id
    hostname       = "node${count.index + 1}"
    mac            = "52:54:00:03:0${count.index + 1}:03"
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.node_rootfs[count.index].id
  }

  disk {
    volume_id = libvirt_volume.node_osd_1[count.index].id
  }

  disk {
    volume_id = libvirt_volume.node_osd_2[count.index].id
  }

  console {
    type = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type = "spice"
    listen_type = "address"
    autoport = true
  }
  connection {
    type     = "ssh"
    user     = "ubuntu"
    password = "ubuntu"
    host = "10.0.0.2"
  }
  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash -x",
      "MAC_ADDR=52:54:00:03:0${count.index + 1}:01",
      "NODE_NAME=\"node${count.index + 1}\"",
      "until [[ $(maas admin machines read mac_address=$MAC_ADDR | jq -r 'length') == 1 ]];do sleep 5;done",
      "SYSTEM_ID=$(maas admin machines read mac_address=$MAC_ADDR | grep -i system_id -m 1 | cut -d '\"' -f 4)",
      "maas admin machine update $SYSTEM_ID hostname=$NODE_NAME power_type=virsh power_parameters_power_address=qemu+ssh://${var.kvm_host_username}@10.0.0.1/system power_parameters_power_id=$NODE_NAME",
      "until [ \"$(maas admin machines read mac_address=$MAC_ADDR | jq -r '.[]|.status_name')\" == \"New\" ]; do sleep 10;done",
      "maas admin machine commission $SYSTEM_ID testing_scripts=none",
      "until [ \"$(maas admin machines read mac_address=$MAC_ADDR | jq -r '.[]|.status_name')\" == \"Ready\" ]; do sleep 10;done",
    ]
    when = create
  }
}

resource "libvirt_domain" "ironic_node" {
  depends_on = [
    libvirt_domain.maas_controller
  ]
  count = var.num_ironic_nodes
  name   = "baremetal${count.index + 1}"
  memory = "4096"
  vcpu   = 2
  running = false
  autostart = false
  boot_device {
    dev = ["network"]
  }

  network_interface {
    network_id     = libvirt_network.ironic_network.id
    hostname       = "baremetal${count.index + 1}"
    mac            = "52:54:00:77:01:0${count.index + 1}"
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.ironic_node_rootfs[count.index].id
  }

  console {
    type = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type = "spice"
    listen_type = "address"
    autoport = true
  }
}

data "remote_file" "maas_admin_api_key" {
  depends_on = [
    libvirt_domain.maas_controller
  ]
  conn {
    host     = "10.0.0.2"
    user     = "ubuntu"
    password = "ubuntu"
  }

  path = "/home/ubuntu/admin-api-key"
}

resource "local_file" "maas_admin_api_key" {
  content  = "${data.remote_file.maas_admin_api_key.content}"
  filename = pathexpand("~/admin-api-key")
}

resource "null_resource" "cloud_and_creds" {
  depends_on = [
    libvirt_domain.maas_controller,
    local_file.maas_admin_api_key,
  ]
  provisioner "local-exec" {
    command = "wget -O cloud-and-creds.sh https://github.com/pmatulis/maas-one/raw/master/cloud-and-creds.sh && bash -x ./cloud-and-creds.sh"
    when = create
  }
  provisioner "local-exec" {
    command = "juju remove-credential --force --client maas-one maas-one ; juju remove-cloud --client maas-one"
    when = destroy
  }
}

resource "null_resource" "juju_bootstrap" {
  depends_on = [
    null_resource.cloud_and_creds,
    libvirt_domain.juju_controller,
  ]
  provisioner "local-exec" {
    command = "until juju bootstrap --bootstrap-constraints tags=juju maas-one maas-one; do sleep 10 ; done"
    when = create
  }
  provisioner "local-exec" {
    command = "juju destroy-controller --destroy-all-models -y maas-one || juju kill-controller -y maas-one || juju unregister -y maas-one || /bin/true"
    when = destroy
  }
}

resource "null_resource" "bundle" {
  depends_on = [
    null_resource.juju_bootstrap
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
juju add-model ironic
juju add-space ironic 10.10.0.0/24
juju add-space main 10.0.0.0/24
juju deploy ./ironic-bundle.yaml
juju wait -x ironic-conductor
juju run-action ironic-conductor/leader set-temp-url-secret --wait
EOF
    when = create
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
juju remove-machine --force 0 1 2 3
juju destroy-model -y ironic || /bin/true
EOF
    when = destroy
  }
}

resource "null_resource" "setup_vbmc" {
  depends_on = [
    libvirt_domain.ironic_node,
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
mkdir -p ~/.config/systemd/user/
cp ./virtualbmc.service ~/.config/systemd/user/virtualbmc.service
systemctl --user daemon-reload
sudo apt install -y pipx python3-venv
pipx ensurepath
pipx install virtualbmc
source ~/.bashrc
systemctl --user restart virtualbmc.service
EOF
    when = create
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
systemctl --user stop virtualbmc || /bin/true
rm ~/.config/systemd/user/virtualbmc.service
systemctl --user daemon-reload
pipx uninstall virtualbmc
EOF
    when = destroy
  }
}

resource "null_resource" "configure_vbmc" {
  count = var.num_ironic_nodes
  depends_on = [
    null_resource.setup_vbmc,
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
IPMI_PORT=623${count.index}
vbmc add baremetal${count.index + 1} --port $IPMI_PORT
vbmc start baremetal${count.index + 1}
until ipmitool -I lanplus -U admin -P password -H 10.0.0.1  -p $IPMI_PORT power status; do sleep 5;done
EOF
    when = create
  }
  provisioner "local-exec" {
    command = "rm -rf ~/.vbmc/baremetal${count.index + 1}"
    when = destroy
  }
}

resource "null_resource" "create_openstack_networks" {
  depends_on = [
    null_resource.bundle
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
source novarc

openstack router create ironic-router
openstack network create Pub_Net --external --share --default    --provider-network-type flat --provider-physical-network physnet1
openstack subnet create Pub_Subnet --allocation-pool start=10.0.0.200,end=10.0.0.250 --subnet-range 10.0.0.0/24 --no-dhcp --gateway 10.0.0.1 --network Pub_Net
openstack router set --external-gateway Pub_Net ironic-router
openstack network create \
     --share \
     --provider-network-type flat \
     --provider-physical-network physnet2 \
     deployment

# Set gateway to be router IP
openstack subnet create \
     --network deployment \
     --dhcp \
     --subnet-range 10.10.0.0/24 \
     --gateway 10.10.0.1 \
     --ip-version 4 \
     --allocation-pool start=10.10.0.100,end=10.10.0.254 \
     deployment

openstack router add subnet ironic-router deployment
EOF
  }
}
resource "null_resource" "upload_images" {
  depends_on = [
    null_resource.bundle
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
source novarc

if [[ ! -f ironic-python-agent.initramfs ]]; then
    wget http://10.245.161.162/swift/v1/images/ironic-python-agent.initramfs
fi
if [[ ! -f ironic-python-agent.kernel ]]; then
    wget http://10.245.161.162/swift/v1/images/ironic-python-agent.kernel
fi
if [[ ! -f baremetal-ubuntu-focal.img ]]; then
    wget http://10.245.161.162/swift/v1/images/baremetal-ubuntu-focal.img
fi

for release in bionic focal
do
    glance image-create \
        --store swift \
        --name baremetal-$release \
        --disk-format raw \
        --container-format bare \
        --file baremetal-ubuntu-$release.img --progress
done

glance image-create \
    --store swift \
    --name deploy-vmlinuz \
    --disk-format aki \
    --container-format aki \
    --visibility public \
    --file ironic-python-agent.kernel --progress

glance image-create \
    --store swift \
    --name deploy-initrd \
    --disk-format ari \
    --container-format ari \
    --visibility public \
    --file ironic-python-agent.initramfs --progress
EOF
  }
}
resource "null_resource" "create_openstack_flavors" {
  depends_on = [
    null_resource.bundle
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
source novarc

export RAM_MB=2048
export CPU=2
export DISK_GB=6
export FLAVOR_NAME="baremetal-small"

openstack flavor create --ram $RAM_MB --vcpus $CPU --disk $DISK_GB $FLAVOR_NAME
openstack flavor set --property resources:CUSTOM_BAREMETAL_SMALL=1 $FLAVOR_NAME

openstack flavor set --property resources:VCPU=0 $FLAVOR_NAME
openstack flavor set --property resources:MEMORY_MB=0 $FLAVOR_NAME
openstack flavor set --property resources:DISK_GB=0 $FLAVOR_NAME

EOF
  }
}
resource "null_resource" "create_openstack_key" {
  depends_on = [
    null_resource.bundle
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
source novarc
openstack keypair create --public-key /home/ubuntu/.ssh/id_rsa.pub testkey
EOF
  }
}
resource "null_resource" "create_openstack_ironic_node" {
  count = var.num_ironic_nodes
  depends_on = [
    null_resource.create_openstack_networks,
    null_resource.upload_images,
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-x", "-c"]
    command = <<EOF
source novarc

export DEPLOY_VMLINUZ_UUID=$(openstack image show deploy-vmlinuz -f value -c id)
export DEPLOY_INITRD_UUID=$(openstack image show deploy-initrd -f value -c id)
export NETWORK_ID=$(openstack network show deployment -f value -c id)
export NODE_NAME01="ironic-node0${count.index + 1}"
export KVM_HOST_BRIDGE_IP=10.0.0.1
export VBMC_PORT=623${count.index}
export MAC="52:54:00:77:01:0${count.index + 1}"

openstack baremetal node create --name $NODE_NAME01 \
     --driver ipmi \
     --deploy-interface direct \
     --driver-info ipmi_address=$KVM_HOST_BRIDGE_IP \
     --driver-info ipmi_username=admin \
     --driver-info ipmi_password=password \
     --driver-info ipmi_port=$VBMC_PORT \
     --driver-info deploy_kernel=$DEPLOY_VMLINUZ_UUID \
     --driver-info deploy_ramdisk=$DEPLOY_INITRD_UUID \
     --driver-info cleaning_network=$NETWORK_ID \
     --driver-info provisioning_network=$NETWORK_ID \
     --property capabilities='boot_mode:uefi' \
     --resource-class baremetal-small \
     --property cpus=4 \
     --property memory_mb=4096 \
     --property local_gb=20

export NODE_UUID01=$(openstack baremetal node show $NODE_NAME01 --format json | jq -r '.uuid')

openstack baremetal port create $MAC \
     --node $NODE_UUID01 \
     --physical-network=physnet2
openstack baremetal node manage $NODE_UUID01
EOF
  }
}
