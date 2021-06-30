########################################
##             Variables              ##
########################################


## Rancher provider vars defined encrypted in Hashicorp Vault
variable "rancher_api_url" { 
	default = "https://rancher.glimpse.me"
}
variable "rancher_admin_pass" {
  	default = ""
}

variable "rke2_token" {
	default = ""
}

variable "short_fqdn" {
	default = ""
}

variable "rancher_fqdn" {
	default = ""
}

## Node Template 

# disk size in MB
variable "disksize" {
	default = 100000
}

# number of CPUs
variable "cpucount" {
	default = 4
}

# memory size in MB
variable "memory" {
	default = 8192
}

# VMware vCenter
variable "vcenter_server" {
	default = "10.100.2.20"
}

# vCenter User
variable "vcenter_user" { 
    default = "glmadmin"
}
variable "vcenter_password" {
  default = ""
}

# VMware Datastore
variable "vcenter_datastore" {
	default = "PHX-GLM-DS-01"
}

# VMware Datacenter
variable "vcenter_datacenter" {
	default = "PHX-GLM"
}

# VMware Resource Pool
variable "vcenter_pool" {
	default = "Compute-01/Resources/g-rke-cluster-dev"
}

# VMware Folder
variable "vcenter_folder" {
	default = "g-rke-cluster-dev"
}

variable "vm_ssh_user" {
  default = ""
}
variable "vm_ssh_password" {
  default = ""
}

variable "vsphere_drs_cluster" {
    default = "Compute-01"
}

# VMware Network
variable "vcenter_network" {
	default =  "K8SRKENETWORK"
}

variable "vcenter_template" {
    default = ""
}

