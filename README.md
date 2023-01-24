# Charmed OpenStack Ironic Lab

This project deploys Charmed OpenStack on a set of virtual machines managed by
Libvirt.


The environment deployed consists of the following components:

1. 3 NAT'ed libvirt networks

  | Name     | Port          | CIDR         | DHCP?   |
  | ----     | ----          | ----         | -----   |
  | external | virt-external | 10.20.0.0/24 | libvirt |
  | oam      | virt-oam      | 10.0.0.0/24  | MAAS    |
  | ironic   | virt-ironic   | 10.10.0.0/24 | Neutron |

2. 9 virtual machines.

  * maas-controller: host MAAS (region and rack controller)
  * juju-controller: host juju controller
  * 4 x node$i : host OpenStack control plane
  * 3 x baremetal$i : fake baremetal nodes registered in Ironic via virtualbmc.

## Usage

```bash
sudo apt install libvirt-daemon
terraform init
terraform apply
```
