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
   The repository is created automatically on the first push, as **public**. Keep it public: ECS pulls the image without logging in.

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
terraform apply -var="bucket_name=<globally-unique-bucket-name>"
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

Build with Parameters → `ACTION=deploy` (defaults: 0.25 vCPU / 512 MiB, 2 tasks).

Pipeline stages:

1. **Unit Tests** – `docker build --target test` runs pytest inside the image build.
2. **Terraform Init & Validate** – S3 backend, `fmt -check`, `validate`.
3. **Build Image** – runtime image tagged `<git-sha>-<build-number>`.
4. **Push to Docker Hub** – logs in with the `dockerhub` credential, pushes `<git-sha>-<build>` and `latest`.
5. **Terraform Plan** – saved as `tfplan`, readable copy archived as `tfplan.txt`.
6. **Approval** – manual gate (skip with `AUTO_APPROVE`, never skipped for destroy).
7. **Terraform Apply** – creates/updates VPC, subnets, security group, IAM roles, ECS cluster, task definition, service.
8. **Verify Deployment** – waits for the service to be stable, finds each task's public IP (`scripts/get-app-urls.sh`), checks that `/api/info` on every task returns the new version, and prints the URLs.

The app URLs (`http://<task-public-ip>:8080`, one per task) are printed at the end of the console log. There is no load balancer, so these IPs **change on every deploy or scale**. Get the current ones any time with:

```bash
scripts/get-app-urls.sh ecs-demo-dev-cluster ecs-demo-dev-svc
```

or in the ECS console: *Clusters → ecs-demo-dev-cluster → Services → ecs-demo-dev-svc → Tasks → (task) → Public IP*.

The first apply takes ~2–3 minutes.

## 8. Scaling

### Vertical (task size)

Run `ACTION=scale` (or `deploy`) with new `TASK_CPU` / `TASK_MEMORY`, e.g. `1024` / `2048`.
Terraform registers a new task definition revision and ECS replaces the tasks: new ones start first, then the old ones stop. The new tasks have new public IPs.

Valid Fargate combinations:

| CPU | Memory (MiB) |
|-----|--------------|
| 256 | 512, 1024, 2048 |
| 512 | 1024 – 4096 (1 GiB steps) |
| 1024 | 2048 – 8192 |
| 2048 | 4096 – 16384 |
| 4096 | 8192 – 30720 |

Any other combination is rejected by AWS during `terraform apply` (the error names the invalid CPU/memory values).

### Horizontal (task count)

Run `ACTION=scale` (or `deploy`) with a new `DESIRED_COUNT`. Terraform updates `desired_count` on the ECS service, and ECS starts or stops tasks to match.
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
To remove the state bucket too, empty it (including old versions), then run `terraform destroy -var="bucket_name=<name>"` in `terraform/bootstrap`.

## 11. Cost notes

Approximate us-east-1 cost with the defaults, running 24/7:

- Fargate: 2 × (0.25 vCPU, 0.5 GB) ≈ $18/month
- CloudWatch Logs / Container Insights: small, usage-based
- No load balancer or NAT gateway (tasks use public IPs directly)
- Public IPv4 addresses: ~$3.60/month each

Destroy the stack when you're not using it.

## 12. Troubleshooting

| Symptom | Likely cause / fix |
|---------|-------------------|
| `permission denied ... docker.sock` in Jenkins | Wrong group for the socket. On Linux: `DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) docker compose up -d` |
| Tasks stuck in `PENDING`, `CannotPullContainerError` | Image tag missing on Docker Hub, repo is private (it must be public), or tasks have no internet route (check `assign_public_ip` / subnet routes). |
| `toomanyrequests: You have reached your pull rate limit` | Docker Hub's anonymous pull limit. Wait and retry; ECS keeps trying to start the tasks. |
| Push fails: `denied: requested access to the resource is denied` | `DOCKERHUB_REPO` username doesn't match the `dockerhub` credential, or the token is read-only. |
| Browser can't open `http://<ip>:8080` | The task was replaced and has a new IP; rerun `scripts/get-app-urls.sh`. Use `http://`, not `https://`. |
| Deployment rolled back automatically | Circuit breaker fired: new tasks failed health checks. Check CloudWatch log group `/ecs/ecs-demo-dev`. |
| `Error acquiring the state lock` | A previous run died mid-apply. Confirm no run is active, then `terraform force-unlock <LOCK_ID>`. |
| `Invalid 'cpu' setting for task` / invalid memory on apply | Pick a CPU/memory combination from the table above. |
| Scale stage: `output ... image_tag not found` | Nothing deployed yet — run `deploy` first. |
