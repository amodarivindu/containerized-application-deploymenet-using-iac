# Terraform Guide: How It Works

A simple explanation of the infrastructure code in `terraform/`: what each file builds in AWS, and the logic that connects them.

---

## 1. The big picture

Terraform files **describe what should exist in AWS**. When you run `terraform apply`, Terraform compares that description with what really exists and creates, changes or deletes things to make them match.

```
 You / Jenkins                Terraform                        AWS
 ─────────────                ─────────                        ───
 terraform plan   ──►  reads *.tf files + state   ──►  "I will create 20 resources"
 terraform apply  ──►  makes the changes          ──►  VPC, load balancer, ECS...
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
├── variables.tf        Inputs you can change (CPU, memory, task counts, image)
├── network.tf          VPC, 2 subnets, internet access, firewalls
├── alb.tf              Load balancer (the public entry point)
├── iam.tf              Permissions for the containers
├── ecs.tf              The cluster, the container recipe, the service
├── autoscaling.tf      Add/remove containers based on CPU
└── outputs.tf          Values printed after apply (URL, names)
```

> Terraform reads **all `.tf` files in the folder together**. The split into files is only to keep things organised. You never import one file into another.

---

## 3. What gets built

```
                         Users (Internet)
                               │ http :80
                               ▼
                 ┌──────────────────────────┐
                 │   Application Load       │  alb.tf
                 │   Balancer               │  firewall: port 80 open to everyone
                 └────────────┬─────────────┘
                              │ sends traffic only to healthy tasks (/health)
             ┌────────────────┴────────────────┐
             ▼                                 ▼
   ┌───────────────────┐             ┌───────────────────┐
   │ Subnet A (AZ a)   │             │ Subnet B (AZ b)   │   network.tf
   │ 10.20.1.0/24      │             │ 10.20.2.0/24      │
   │ ┌───────────────┐ │             │ ┌───────────────┐ │
   │ │ Fargate task  │ │             │ │ Fargate task  │ │   ecs.tf
   │ │ calculator    │ │             │ │ calculator    │ │   firewall: port 8080,
   │ │ :8080         │ │             │ │ :8080         │ │   ONLY from the load balancer
   │ └───────────────┘ │             │ └───────────────┘ │
   └───────────────────┘             └───────────────────┘
             └──────── VPC 10.20.0.0/16 ──────┘
                              │
        pulls image from Docker Hub · sends logs to CloudWatch
```

**Two AZs (availability zones)** are two separate AWS data centres. If one fails, the task in the other keeps the app running. AWS load balancers also require at least two.

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
| `local.name` | One name prefix used everywhere, giving `ecs-demo-dev-alb`, `ecs-demo-dev-cluster` and so on. |

### 4.3 `variables.tf` — the inputs

Variables are the **settings panel**. You change behaviour by changing a variable, never by editing the resources.

| Variable | Default | Controls |
|---|---|---|
| `aws_region`, `availability_zones` | us-east-1, [1a, 1b] | Where it's built |
| `project_name`, `environment` | ecs-demo, dev | Names |
| `dockerhub_repository` | *(required)* | Which image, e.g. `amodarivindu/ecs-demo` |
| `image_tag` | latest | Which version of the image |
| `task_cpu`, `task_memory` | 256, 512 | **Vertical scaling**: size of each container |
| `desired_count` | 2 | Starting number of containers |
| `min_capacity`, `max_capacity` | 1, 4 | **Horizontal scaling** limits |
| `cpu_target` | 60 | Autoscaling goal (% CPU) |

**How Jenkins sets them:** any environment variable named `TF_VAR_<name>` becomes that Terraform variable.

```
Jenkins parameter  TASK_CPU = 512
        │
        ▼
Jenkinsfile        TF_VAR_task_cpu = "${params.TASK_CPU}"
        │
        ▼
Terraform          var.task_cpu = 512
```

For local runs, put the values in `terraform.tfvars` instead (copy `terraform.tfvars.example`).

### 4.4 `network.tf` — the private network

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

**The two firewalls (security groups) are the key security logic:**

```hcl
# Load balancer: anyone may connect on port 80
resource "aws_security_group" "alb" {
  ingress { from_port = 80, cidr_blocks = ["0.0.0.0/0"] }
}

# Tasks: port 8080, but ONLY from the load balancer
resource "aws_security_group" "tasks" {
  ingress { from_port = 8080, security_groups = [aws_security_group.alb.id] }
}
```

```
User ──► :80 load balancer ✅      User ──► :8080 task directly ❌ blocked
```

The tasks have public IPs (so they can download the image from Docker Hub), but nobody can reach them directly. All traffic must come through the load balancer.

`egress` (outbound) is open on both, so tasks can reach Docker Hub and CloudWatch.

### 4.5 `alb.tf` — the load balancer

```
Listener (port 80) ──► Target group ──► task IPs on port 8080
                           │
                           └── health check: GET /health must return 200
```

| Resource | Logic |
|---|---|
| `aws_lb` | The public entry point. AWS gives it a DNS name, the `alb_url` output. |
| `aws_lb_target_group` | The list of tasks to send traffic to. `target_type = "ip"` because each Fargate task has its own IP. ECS adds and removes tasks here automatically. |
| `health_check` | The load balancer calls `/health` regularly and only sends users to tasks that answer 200. |
| `deregistration_delay = 30` | During a deploy, an old task gets 30 seconds to finish its requests before it's removed. |
| `aws_lb_listener` | "Anything arriving on port 80 → forward to the target group". |

### 4.6 `iam.tf` — permissions

ECS uses **two roles** for two different jobs:

| Role | Used by | Why |
|---|---|---|
| `execution` | **ECS itself**, to *start* the container | Needs to write logs to CloudWatch (the AWS-managed policy `AmazonECSTaskExecutionRolePolicy`) |
| `task` | **Your app**, while it runs | Would hold permissions for S3, DynamoDB and so on. The calculator uses no AWS services, so it's **empty** |

An empty task role follows the **least privilege** rule: if someone hacked the app, they would get no AWS access.

`data "aws_iam_policy_document" "ecs_assume"` is the **trust policy**, shared by both roles. It says "only the ECS tasks service may use this role".

### 4.7 `ecs.tf` — the heart of it

It has three pieces: **cluster**, **task definition** and **service**.

```
Cluster  (a group, no servers to manage with Fargate)
   └── Service  "keep 2 copies of this recipe running behind the load balancer"
          └── Task definition  "the recipe: image, CPU, memory, port, logs"
                 └── Tasks (running containers)
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
    logConfiguration = { logDriver = "awslogs", ... }                 # stdout → CloudWatch
  }])
}
```

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
  desired_count   = var.desired_count                 # how many copies
  launch_type     = "FARGATE"                         # AWS runs the servers for us
  ...
}
```

The service:
- starts the tasks and **replaces any that crash**;
- registers them with the load balancer;
- performs **rolling deployments** when the revision changes.

**Rolling deployment, with zero downtime** (ECS defaults: keep 100% running, allow up to 200% during a deploy):

```
Before:   [v1] [v1]
Step 1:   [v1] [v1] [v2] [v2]    new tasks start next to the old ones
Step 2:   [v1] [v1] [v2✓][v2✓]   new tasks pass /health and get traffic
After:              [v2✓][v2✓]   old tasks drained and stopped
```

`health_check_grace_period_seconds = 60` gives a new task 60 seconds to boot before failed health checks count against it.

**Circuit breaker = automatic rollback:**

```hcl
deployment_circuit_breaker { enable = true, rollback = true }
```

If the new version keeps failing its health checks, ECS stops the deploy and goes back to the previous revision by itself. Users never see the broken version.

**`depends_on = [aws_lb_listener.http]`:** Terraform normally works out the order by itself from references. The service doesn't reference the listener, but it needs it to exist, so we state it explicitly.

**`ignore_changes = [desired_count]`: the most important line to understand.**

```hcl
lifecycle { ignore_changes = [desired_count] }
```

Terraform sets the task count **only once**, when the service is created. After that, two other things change it:
- autoscaling (for example 2 → 4 when busy)
- the Jenkins `scale` action

Without this line, the next deploy would see "code says 2, AWS has 4" and **scale back down to 2 in the middle of a traffic spike**. With it, Terraform leaves the count alone.

### 4.8 `autoscaling.tf` — horizontal scaling

```hcl
resource "aws_appautoscaling_target" "ecs" {
  resource_id  = "service/<cluster>/<service>"   # WHAT to scale
  min_capacity = var.min_capacity                # never fewer than 1
  max_capacity = var.max_capacity                # never more than 4
}

resource "aws_appautoscaling_policy" "cpu" {
  policy_type = "TargetTrackingScaling"
  target_tracking_scaling_policy_configuration {
    target_value = var.cpu_target                # keep average CPU around 60%
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}
```

**Logic: it works like a thermostat.** You set the target temperature (60% CPU), and AWS turns the heating (number of tasks) up or down:

```
Average CPU 85%  ──►  too hot   ──►  add tasks     (up to max 4)
Average CPU 60%  ──►  on target ──►  do nothing
Average CPU 15%  ──►  too cold  ──►  remove tasks  (down to min 1)
```

AWS creates the CloudWatch alarms for this automatically. You don't write any alarm code.

### 4.9 `outputs.tf` — results

| Output | Example | Used by |
|---|---|---|
| `alb_url` | `http://ecs-demo-dev-alb-123.us-east-1.elb.amazonaws.com` | You (open in a browser), the Jenkins smoke test |
| `ecs_cluster_name` | `ecs-demo-dev-cluster` | Jenkins: wait for the deploy, scale |
| `ecs_service_name` | `ecs-demo-dev-svc` | Jenkins: wait for the deploy, scale |
| `image_tag` | `abc1234-7` | Jenkins `scale` action (keeps the same image) |

See them with `terraform output`, or one value with `terraform output -raw alb_url`.

---

## 5. How the pieces connect

Terraform reads references like `aws_vpc.main.id` and builds everything **in the right order**, doing independent pieces at the same time:

```
provider.tf / variables.tf
        │
        ▼
     aws_vpc ─────────┬──────────────┬─────────────────┐
        │             │              │                 │
 internet_gateway  subnet_a/b   security groups   (IAM roles, log group:
        │             │              │             no network needed,
   route_table ───────┤              │             built in parallel)
                      ▼              ▼                 │
                  load balancer ◄────┘                 │
                      │                                │
             target_group ──► listener                 │
                      │          │                     │
                      ▼          ▼                     ▼
                   ECS service ◄──────────── task definition ◄── cluster
                      │
                      ▼
              autoscaling target ──► CPU policy
```

**About 20 AWS resources** in total. `terraform destroy` removes them in reverse order.

---

## 6. The two kinds of scaling

| | Vertical scaling | Horizontal scaling |
|---|---|---|
| **Meaning** | Make each container **bigger** | Run **more** containers |
| **Variables** | `task_cpu`, `task_memory` | `min_capacity`, `max_capacity`, `desired_count`, `cpu_target` |
| **Where in code** | Task definition (`ecs.tf`) | `autoscaling.tf` + service |
| **How to trigger** | Jenkins `scale` with `TASK_CPU=512`, `TASK_MEMORY=1024` | Automatic (CPU), or Jenkins `scale` with `DESIRED_COUNT` |
| **What happens** | New revision → rolling replacement | Tasks are added or removed |
| **Downtime** | None | None |

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
| First `deploy` | – | `~20 to add`: everything is created |
| `deploy` (new code) | `image_tag` | New task definition revision, service updated → rolling deploy |
| `scale` CPU/memory | `task_cpu`, `task_memory` | New task definition revision → rolling deploy |
| `scale` min/max | `min_capacity`, `max_capacity` | Autoscaling target updated |
| `plan-only` | – | Whatever *would* change (nothing is applied) |
| `destroy` | – | Everything removed |

**Before approving in Jenkins**, read the last line of the plan:

```
Plan: 1 to add, 1 to change, 1 to destroy.
```

That's normal for a deploy (new revision in, old revision out). If a normal deploy wants to destroy the VPC or load balancer, **stop and investigate**.

---

## 8. Terraform concepts used

| Concept | Example | Meaning |
|---|---|---|
| `resource` | `resource "aws_vpc" "main"` | Something to create in AWS |
| `variable` | `var.task_cpu` | An input |
| `locals` | `local.name` | A computed helper value |
| `data` | `data "aws_iam_policy_document"` | Build or read something without creating a resource |
| `output` | `output "alb_url"` | A value to print |
| Reference | `aws_vpc.main.id` | Use another resource's value; this also sets the build order |
| Interpolation | `"${local.name}-alb"` | Insert a value into text |
| `jsonencode()` | container definitions | Turn Terraform data into the JSON AWS expects |
| `depends_on` | service → listener | Force an order Terraform can't see |
| `lifecycle.ignore_changes` | `desired_count` | "Set once, then leave it alone" |
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
terraform plan -var="task_cpu=512" -var="task_memory=1024"   # see vertical scaling in a plan

terraform state list                                  # everything Terraform manages
terraform output                                      # URL and names
```
