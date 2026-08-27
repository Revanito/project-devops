variable "resource_group_name" {
  type        = string
  description = "Resource group EXISTANT, fourni par l'école (renseigné dans terraform.tfvars)."
}

variable "myuid" {
  type        = string
  description = "Identifiant école (login), utilisé pour le tag obligatoire \"user\" (renseigné dans terraform.tfvars)."
}

variable "cluster_name" {
  type    = string
  default = "project-devops"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "vm_size" {
  type    = string
  default = "Standard_B2ms" # 2 vCPU / 8 Go RAM — B2s (4 Go) jugé trop juste par le formateur
}
