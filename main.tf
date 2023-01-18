terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}
provider "libvirt" {
  ## Configuration options
  uri = "qemu:///system"
  #alias = "server2"
  #uri   = "qemu+ssh://root@192.168.100.10/system"
}

resource "libvirt_pool" "ironic" {
  name = "ironic"
  type = "dir"
  path = "~/ironic_storage"
}

# networks
resource "libvirt_network" "oam_network" {
  name = "oam"
  mode = "nat"
  domain = "oam.libvirt"
  addresses = ["10.10.0.0/24"]
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
  bridge = "virt-oam"
  dhcp { enabled = false }  # dhcp provided by Neutron
}

# Defining VM Volume
resource "libvirt_volume" "ubuntu-focal-qcow2" {
  name = "ubuntu-focal.qcow2"
  pool = libvirt_pool.ironic.name
  source = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64-disk-kvm.img"
  format = "qcow2"
}

# cloud-init config for maas-controller
# get user data info
data "template_file" "user_data_maas_controller" {
  template = "${file("${path.module}/cloud_init_maas_controller.yaml")}"
}


# Define KVM domain to create
resource "libvirt_domain" "maas_controller" {
  name   = "maas-controller"
  memory = "4096"
  vcpu   = 2

  network_interface {
    network_name = libvirt_network.oam_network.name
  }

  disk {
    volume_id = "${libvirt_volume.ubuntu-focal-qcow2.id}"
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

# Output Server IP
output "ip" {
  value = "${libvirt_domain.maas_controller.network_interface.0.addresses.0}"
}
