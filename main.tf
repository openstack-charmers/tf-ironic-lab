variable "ubuntu_focal_img" {
  type = string
  default = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
}

variable "num_maas_nodes" {
  description = "Number of VMs to create and register in MAAS"
  type        = number
  default     = 4
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
resource "libvirt_network" "external_network" {
  name = "external"
  mode = "nat"
  domain = "external.libvirt"
  addresses = ["10.20.0.0/24"]
  bridge = "virt-external"
  dhcp { enabled = true }
}
resource "libvirt_network" "ironic_network" {
  name = "ironic"
  mode = "nat"
  domain = "ironic.libvirt"
  addresses = ["10.30.0.0/24"]
  bridge = "virt-ironic"
  dhcp { enabled = false }  # dhcp provided by Neutron
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
  size = 21474836480  # 20GiB
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
    mac            = "52:54:00:02:01:01"
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

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
      "until nc -v -z localhost 5240; do sleep 5;done",
      "sudo cat /var/snap/maas/current/root/.ssh/id_rsa.pub | tee /home/ubuntu/.ssh/authorized_keys",
      "ssh-keyscan -t rsa -H 10.0.0.1 | sudo tee -a /var/snap/maas/current/root/.ssh/known_hosts",
      "sudo chmod 600 /var/snap/maas/current/root/.ssh/known_hosts",
      # TODO: rewrite this to take advantage of 'maas' terraform provider.
      "maas login admin http://localhost:5240/MAAS - < /home/ubuntu/admin-api-key >/dev/null",
      "until maas admin subnet read 10.0.0.0/24 | grep fabric- -m 1 ;do sleep 2;done",
      "wget https://github.com/pmatulis/maas-one/raw/master/config-maas.sh",
      "bash -ex ./config-maas.sh",
      "until [ -f /home/ubuntu/admin-api-key ]; do sleep 5; done",
      # block until images have been imported, otherwise pxe booting won't succeed.
      "until maas admin boot-resources is-importing | tail -1 | grep false;do sleep 10;done",
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
    command = "echo ${data.remote_file.maas_ssh_key.content} | tee -a ~/.ssh/authorized_keys"
    when = create
  }
}

resource "libvirt_domain" "juju_controller" {
  depends_on = [
    libvirt_domain.maas_controller
  ]
  name   = "juju-controller"
  memory = "4096"
  vcpu   = 2
  running = false
  autostart = false
  boot_device {
    dev = ["network"]
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
}

resource "libvirt_domain" "node" {
  count = var.num_maas_nodes
  name   = "node${count.index + 1}"
  memory = "4096"
  vcpu   = 2
  running = false
  autostart = false
  boot_device {
    dev = ["network"]
  }

  network_interface {
    network_id     = libvirt_network.oam_network.id
    hostname       = "node${count.index + 1}"
    mac            = "52:54:00:03:0${count.index + 1}:01"
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.node_rootfs[count.index].id
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

resource "null_resource" "power_juju_controller" {
  depends_on = [
    libvirt_domain.maas_controller
  ]
  provisioner "local-exec" {
    command = "virsh start juju-controller"
    when = create
  }
}

resource "null_resource" "power_on_nodes" {
  depends_on = [
    libvirt_domain.maas_controller
  ]
  count = var.num_maas_nodes
  provisioner "local-exec" {
    command = "virsh start node${count.index + 1}"
    when = create
  }
}

resource "null_resource" "config_nodes" {
  depends_on = [
    null_resource.power_on_nodes
  ]
  connection {
    type     = "ssh"
    user     = "ubuntu"
    password = "ubuntu"
    host = "10.0.0.2"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",
      "until [[ $(maas admin machines read | jq -r '.[]|.hostname' |wc -l) == 4 ]];do sleep 5;done",
      "wget https://github.com/pmatulis/maas-one/raw/master/config-nodes.sh",
      "bash -x ./config-nodes.sh",
    ]
  }
}

resource "null_resource" "cloud_and_creds" {
  depends_on = [
    libvirt_domain.maas_controller,
    local_file.maas_admin_api_key,
    null_resource.config_nodes,
  ]
  provisioner "local-exec" {
    command = "wget -O cloud-and-creds.sh https://github.com/pmatulis/maas-one/raw/master/cloud-and-creds.sh && bash -x ./cloud-and-creds.sh"
    when = create
  }
}

resource "null_resource" "juju-bootstrap" {
  depends_on = [
    null_resource.cloud_and_creds
  ]
  provisioner "local-exec" {
    command = "juju bootstrap --bootstrap-constraints tags=juju maas-one maas-one"
    when = create
  }
}


# destroy controller
resource "null_resource" "destroy_controller" {
  provisioner "local-exec" {
    command = "juju destroy-controller --destroy-all-models -y maas-one || /bin/true"
    when = destroy
  }
}

# unregister the cloud
resource "null_resource" "remove_cloud_and_creds" {
  provisioner "local-exec" {
    command = "juju remove-credential --force --client maas-one ; juju remove-cloud --client maas-one"
    when = destroy
  }
}



# provider "maas" {
#   api_version = "2.0"
#   api_key = "${data.remote_file.maas_admin_api_key.content}"
#   api_url = "http://${libvirt_domain.maas_controller.network_interface.0.addresses.0}:5240/MAAS"
# }


# resource "maas_machine" "juju_controller" {
#   power_type = "virsh"
#   power_parameters = {
#     power_address = "qemu+ssh://ubuntu@10.0.0.1/system"
#     power_id = libvirt_domain.maas_controller.name
#   }
#   pxe_mac_address = libvirt_domain.juju_controller.network_interface.0.mac
# }
