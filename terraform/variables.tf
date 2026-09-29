# ---------- General ----------
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zones" {
  description = "Two AZs in aws_region (one subnet in each)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "project_name" {
  type    = string
  default = "ecs-demo"
}

variable "environment" {
  type    = string
  default = "dev"
}

# ---------- Image ----------
variable "dockerhub_repository" {
  description = "Public Docker Hub repository, e.g. johndoe/ecs-demo"
  type        = string
}

variable "image_tag" {
  description = "Image tag to deploy. Jenkins sets this to <git-sha>-<build-number>."
  type        = string
  default     = "latest"
}

variable "container_port" {
  type    = number
  default = 8080
}

# ---------- Vertical scaling: size of each task ----------
# Valid pairs: 256 -> 512-2048 | 512 -> 1024-4096 | 1024 -> 2048-8192 | 2048 -> 4096-16384
variable "task_cpu" {
  description = "CPU units per task (1024 = 1 vCPU)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memory per task in MiB"
  type        = number
  default     = 512
}

# ---------- Horizontal scaling: number of tasks ----------
variable "desired_count" {
  description = "Tasks to start with (afterwards autoscaling / Jenkins 'scale' controls it)"
  type        = number
  default     = 2
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 4
}

variable "cpu_target" {
  description = "Autoscaling keeps average CPU around this percentage"
  type        = number
  default     = 60
}
