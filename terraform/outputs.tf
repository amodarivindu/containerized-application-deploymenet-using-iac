output "alb_url" {
  description = "Open this in a browser"
  value       = "http://${aws_lb.main.dns_name}"
}

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
