# Output Server IP
output "maas_controller_ip" {
  value = "10.0.0.2"
}
output "juju_controller_name" {
  value = "${libvirt_domain.maas_controller.name}"
}
output "juju_controller_mac" {
  value = "${libvirt_domain.juju_controller.network_interface.0.mac}"
}
