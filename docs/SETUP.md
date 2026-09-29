# Setup Guide

End-to-end steps to go from an empty AWS account to a running app on ECS Fargate, deployed by Jenkins.

## 1. Prerequisites

| Tool | Version | Used for |
|------|---------|----------|
| AWS account | – | Target environment |
| AWS CLI | v2 | Bootstrap + local checks |
| Terraform | >= 1.10 | Infrastructure (S3-native state locking needs 1.10+) |
| Docker | 24+ with buildx | Building images, running Jenkins locally |
| Git + GitHub repo | – | Source control, Jenkins pulls from here |
| Docker Hub account | – | Image registry (Jenkins pushes, ECS pulls) |

## 2. Push the code to GitHub

```bash
git init
git add .
git commit -m "Initial commit: ECS Fargate app with Terraform and Jenkins"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

GitHub only hosts the code. All CI/CD (tests, builds, Terraform, deployment) runs in Jenkins.

## 3. Prepare Docker Hub

1. Sign in at https://hub.docker.com.
2. *Account settings → Personal access tokens → Generate new token*, access **Read & Write**. Copy the token.
3. Set `DOCKERHUB_REPO` in the `Jenkinsfile` to `<your-dockerhub-username>/ecs-demo` (lowercase).
   The repository is created automatically on the first push, as **public**.

### Optional: private repository

ECS can only pull a private image with credentials stored in AWS Secrets Manager:

```bash
aws secretsmanager create-secret --name dockerhub-pull \
  --secret-string '{"username":"<dockerhub-user>","password":"<access-token>"}'
```

Copy the returned `ARN` and uncomment `TF_VAR_dockerhub_credentials_secret_arn` in the `Jenkinsfile`.
Terraform then adds `repositoryCredentials` to the container definition and lets the task execution role read that secret.
This also lifts Docker Hub's anonymous pull rate limit, so it's worth doing even for a public repo in busy accounts.

## 4. Create an IAM user for Jenkins

1. IAM → Policies → Create policy → JSON → paste [`jenkins-iam-policy.json`](jenkins-iam-policy.json).
   Replace `CHANGE-ME-ecs-demo-tfstate` with your state bucket name.
2. IAM → Users → Create user `jenkins-deployer`, attach the policy.
3. Create an access key (use case: "Application running outside AWS").

> If Jenkins runs on EC2, prefer an instance profile with the same policy instead of access keys.

## 5. Bootstrap the Terraform state bucket (one time)

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=<globally-unique-bucket-name>"
```

Then put that bucket name in:
- `Jenkinsfile` → `TF_STATE_BUCKET`
- `terraform/backend.hcl` (copy from `backend.hcl.example`) for local runs

## 6. Run Jenkins

```bash
cd jenkins
docker compose up -d --build
docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

Open http://localhost:8081, paste the password, choose **Install suggested plugins** (the required ones are already baked into the image from `plugins.txt`) and create an admin user.

Verify the tools inside the container:

```bash
docker compose exec jenkins sh -c "docker version && terraform version && aws --version"
```

### Add credentials

*Manage Jenkins → Credentials → System → Global → Add Credentials*

| Kind | ID | Value |
|------|----|-------|
| AWS Credentials | `aws-deployer` | Access key + secret from step 4 |
| Username with password | `dockerhub` | Docker Hub username + access token from step 3 |
| Username with password (optional) | `github` | GitHub username + personal access token (private repos only) |

### Create the pipeline job

1. *New Item* → name `ecs-demo` → **Pipeline**.
2. *Pipeline* → Definition: **Pipeline script from SCM** → Git → your repo URL (+ `github` credential if private) → branch `*/main` → Script Path `Jenkinsfile`.
3. Optional: *Build Triggers* → **GitHub hook trigger for GITScm polling**, and add a webhook in GitHub (`http://<jenkins-host>/github-webhook/`). Localhost Jenkins needs a tunnel (e.g. ngrok) for webhooks; otherwise use *Poll SCM* `H/5 * * * *`.
4. Click **Build Now** once — the first run registers the parameters (it may run with defaults). After that use **Build with Parameters**.

## 7. First deployment

Build with Parameters → `ACTION=deploy` (defaults: 0.25 vCPU / 512 MiB, 2 tasks, autoscale 1–4).

Pipeline stages:

1. **Unit Tests** – `docker build --target test` runs pytest inside the image build.
2. **Terraform Init & Validate** – S3 backend, `fmt -check`, `validate`.
3. **Build Image** – runtime image tagged `<git-sha>-<build-number>`.
4. **Push to Docker Hub** – logs in with the `dockerhub` credential, pushes `<git-sha>-<build>` and `latest`.
5. **Terraform Plan** – saved as `tfplan`, readable copy archived as `tfplan.txt`.
6. **Approval** – manual gate (skip with `AUTO_APPROVE`, never skipped for destroy).
7. **Terraform Apply** – creates/updates VPC, ALB, ECS cluster, task definition, service, IAM, autoscaling.
8. **Verify Deployment** – waits for the service to be stable, then checks that `/api/info` on the ALB returns the new version.

The app URL is printed in the console log and available with:

```bash
cd terraform && terraform output alb_url
```

The first apply takes ~5 minutes (mostly ALB provisioning).

## 8. Scaling

### Vertical (task size)

Run `ACTION=scale` (or `deploy`) with new `TASK_CPU` / `TASK_MEMORY`, e.g. `1024` / `2048`.
Terraform registers a new task definition revision and ECS does a rolling replacement (min healthy 100%, max 200%) — no downtime. Gunicorn workers scale with the vCPU count (`WEB_CONCURRENCY = 2 × vCPU + 1`).

Valid Fargate combinations:

| CPU | Memory (MiB) |
|-----|--------------|
| 256 | 512, 1024, 2048 |
| 512 | 1024 – 4096 (1 GiB steps) |
| 1024 | 2048 – 8192 |
| 2048 | 4096 – 16384 |
| 4096 | 8192 – 30720 |

Invalid combinations are rejected at plan time by a Terraform precondition.

### Horizontal (task count)

- **Automatic**: target tracking keeps average CPU near 60% and memory near 75%, within `MIN_TASKS`–`MAX_TASKS`.
- **Manual**: `ACTION=scale` with `DESIRED_COUNT` calls `scripts/scale-service.sh` (`aws ecs update-service --desired-count`). Keep it within the min/max range or autoscaling will pull it back.

## 9. Running locally

```bash
docker compose up --build          # http://localhost:8080

# or Terraform from your machine
cd terraform
cp backend.hcl.example backend.hcl        # edit bucket name
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform plan
```

## 10. Teardown

Run the pipeline with `ACTION=destroy` and approve. This removes everything in AWS except the state bucket.
Images stay on Docker Hub; delete the repository there if you no longer need it.
To remove the state bucket too, empty it, set `prevent_destroy = false` in `terraform/bootstrap/main.tf`, then run `terraform destroy` there.

## 11. Cost notes

Approximate us-east-1 cost with the defaults, running 24/7:

- ALB: ~$16/month + LCU
- Fargate: 2 × (0.25 vCPU, 0.5 GB) ≈ $18/month
- CloudWatch Logs / Container Insights: small, usage-based
- No NAT gateway (tasks use public IPs; only the ALB can reach them)

Destroy the stack when you're not using it.

## 12. Troubleshooting

| Symptom | Likely cause / fix |
|---------|-------------------|
| `permission denied ... docker.sock` in Jenkins | Wrong group for the socket. On Linux: `DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) docker compose up -d` |
| Tasks stuck in `PENDING`, `CannotPullContainerError` | Image tag missing on Docker Hub, repo is private without `dockerhub_credentials_secret_arn`, or tasks have no internet route (check `assign_public_ip` / subnet routes). |
| `toomanyrequests: You have reached your pull rate limit` | Anonymous Docker Hub pull limit. Add the pull-credentials secret (step 3, private repository). |
| Push fails: `denied: requested access to the resource is denied` | `DOCKERHUB_REPO` username doesn't match the `dockerhub` credential, or the token is read-only. |
| `dockerhub_repository must look like <username>/<repo>` | Set `DOCKERHUB_REPO` in the Jenkinsfile (lowercase, no `CHANGE-ME`). |
| Deployment rolled back automatically | Circuit breaker fired: new tasks failed health checks. Check CloudWatch log group `/ecs/ecs-demo-dev`. |
| `Error acquiring the state lock` | A previous run died mid-apply. Confirm no run is active, then `terraform force-unlock <LOCK_ID>`. |
| `task_memory ... is not valid for task_cpu` | Pick a combination from the table above. |
| Scale stage: `output ... image_tag not found` | Nothing deployed yet — run `deploy` first. |
