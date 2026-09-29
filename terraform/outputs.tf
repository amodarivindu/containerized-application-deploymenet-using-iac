output "alb_url" {
  description = "Public URL of the application."
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecr_repository_url" {
  description = "ECR repository to push images to."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.app.arn
}

output "image_tag" {
  description = "Currently deployed image tag (used by the Jenkins 'scale' action to keep the same image)."
  value       = var.image_tag
}

output "task_size" {
  description = "Current vertical scaling settings."
  value       = {
    cpu              = var.task_cpu
    memory           = var.task_memory
    gunicorn_workers = local.gunicorn_workers
  }
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}
