# ---------- General ----------
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix for all resources (keep it under ~16 chars; ALB names max 32)."
  type        = string
  default     = "ecs-demo"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
  default     = "dev"
}

# ---------- Networking ----------
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones (and public subnets) to use."
  type        = number
  default     = 2
}

# ---------- Container ----------
variable "container_port" {
  description = "Port the application listens on inside the container."
  type        = number
  default     = 8080
}

variable "image_tag" {
  description = "Image tag in ECR to deploy. Jenkins sets this to <git-sha>-<build-number>."
  type        = string
  default     = "latest"
}

# ---------- Vertical scaling (task size) ----------
variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.task_cpu)
    error_message = "task_cpu must be one of 256, 512, 1024, 2048, 4096."
  }
}

variable "task_memory" {
  description = "Fargate task memory in MiB. Must be a valid combination with task_cpu."
  type        = number
  default     = 512
}

# ---------- Horizontal scaling (task count) ----------
variable "desired_count" {
  description = "Initial number of running tasks. After creation, count is managed by autoscaling / Jenkins 'scale' action."
  type        = number
  default     = 2
}

variable "enable_autoscaling" {
  description = "Enable target-tracking autoscaling on CPU and memory."
  type        = bool
  default     = true
}

variable "min_capacity" {
  description = "Minimum number of tasks when autoscaling."
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of tasks when autoscaling."
  type        = number
  default     = 4

  validation {
    condition     = var.max_capacity >= var.min_capacity
    error_message = "max_capacity must be greater than or equal to min_capacity."
  }
}

variable "cpu_target_utilization" {
  description = "Target average CPU utilization (%) for autoscaling."
  type        = number
  default     = 60
}

variable "memory_target_utilization" {
  description = "Target average memory utilization (%) for autoscaling."
  type        = number
  default     = 75
}

# ---------- Observability ----------
variable "log_retention_days" {
  description = "CloudWatch log retention for container logs."
  type        = number
  default     = 14
}
