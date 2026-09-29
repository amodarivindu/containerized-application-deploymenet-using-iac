output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "image_tag" {
  description = "Currently deployed tag (the Jenkins 'scale' action reuses it)"
  value       = var.image_tag
}

output "get_app_urls" {
  description = "Run this to list the public URL of each running task"
  value       = "scripts/get-app-urls.sh ${aws_ecs_cluster.main.name} ${aws_ecs_service.app.name}"
}
