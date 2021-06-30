###################################
##      Terraform providers       ##
###################################

provider "vsphere" {
  vsphere_server       = var.vcenter_server
  user                 = var.vcenter_user
  password             = var.vcenter_password
  allow_unverified_ssl = true
}

# Configure the Rancher2 provider to bootstrap and admin
# Provider config for bootstrap
provider "rancher2" {
  alias     = "bootstrap"
  api_url   = var.rancher_api_url
  bootstrap = true
}

# Create a new rancher2_bootstrap using bootstrap provider config
resource "rancher2_bootstrap" "admin" {
  provider   = rancher2.bootstrap
  password   = var.rancher_admin_pass
  telemetry  = true
  depends_on = [vsphere_virtual_machine.rancher01, vsphere_virtual_machine.rancher02, vsphere_virtual_machine.rancher03]
}

# Provider config for admin
provider "rancher2" {

  api_url   = rancher2_bootstrap.admin.url
  token_key = rancher2_bootstrap.admin.token
  insecure  = true
}

###################################
##      Terraform resources      ##
###################################



#===============================================================================
# Collect essential vSphere Data Sources
#===============================================================================

data "vsphere_datacenter" "dc" {
  name = var.vcenter_datacenter
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.vsphere_drs_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_resource_pool" "pool" {
  name          = var.vcenter_pool
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "datastore" {
  name          = var.vcenter_datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}
data "vsphere_network" "network" {
  name          = var.vcenter_network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.vcenter_template
  datacenter_id = data.vsphere_datacenter.dc.id
}
#===============================================================================
# Generate Templates to obfuscate secrets in them
#===============================================================================


data "template_file" "rke2_token" {
  template = file("templates/config.tpl")
  vars = {
    my-shared-secret = "${var.rke2_token}"
    san-1            = "${var.short_fqdn}"
    san-2            = "${var.rancher_fqdn}"
    san-3            = "10.10.70.2"
    san-4            = "10.10.70.3"
    san-5            = "10.10.70.4"
    san-6            = "10.10.70.5"
  }
}

data "template_file" "rke2_token_server" {
  template = file("templates/config_server.tpl")
  vars = {
    server           = "https://10.10.70.3:9345"
    my-shared-secret = "${var.rke2_token}"
    san-1            = "${var.short_fqdn}"
    san-2            = "${var.rancher_fqdn}"
    san-3            = "10.10.70.2"
    san-4            = "10.10.70.3"
    san-5            = "10.10.70.4"
    san-6            = "10.10.70.5"
  }
}
#===============================================================================
# Local Resources to create from Terraform data Templates 
#===============================================================================

resource "local_file" "rke2_token" {
  content  = data.template_file.rke2_token.rendered
  filename = "files/config.yaml"
}

resource "local_file" "rke2_token_server" {
  content  = data.template_file.rke2_token_server.rendered
  filename = "files/config_server.yaml"
}

#===============================================================================
# Create the HAProxy load balancer VM
#===============================================================================
resource "vsphere_virtual_machine" "haproxy" {
  name             = "g-rke-haproxy"
  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.datastore.id
  folder           = "g-rke-cluster-dev"

  num_cpus = 4
  memory   = 4096
  guest_id = data.vsphere_virtual_machine.template.guest_id

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "g-rke-dev-haproxy.vmdk"
    size             = data.vsphere_virtual_machine.template.disks.0.size
    eagerly_scrub    = data.vsphere_virtual_machine.template.disks.0.eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.template.disks.0.thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    linked_clone  = false

    customize {
      linux_options {
        host_name = "g-rke-dev-haproxy"
        domain    = "cluster.local"
      }

      network_interface {
        ipv4_address = "10.10.70.2"
        ipv4_netmask = "24"
      }

      ipv4_gateway    = "10.10.70.1"
      dns_server_list = ["1.1.1.1"]
    }
  }


  provisioner "file" {
    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }

    source      = "files/haproxy.cfg"
    destination = "/tmp/haproxy.cfg"
  }

  provisioner "file" {
    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }

    source      = "files/certificate.pem"
    destination = "/tmp/certificate.pem"
  }
  provisioner "remote-exec" {
    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }

    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y haproxy",
      "sudo mv /tmp/haproxy.cfg /etc/haproxy",
      "sudo mv /tmp/certificate.pem /etc/ssl/",
      "sudo systemctl restart haproxy"
    ]
  }
  lifecycle {
    ignore_changes = [disk]
  }
}


#===============================================================================
# Create rke2 engine 
#===============================================================================
resource "vsphere_virtual_machine" "rancher01" {
  count            = 1
  name             = "g-rke-dev-${format("%02d", count.index + 1)}"
  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.datastore.id
  folder           = "g-rke-cluster-dev"

  num_cpus = 8
  memory   = 8192
  guest_id = data.vsphere_virtual_machine.template.guest_id

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "g-rke-dev-${format("%02d", count.index + 1)}.vmdk"
    size             = data.vsphere_virtual_machine.template.disks.0.size
    eagerly_scrub    = data.vsphere_virtual_machine.template.disks.0.eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.template.disks.0.thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    linked_clone  = false

    customize {
      linux_options {
        host_name = "g-rke-dev-${format("%02d", count.index + 1)}"
        domain    = "cluster.local"
      }

      network_interface {
        ipv4_address = format("10.10.70.%d", (count.index + 1 + 2))
        ipv4_netmask = "24"
      }

      ipv4_gateway    = "10.10.70.1"
      dns_server_list = ["1.1.1.1", "8.8.8.8"]
    }
  }


  provisioner "file" {
    source      = "files/script.sh"
    destination = "/tmp/script.sh"

    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }
  }

  provisioner "file" {
    source      = "files/config.yaml"
    destination = "/tmp/config.yaml"

    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }
  }

  provisioner "remote-exec" {
    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }

    inline = [
      "chmod +x /tmp/script.sh",
      "sudo mkdir -p /etc/rancher/rke2",
      "sudo cp /tmp/config.yaml /etc/rancher/rke2",
      "echo '10.10.70.4 g-rke-dev-02.cluster.local g-rke-dev-02' | sudo tee -a /etc/hosts",
      "echo '10.10.70.5 g-rke-dev-03.cluster.local g-rke-dev-03' | sudo tee -a /etc/hosts",
      "/tmp/script.sh"
    ]
  }
  lifecycle {
    ignore_changes = ["disk"]
  }
  depends_on = [vsphere_virtual_machine.haproxy]
}

resource "vsphere_virtual_machine" "rancher02" {
  name             = "g-rke-dev-02"
  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.datastore.id
  folder           = "g-rke-cluster-dev"

  num_cpus = 8
  memory   = 8192
  guest_id = data.vsphere_virtual_machine.template.guest_id

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "g-rke-dev-02.vmdk"
    size             = data.vsphere_virtual_machine.template.disks.0.size
    eagerly_scrub    = data.vsphere_virtual_machine.template.disks.0.eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.template.disks.0.thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    linked_clone  = false

    customize {
      linux_options {
        host_name = "g-rke-dev-02"
        domain    = "cluster.local"
      }

      network_interface {
        ipv4_address = "10.10.70.4"
        ipv4_netmask = "24"
      }

      ipv4_gateway    = "10.10.70.1"
      dns_server_list = ["1.1.1.1", "8.8.8.8"]
    }
  }


  provisioner "file" {
    source      = "files/script.sh"
    destination = "/tmp/script.sh"

    connection {
      type = "ssh"
      host = self.default_ip_address
      user = var.vm_ssh_user
      password = var.vm_ssh_password
    }
  }

  provisioner "file" {
    source      = "files/config_server.yaml"
    destination = "/tmp/config.yaml"

    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }
  }

  provisioner "remote-exec" {
    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }

    inline = [
      "chmod +x /tmp/script.sh",
      "sudo mkdir -p /etc/rancher/rke2",
      "sudo cp /tmp/config.yaml /etc/rancher/rke2",
      "echo '10.10.70.3 g-rke-dev-01.cluster.local g-rke-dev-01' | sudo tee -a /etc/hosts",
      "echo '10.10.70.5 g-rke-dev-03.cluster.local g-rke-dev-03' | sudo tee -a /etc/hosts",
      "/tmp/script.sh"
    ]
  }
  lifecycle {
    ignore_changes = ["disk"]
  }
  depends_on = [vsphere_virtual_machine.haproxy, vsphere_virtual_machine.rancher01]
}

resource "vsphere_virtual_machine" "rancher03" {
  name             = "g-rke-dev-03"
  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.datastore.id
  folder           = "g-rke-cluster-dev"

  num_cpus = 8
  memory   = 8192
  guest_id = data.vsphere_virtual_machine.template.guest_id

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "g-rke-dev-03.vmdk"
    size             = data.vsphere_virtual_machine.template.disks.0.size
    eagerly_scrub    = data.vsphere_virtual_machine.template.disks.0.eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.template.disks.0.thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
    linked_clone  = false

    customize {
      linux_options {
        host_name = "g-rke-dev-03"
        domain    = "cluster.local"
      }

      network_interface {
        ipv4_address = "10.10.70.5"
        ipv4_netmask = "24"
      }

      ipv4_gateway    = "10.10.70.1"
      dns_server_list = ["1.1.1.1", "8.8.8.8"]
    }
  }


  provisioner "file" {
    source      = "files/script.sh"
    destination = "/tmp/script.sh"

    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }
  }

  provisioner "file" {
    source      = "files/config_server.yaml"
    destination = "/tmp/config.yaml"

    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }
  }

  provisioner "file" {
    source      = "files/rancher_install.sh"
    destination = "/tmp/rancher_install.sh"

    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }
  }
  provisioner "remote-exec" {
    connection {
      type     = "ssh"
      host     = self.default_ip_address
      user     = var.vm_ssh_user
      password = var.vm_ssh_password
    }

    inline = [
      "chmod +x /tmp/script.sh",
      "chmod +x /tmp/rancher_install.sh",
      "sudo mkdir -p /etc/rancher/rke2",
      "sudo cp /tmp/config.yaml /etc/rancher/rke2",
      "/tmp/script.sh",
      "sudo chown root:root /tmp/rancher_install.sh",
      "sudo chmod u+s /tmp/rancher_install.sh",
      "echo '10.10.70.3 g-rke-dev-01.cluster.local g-rke-dev-01' | sudo tee -a /etc/hosts",
      "echo '10.10.70.4 g-rke-dev-02.cluster.local g-rke-dev-02' | sudo tee -a /etc/hosts",
      "sudo /tmp/rancher_install.sh"
    ]
  }
  lifecycle {
    ignore_changes = ["disk"]
  }
  depends_on = [vsphere_virtual_machine.haproxy, vsphere_virtual_machine.rancher01, vsphere_virtual_machine.rancher02]
}
