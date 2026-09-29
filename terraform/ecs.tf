resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ---------- Task definition (vertical scaling lives here) ----------
# Changing task_cpu / task_memory creates a new task definition revision, and
# the service performs a rolling deployment onto the resized tasks.
resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([merge(
    {
      name      = local.container_name
      image     = "docker.io/${var.dockerhub_repository}:${var.image_tag}"
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = [
        { name = "APP_VERSION", value = var.image_tag },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "PORT", value = tostring(var.container_port) },
        { name = "WEB_CONCURRENCY", value = tostring(local.gunicorn_workers) },
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:${var.container_port}/health', timeout=3)\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "app"
        }
      }
    },
    # Private Docker Hub repo: authenticate the pull with credentials from Secrets Manager.
    {
      for k, v in { repositoryCredentials = { credentialsParameter = var.dockerhub_credentials_secret_arn } } :
      k => v if var.dockerhub_credentials_secret_arn != ""
    }
  )])

  lifecycle {
    precondition {
      condition     = contains(local.fargate_memory_options[tostring(var.task_cpu)], var.task_memory)
      error_message = "task_memory ${var.task_memory} is not valid for task_cpu ${var.task_cpu}. Valid values: ${join(", ", local.fargate_memory_options[tostring(var.task_cpu)])}."
    }
  }
}

# ---------- Service ----------
resource "aws_ecs_service" "app" {
  name             = "${local.name}-svc"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"
  propagate_tags   = "SERVICE"

  # Rolling update: start new tasks before stopping old ones (zero downtime).
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  # Automatically roll back if new tasks fail to become healthy.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = var.container_port
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.task_execution,
  ]

  lifecycle {
    # Task count is owned by Application Auto Scaling and the Jenkins "scale"
    # action after the first apply; don't let deploys reset it.
    ignore_changes = [desired_count]
  }
}
