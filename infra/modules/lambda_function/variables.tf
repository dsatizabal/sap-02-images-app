variable "name" {
  type = string
}

variable "filename" {
  type = string
}

variable "handler" {
  type = string
}

variable "runtime" {
  type    = string
  default = "python3.13"
}

variable "timeout" {
  type    = number
  default = 10
}

variable "memory_size" {
  type    = number
  default = 256
}

variable "env" {
  type    = map(string)
  default = {}
}
