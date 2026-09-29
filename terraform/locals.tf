data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name           = "${var.project_name}-${var.environment}"
  container_name = "app"
  azs            = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Valid Fargate CPU -> memory (MiB) combinations.
  fargate_memory_options = {
    "256"  = [512, 1024, 2048]
    "512"  = range(1024, 4097, 1024)
    "1024" = range(2048, 8193, 1024)
    "2048" = range(4096, 16385, 1024)
    "4096" = range(8192, 30721, 1024)
  }

  # Scale gunicorn workers with the vCPUs given to the task (2 * vCPU + 1, min 2).
  gunicorn_workers = max(2, floor(var.task_cpu / 1024) * 2 + 1)
}
