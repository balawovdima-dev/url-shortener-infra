variable "name" {
  description = "Name prefix for all resources"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "azs" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "One CIDR per AZ, same order as azs"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "One CIDR per AZ, same order as azs"
  type        = list(string)
}
variable "enable_nat_gateway" {
  description = "Create a NAT Gateway so private subnets get outbound internet (costs money)"
  type        = bool
  default     = false
}
