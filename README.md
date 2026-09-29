# Deploying a Containerized Application Using IaC

A Dockerized Python **calculator web app** deployed to **AWS ECS Fargate**, with infrastructure defined in **Terraform** and delivery automated by a **Jenkins** CI/CD pipeline. The pipeline supports vertical scaling (task CPU/memory) and horizontal scaling (task count) through ECS service updates.

## Architecture

```mermaid
flowchart LR
    dev[Developer] -->|git push| gh[GitHub repo]
    gh -->|webhook / poll| jenkins

    subgraph jenkins[Jenkins pipeline]
        direction TB
        t[Unit tests<br/>docker build --target test] --> b[Build image]
        b --> p[Push to Docker Hub]
        p --> plan[terraform plan]
        plan --> ok{Approval}
        ok --> apply[terraform apply]
        apply --> v[Verify: services-stable<br/>+ smoke test]
    end

    p --> hub[(Docker Hub<br/>user/ecs-demo)]
    apply --> state[(S3 remote state<br/>+ lockfile)]

    subgraph aws[AWS VPC · 2 public subnets]
        subgraph ecs[ECS cluster]
            svc[ECS service<br/>desired_count · rolling deploy · circuit breaker] --> t1[Fargate task<br/>public IP :8080]
            svc --> t2[Fargate task<br/>public IP :8080]
        end
    end

    apply --> aws
    hub -.image pull.-> t1 & t2
    t1 & t2 -.logs.-> cw[CloudWatch Logs<br/>Container Insights]
    user[End user] -->|http://task-ip:8080| t1 & t2
```

## Repository layout

```
.
├── app/                        # Flask calculator app
│   ├── src/app.py              #   routes: / (UI), POST /api/calculate, /api/info, /health
│   ├── src/calculator.py       #   safe expression evaluator (AST whitelist, no eval)
│   ├── src/templates/index.html#   calculator UI (buttons, keyboard, history)
│   ├── tests/                  #   pytest unit tests (calculator + API)
│   ├── Dockerfile              #   multi-stage: base → test → runtime (non-root, healthcheck)
│   └── requirements*.txt
├── terraform/                  # Main infrastructure stack
│   ├── provider.tf             #   Terraform + AWS provider, S3 backend, name prefix
│   ├── variables.tf            #   all inputs incl. task_cpu, task_memory, desired_count
│   ├── network.tf              #   VPC, 2 public subnets, internet gateway, security group
│   ├── iam.tf                  #   execution role + task role
│   ├── ecs.tf                  #   cluster, task definition, service, log group
│   ├── outputs.tf
│   └── bootstrap/              #   one-time S3 state bucket
├── Jenkinsfile                 # deploy | plan-only | scale | destroy
├── jenkins/                    # Jenkins controller image (docker, terraform, aws cli) + compose
├── scripts/get-app-urls.sh     # print the public URL of each running task
├── docker-compose.yml          # run the app locally
└── docs/
    ├── SETUP.md                # step-by-step setup guide
    ├── RUN-GUIDE.md            # step-by-step run guide (Windows)
    ├── APP-CODE-GUIDE.md       # explanation of the application code and tests
    ├── TERRAFORM-GUIDE.md      # explanation of the Terraform structure and logic
    └── jenkins-iam-policy.json # IAM policy for the Jenkins deployer
```

## Accessing the app

There is no load balancer, so each task has its own public IP on port 8080. The IPs change whenever tasks are replaced (deploy, scale, crash). The Jenkins **Verify Deployment** stage prints the current URLs, or run:

```bash
scripts/get-app-urls.sh ecs-demo-dev-cluster ecs-demo-dev-svc
# http://3.91.20.14:8080
# http://54.166.7.201:8080
```

You can also find each task's **Public IP** in the ECS console under the service's **Tasks** tab.

## Quick start

```bash
# 1. Run the app locally
docker compose up --build            # → http://localhost:8080

# 2. Create the Terraform state bucket (once)
cd terraform/bootstrap && terraform init && terraform apply -var="bucket_name=<unique-name>"

# 3. Set DOCKERHUB_REPO + TF_STATE_BUCKET in the Jenkinsfile
# 4. Start Jenkins, add the "aws-deployer" and "dockerhub" credentials, create a Pipeline-from-SCM job
cd jenkins && docker compose up -d --build   # → http://localhost:8081

# 5. Build with Parameters → ACTION=deploy
```

Step-by-step for Windows: **[RUN-GUIDE.md](docs/RUN-GUIDE.md)**. Reference details: **[docs/SETUP.md](docs/SETUP.md)**. How the app code works: **[docs/APP-CODE-GUIDE.md](docs/APP-CODE-GUIDE.md)**. How the infrastructure works: **[docs/TERRAFORM-GUIDE.md](docs/TERRAFORM-GUIDE.md)**.

## Calculator API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Calculator UI: buttons, keyboard input, last 10 results |
| POST | `/api/calculate` | Body `{"expression": "(2 + 3) × 4 ^ 2"}` → `{"result": 80, ...}`; errors return `400 {"error": "Division by zero"}` |
| GET | `/api/info` | Version, environment, task hostname (used by the pipeline smoke test) |
| GET | `/health` | ECS container health check |

Supported: numbers, `+ − × ÷ %`, `^` (power), parentheses, unary minus. Expressions are parsed into an AST and only arithmetic nodes are evaluated, so arbitrary code is rejected. Length, exponent and result size are capped to keep requests cheap.

## Pipeline actions

| `ACTION` | What happens |
|----------|--------------|
| `deploy` | Test → build → push `<sha>-<build>` and `latest` to Docker Hub → plan → approve → apply → verify new version is live |
| `plan-only` | Test + `terraform plan`, no changes |
| `scale` | Keeps the current image; applies new `TASK_CPU`/`TASK_MEMORY` (new task def revision, rolling replace) and `DESIRED_COUNT` (horizontal) |
| `destroy` | `terraform plan -destroy` → mandatory approval → apply |

## Scaling model

| Type | Where | How it changes |
|------|-------|----------------|
| Vertical | `aws_ecs_task_definition.app` (`task_cpu`, `task_memory`) | New revision → ECS starts new tasks, then stops the old ones. The new tasks have new public IPs. |
| Horizontal | `aws_ecs_service.app` (`desired_count`) | ECS starts or stops tasks to match the new count. |

## Safety features

- Unique image tag per build (`<git-sha>-<build>`): every deployment can be traced back to a commit, and ECS always pulls an exact version rather than `latest`.
- Docker Hub is logged into with an access token (never a password) and logged out after each push.
- ECS deployment circuit breaker with automatic rollback.
- Manual approval before apply, always required for destroy.
- The security group allows inbound traffic on the app port only, and the container runs as a non-root user.
- Terraform state is versioned in S3, with lockfile-based locking.
