# Terraform Guide: How It Works

A simple explanation of the infrastructure code in `terraform/`: what each file builds in AWS, and the logic that connects them.

---

## 1. The big picture

Terraform files **describe what should exist in AWS**. When you run `terraform apply`, Terraform compares that description with what really exists and creates, changes or deletes things to make them match.

```
 You / Jenkins                Terraform                        AWS
 ─────────────                ─────────                        ───
 terraform plan   ──►  reads *.tf files + state   ──►  "I will create 15 resources"
 terraform apply  ──►  makes the changes          ──►  VPC, subnets, ECS...
                       saves what it built in the
                       state file (S3)
```

| Command | Meaning |
|---|---|
| `terraform init` | Download the AWS plugin and connect to the S3 state |
| `terraform plan` | Show what would change (safe, changes nothing) |
| `terraform apply` | Make the changes |
| `terraform destroy` | Delete everything |

**State file:** Terraform's memory of what it built. It's stored in S3, so Jenkins and your laptop share the same memory.

---

## 2. The files

```
terraform/
├── bootstrap/main.tf   STEP 0 (once): S3 bucket to store the state
│
├── provider.tf         Settings: AWS region, S3 state, tags, name prefix
├── variables.tf        Inputs you can change (CPU, memory, task count, image)
├── network.tf          VPC, 2 subnets, internet access, firewall
├── iam.tf              Permissions for the containers
├── ecs.tf              The cluster, the container recipe, the service
└── outputs.tf          Values printed after apply (names, image tag)
```

> Terraform reads **all `.tf` files in the folder together**. The split into files is only to keep things organised. You never import one file into another.

---

## 3. What gets built

```
                          Users (Internet)
                  http://<task-A-ip>:8080   http://<task-B-ip>:8080
                          │                          │
┌─────────────────────── VPC 10.20.0.0/16 ──────────────────────────┐
│                         │                          │              │
│   ┌─────────────────────▼─────┐      ┌─────────────▼─────────────┐│
│   │ Subnet A (AZ a)           │      │ Subnet B (AZ b)           ││
│   │ 10.20.1.0/24              │      │ 10.20.2.0/24              ││
│   │  ┌─────────────────────┐  │      │  ┌─────────────────────┐  ││
│   │  │ Fargate task        │  │      │  │ Fargate task        │  ││
│   │  │ calculator :8080    │  │      │  │ calculator :8080    │  ││
│   │  │ public IP 3.91.x.x  │  │      │  │ public IP 54.16.x.x │  ││
│   │  └─────────────────────┘  │      │  └─────────────────────┘  ││
│   └───────────────────────────┘      └───────────────────────────┘│
│              firewall: only port 8080 in, everything out          │
│                         │                                         │
│                  Internet Gateway                                 │
└─────────────────────────┼─────────────────────────────────────────┘
                          ▼
          pulls image from Docker Hub · sends logs to CloudWatch
```

**There is no load balancer.** Each task (running container) has its **own public IP**, and users open it directly on port 8080.

| Good | Trade-off |
|---|---|
| Very simple: fewer resources, cheaper (no ~$16/month load balancer) | No single URL: each task has a different address |
| Easy to understand and debug | **IPs change** whenever a task is replaced (deploy, scale, crash) |
| | No automatic traffic sharing between tasks |

The Jenkins pipeline prints the current URLs after every deploy, and `scripts/get-app-urls.sh` lists them at any time.

**Two AZs (availability zones)** are two separate AWS data centres. ECS spreads the tasks across both, so if one data centre has a problem, the task in the other keeps running.

---

## 4. How each file works

### 4.1 `bootstrap/main.tf` — run once, first

```hcl
resource "aws_s3_bucket" "tfstate"            { bucket = var.bucket_name }
resource "aws_s3_bucket_versioning" "tfstate" { ... status = "Enabled" }
```

**Logic:** the main stack stores its state *in* S3, so the bucket must exist *before* the main stack starts. That's why it's a separate mini-project, run once by hand. Versioning keeps old copies of the state, so a mistake can be undone.

### 4.2 `provider.tf` — settings

```hcl
backend "s3" {
  key          = "ecs-app/terraform.tfstate"   # path of the state file inside the bucket
  use_lockfile = true                          # only one apply at a time
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = var.project_name, Environment = var.environment } }
}

locals {
  name = "${var.project_name}-${var.environment}"   # "ecs-demo-dev"
}
```

| Part | Logic |
|---|---|
| `backend "s3"` | The state lives in S3, not on your laptop. The bucket name is given at `init`, so it isn't hard-coded. |
| `use_lockfile` | If Jenkins and you run `apply` at the same time, the second one waits instead of corrupting the state. |
| `default_tags` | Every resource gets `Project` and `Environment` tags automatically, so you can find everything in the AWS console. |
| `local.name` | One name prefix used everywhere, giving `ecs-demo-dev-cluster`, `ecs-demo-dev-svc` and so on. |

### 4.3 `variables.tf` — the inputs

Variables are the **settings panel**. You change behaviour by changing a variable, never by editing the resources.

| Variable | Default | Controls |
|---|---|---|
| `aws_region`, `availability_zones` | us-east-1, [1a, 1b] | Where it's built |
| `project_name`, `environment` | ecs-demo, dev | Names |
| `dockerhub_repository` | *(required)* | Which image, e.g. `amodarivindu/ecs-demo` |
| `image_tag` | latest | Which version of the image |
| `container_port` | 8080 | Port the app listens on |
| `task_cpu`, `task_memory` | 256, 512 | **Vertical scaling**: size of each container |
| `desired_count` | 2 | **Horizontal scaling**: number of containers |

**How Jenkins sets them:** any environment variable named `TF_VAR_<name>` becomes that Terraform variable.

```
Jenkins parameter  DESIRED_COUNT = 3
        │
        ▼
Jenkinsfile        TF_VAR_desired_count = "${params.DESIRED_COUNT}"
        │
        ▼
Terraform          var.desired_count = 3
```

For local runs, put the values in `terraform.tfvars` instead (copy `terraform.tfvars.example`).

### 4.4 `network.tf` — the network

```
VPC 10.20.0.0/16
 ├── Subnet A 10.20.1.0/24 in AZ a ─┐
 ├── Subnet B 10.20.2.0/24 in AZ b ─┼──► Route table: 0.0.0.0/0 → Internet Gateway
 └── Internet Gateway ──────────────┘
```

| Resource | What it is |
|---|---|
| `aws_vpc` | Your own isolated network in AWS |
| `aws_subnet` ×2 | A slice of the network in each AZ. `map_public_ip_on_launch` gives tasks a public IP. |
| `aws_internet_gateway` | The door to the internet |
| `aws_route_table` + associations | The rule "internet traffic goes through that door", attached to both subnets |

**Logic: why public subnets?** Tasks need internet access for two reasons: users must reach them, and they must download the image from Docker Hub. A public subnet with a public IP gives both.

**The firewall (security group):**

```hcl
resource "aws_security_group" "tasks" {
  ingress {                               # INBOUND
    from_port   = var.container_port      # 8080 only
    to_port     = var.container_port
    cidr_blocks = ["0.0.0.0/0"]           # from anywhere
  }
  egress {                                # OUTBOUND
    protocol    = "-1"                    # everything
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

```
User ──► :8080 ✅ allowed          User ──► :22, :3306, any other port ❌ blocked
Task ──► Docker Hub, CloudWatch ✅ allowed
```

### 4.5 `iam.tf` — permissions

ECS uses **two roles** for two different jobs:

| Role | Used by | Why |
|---|---|---|
| `execution` | **ECS itself**, to *start* the container | Needs to write logs to CloudWatch (the AWS-managed policy `AmazonECSTaskExecutionRolePolicy`) |
| `task` | **Your app**, while it runs | Would hold permissions for S3, DynamoDB and so on. The calculator uses no AWS services, so it's **empty** |

An empty task role follows the **least privilege** rule: if someone hacked the app, they would get no AWS access.

`data "aws_iam_policy_document" "ecs_assume"` is the **trust policy**, shared by both roles. It says "only the ECS tasks service may use this role".

### 4.6 `ecs.tf` — the heart of it

It has three pieces: **cluster**, **task definition** and **service**.

```
Cluster  (a group, no servers to manage with Fargate)
   └── Service  "keep desired_count copies of this recipe running"
          └── Task definition  "the recipe: image, CPU, memory, port, health check, logs"
                 └── Tasks (running containers, each with a public IP)
```

#### Task definition = the recipe

```hcl
resource "aws_ecs_task_definition" "app" {
  cpu    = var.task_cpu       # 256 = 0.25 vCPU     ← vertical scaling
  memory = var.task_memory    # 512 MiB             ← vertical scaling

  container_definitions = jsonencode([{
    name         = "app"
    image        = "${var.dockerhub_repository}:${var.image_tag}"   # amodarivindu/ecs-demo:abc1234-7
    portMappings = [{ containerPort = 8080 }]
    environment  = [{ name = "APP_VERSION", value = var.image_tag }, ...]
    healthCheck  = { command = [... call /health ...], interval = 30, retries = 3 }
    logConfiguration = { logDriver = "awslogs", ... }                 # stdout → CloudWatch
  }])
}
```

| Setting | Logic |
|---|---|
| `image` | Exact version to run. A new tag means a new deploy. |
| `environment` | `APP_VERSION` is shown in the page footer, so you can see which version is live. |
| `healthCheck` | Every 30s ECS runs a small Python command inside the container that calls `/health`. After 3 failures the task is marked **unhealthy** and replaced. |
| `logConfiguration` | Everything the app prints goes to CloudWatch log group `/ecs/ecs-demo-dev`. |

**Key logic:** a task definition can't be edited. Every change creates a new **revision**:

```
ecs-demo-dev:1   image abc1234-5, 256 CPU
ecs-demo-dev:2   image def5678-6, 256 CPU    ← new code deployed
ecs-demo-dev:3   image def5678-6, 512 CPU    ← vertical scaling
```

So **deploying new code** and **resizing** work the same way: a new revision is created, and the service rolls it out.

#### Service = the manager

```hcl
resource "aws_ecs_service" "app" {
  task_definition = aws_ecs_task_definition.app.arn   # which revision to run
  desired_count   = var.desired_count                 # how many copies  ← horizontal scaling
  launch_type     = "FARGATE"                         # AWS runs the servers for us

  network_configuration {
    subnets          = [subnet A, subnet B]           # spread across 2 AZs
    security_groups  = [the firewall]
    assign_public_ip = true                           # each task gets a public IP
  }
}
```

The service:
- keeps exactly `desired_count` tasks running;
- **replaces any task that crashes** or fails its health check;
- performs a **rolling deployment** when the revision changes.

**Rolling deployment** (ECS defaults: keep 100% running, allow up to 200% during a deploy):

```
Before:   [v1 ip-A] [v1 ip-B]
Step 1:   [v1 ip-A] [v1 ip-B] [v2 ip-C] [v2 ip-D]    new tasks start next to the old ones
Step 2:   [v1 ip-A] [v1 ip-B] [v2✓ ip-C] [v2✓ ip-D]  new tasks pass their health check
After:                        [v2✓ ip-C] [v2✓ ip-D]  old tasks are stopped
```

The app keeps running the whole time, but notice the **IPs change** (A, B → C, D). Without a load balancer, users must switch to the new URLs.

**Circuit breaker = automatic rollback:**

```hcl
deployment_circuit_breaker { enable = true, rollback = true }
```

If the new tasks keep crashing or failing their health check, ECS stops the deploy and **goes back to the previous revision** by itself. The old working version keeps running.

### 4.7 `outputs.tf` — results

| Output | Example | Used by |
|---|---|---|
| `ecs_cluster_name` | `ecs-demo-dev-cluster` | Jenkins: wait for the deploy, find task IPs |
| `ecs_service_name` | `ecs-demo-dev-svc` | Jenkins: wait for the deploy, find task IPs |
| `image_tag` | `abc1234-7` | Jenkins `scale` action (keeps the same image) |
| `get_app_urls` | `scripts/get-app-urls.sh ecs-demo-dev-cluster ecs-demo-dev-svc` | You: copy and run it to list the URLs |

See them with `terraform output`.

**Why no URL output?** Terraform only knows the service, not the IPs of the tasks inside it. ECS creates tasks (and their IPs) *after* Terraform finishes, and replaces them at any time. So the IPs are looked up live instead:

```
scripts/get-app-urls.sh
  1. aws ecs list-tasks                      → running task IDs
  2. aws ecs describe-tasks                  → network interface of each task
  3. aws ec2 describe-network-interfaces     → public IP of each interface
  → prints http://<ip>:8080 for each task
```

---

## 5. How the pieces connect

Terraform reads references like `aws_vpc.main.id` and builds everything **in the right order**, doing independent pieces at the same time:

```
provider.tf / variables.tf
        │
        ▼
     aws_vpc ────────────┬─────────────────┐
        │                │                 │
 internet_gateway    subnet_a/b     security group        IAM roles     log group   cluster
        │                │                 │                  │             │          │
   route_table ──► associations            │                  └─────► task definition  │
                         │                 │                                │          │
                         └────────────► ECS service ◄──────────────────────┴──────────┘
```

**15 AWS resources** in total:

| File | Resources |
|---|---|
| `network.tf` | VPC, internet gateway, 2 subnets, route table, 2 route associations, security group (8) |
| `iam.tf` | 2 roles, 1 policy attachment (3) |
| `ecs.tf` | log group, cluster, task definition, service (4) |

`terraform destroy` removes them in reverse order.

---

## 6. The two kinds of scaling

Both are done by **updating the ECS service definition** through Terraform:

| | Vertical scaling | Horizontal scaling |
|---|---|---|
| **Meaning** | Make each container **bigger** | Run **more** containers |
| **Variables** | `task_cpu`, `task_memory` | `desired_count` |
| **Where in code** | Task definition (`ecs.tf`) | Service (`ecs.tf`) |
| **Jenkins** | `ACTION=scale`, `TASK_CPU=512`, `TASK_MEMORY=1024` | `ACTION=scale`, `DESIRED_COUNT=3` |
| **What happens** | New revision → all tasks replaced with bigger ones | ECS starts or stops tasks to match the count |
| **IPs** | All change (new tasks) | Existing tasks keep theirs; new tasks get new ones |

```
Vertical:    [256 CPU] [256 CPU]   ──►   [512 CPU] [512 CPU]
Horizontal:  [task] [task]         ──►   [task] [task] [task]
```

Fargate only accepts certain CPU/memory pairs. Pick from this table, or AWS rejects the apply:

| CPU | Memory (MiB) |
|---|---|
| 256 (0.25 vCPU) | 512, 1024, 2048 |
| 512 (0.5 vCPU) | 1024 – 4096 |
| 1024 (1 vCPU) | 2048 – 8192 |
| 2048 (2 vCPU) | 4096 – 16384 |

---

## 7. What happens on each Jenkins run

| Jenkins action | Changed variable | Terraform plan shows |
|---|---|---|
| First `deploy` | – | `15 to add`: everything is created |
| `deploy` (new code) | `image_tag` | New task definition revision, service updated → rolling deploy |
| `scale` CPU/memory | `task_cpu`, `task_memory` | New task definition revision → rolling deploy |
| `scale` task count | `desired_count` | Service updated in place (`1 to change`) |
| `plan-only` | – | Whatever *would* change (nothing is applied) |
| `destroy` | – | `15 to destroy` |

After `deploy` and `scale`, the **Verify Deployment** stage waits until the service is stable, finds every task's IP, checks each one returns the new version on `/api/info`, and prints the URLs.

**Before approving in Jenkins**, read the last line of the plan:

```
Plan: 1 to add, 1 to change, 1 to destroy.
```

That's normal for a deploy (new revision in, old revision out). If a normal deploy wants to destroy the VPC or subnets, **stop and investigate**.

---

## 8. Terraform concepts used

| Concept | Example | Meaning |
|---|---|---|
| `resource` | `resource "aws_vpc" "main"` | Something to create in AWS |
| `variable` | `var.task_cpu` | An input |
| `locals` | `local.name` | A computed helper value |
| `data` | `data "aws_iam_policy_document"` | Build or read something without creating a resource |
| `output` | `output "ecs_cluster_name"` | A value to print |
| Reference | `aws_vpc.main.id` | Use another resource's value; this also sets the build order |
| Interpolation | `"${local.name}-cluster"` | Insert a value into text |
| `jsonencode()` | container definitions | Turn Terraform data into the JSON AWS expects |
| `backend "s3"` | provider.tf | Where the state is stored |

---

## 9. Try it yourself

```powershell
cd terraform
Copy-Item backend.hcl.example backend.hcl            # put your bucket name in it
Copy-Item terraform.tfvars.example terraform.tfvars  # put your Docker Hub repo in it
terraform init -backend-config=backend.hcl

terraform validate                                    # check the code (no AWS changes)
terraform plan                                        # see what would be built
terraform plan -var="task_cpu=512" -var="task_memory=1024"   # vertical scaling in a plan
terraform plan -var="desired_count=3"                         # horizontal scaling in a plan

terraform state list                                  # everything Terraform manages
terraform output                                      # names, image tag, URL command
```
