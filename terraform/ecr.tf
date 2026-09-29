resource "aws_ecr_repository" "app" {
  name = local.name

  # Every build gets a unique tag (<git-sha>-<build>), so tags never need to move.
  image_tag_mutability = "IMMUTABLE"

  # Lets `terraform destroy` remove the repo even when it still holds images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 15 most recent images"
      selection    = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 15
      }
      action = { type = "expire" }
    }]
  })
}
