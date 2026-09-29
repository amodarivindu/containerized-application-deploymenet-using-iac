resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = 14
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights" # CPU / memory metrics per task
    value = "enabled"
  }
}

# ---------- Task definition: the "recipe" for one container ----------
# Any change here (new image_tag, task_cpu, task_memory) creates a new revision,
# and the service rolls it out with no downtime.
resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu    # vertical scaling
  memory                   = var.task_memory # vertical scaling
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name         = "app"
      image        = "${var.dockerhub_repository}:${var.image_tag}"
      essential    = true
      portMappings = [{ containerPort = var.container_port }]

      environment = [
        { name = "APP_VERSION", value = var.image_tag },
        { name = "ENVIRONMENT", value = var.environment },
      ]

      # ECS calls /health inside the container; a task that fails is replaced.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:${var.container_port}/health', timeout=3)\" || exit 1"]
        interval    = 30
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
    }
  ])
}

# ---------- Service: keeps desired_count tasks running ----------
resource "aws_ecs_service" "app" {
  name            = "${local.name}-svc"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count # horizontal scaling
  launch_type     = "FARGATE"

  # If a new version fails its health checks, roll back to the previous one.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }
}
