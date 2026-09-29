# Run Guide (Windows)

Step-by-step instructions to run this project on Windows, from a local test to a live deployment on AWS ECS Fargate through Jenkins.
Images are stored on **Docker Hub**. Jenkins pushes them and ECS pulls them.
Run all commands in **PowerShell** from the project folder unless a step says otherwise.

```powershell
cd "D:\my\Projects\containerized application deploymenet using iac"
```

> Reference details (IAM, scaling tables, cost, troubleshooting) are in [docs/SETUP.md](SETUP.md).

---

## Overview

| Step | What you do | Needs AWS? |
|------|-------------|-----------|
| 0 | Install and start tools | No |
| 1 | Run the app locally | No |
| 2 | Prepare Docker Hub | No |
| 3 | Connect your terminal to AWS | Yes |
| 4 | Create the Terraform state bucket | Yes |
| 5 | Create the IAM user for Jenkins | Yes |
| 6 | Push the code to GitHub | No |
| 7 | Start and configure Jenkins | No |
| 8 | Deploy to AWS from Jenkins | Yes |
| 9 | Demo scaling | Yes |
| 10 | Tear down | Yes |

---

## Step 0 — Install and start the tools

| Tool | Install |
|------|---------|
| Git | `winget install Git.Git` |
| Terraform (>= 1.10) | `winget install Hashicorp.Terraform` |
| Docker Desktop | `winget install Docker.DockerDesktop`, then **start Docker Desktop** and wait for *Engine running* |
| AWS CLI v2 | `winget install Amazon.AWSCLI` |
| AWS account | With admin access |
| Docker Hub account | Free sign-up at https://hub.docker.com |

Open a **new** terminal after installing, then verify:

```powershell
git --version
terraform version
docker version        # must show both Client and Server
aws --version
```

---

## Step 1 — Run the app locally

This step needs no AWS account.

```powershell
# Run the unit tests (the Dockerfile "test" stage runs pytest; build fails if tests fail)
docker build --target test -t ecs-demo:test app

# Build and run the app
docker compose up --build
```

Open **http://localhost:8080**. You should see the **Calculator**. Try `(2 + 3) × 4`, then `=`. The keyboard works too: digits, `+ - * / % ^ ( )`, Enter, Backspace, Esc.

Test the API directly from PowerShell:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:8080/api/calculate `
  -ContentType "application/json" -Body '{"expression": "(2 + 3) * 4 ^ 2"}'
# expression       hostname      result
# ----------       --------      ------
# (2 + 3) * 4 ^ 2  3f1c...           80
```

Other endpoints: http://localhost:8080/health and http://localhost:8080/api/info

Stop it with `Ctrl+C`, then `docker compose down`.

---

## Step 2 — Prepare Docker Hub

1. Sign in at https://hub.docker.com.
2. Click your avatar → **Account settings → Personal access tokens → Generate new token**.
   - Description: `jenkins`
   - Access permissions: **Read & Write**
   - Copy the token now. It is shown only once, and you will need it in Step 7.
3. Open [Jenkinsfile](../Jenkinsfile) and set your repository (lowercase):

   ```groovy
   DOCKERHUB_REPO     = 'your-dockerhub-username/ecs-demo'
   ```

You don't need to create the repository by hand. Docker Hub creates it as **public** on the first push.

*(Optional)* Test the push from your machine:

```powershell
docker login -u your-dockerhub-username          # paste the token as the password
docker build --target runtime -t your-dockerhub-username/ecs-demo:manual-test app
docker push your-dockerhub-username/ecs-demo:manual-test
docker logout
```

> Keep the repository **public**. ECS pulls the image without logging in to Docker Hub.

---

## Step 3 — Connect your terminal to AWS

1. AWS Console → **IAM → Users → Create user** (e.g. `admin-cli`) → attach **AdministratorAccess**.
2. Open the user → **Security credentials → Create access key** → use case **CLI**.
3. Configure the CLI:

```powershell
aws configure
# AWS Access Key ID:     <paste>
# AWS Secret Access Key: <paste>
# Default region name:   us-east-1
# Default output format: json

aws sts get-caller-identity   # prints your 12-digit account ID
```

---

## Step 4 — Create the Terraform state bucket (one time)

The bucket name must be globally unique. A safe pattern is `ecs-demo-tfstate-<account-id>`.

```powershell
cd terraform\bootstrap
terraform init
terraform apply -var="bucket_name=ecs-demo-tfstate-123456789012"
# type: yes
cd ..\..
```

Now replace `CHANGE-ME-ecs-demo-tfstate` with your bucket name in:

- [Jenkinsfile](../Jenkinsfile) → the `TF_STATE_BUCKET` line
- [docs/jenkins-iam-policy.json](jenkins-iam-policy.json) → both `Resource` lines under `TerraformState`

---

## Step 5 — Create the IAM user for Jenkins

1. **IAM → Policies → Create policy → JSON** → paste the contents of `docs/jenkins-iam-policy.json` → name it `ecs-demo-jenkins`.
2. **IAM → Users → Create user** `jenkins-deployer` → attach the `ecs-demo-jenkins` policy.
3. Open the user → **Create access key** → save the key and secret for Step 7.

---

## Step 6 — Push the code to GitHub

Check that both placeholders are filled in before you commit:

```powershell
Select-String -Path Jenkinsfile -Pattern "CHANGE-ME"   # should print nothing
```

Create an empty repository on GitHub first (no README, no .gitignore). Then:

```powershell
git init
git add .
git commit -m "ECS Fargate app with Terraform and Jenkins"
git branch -M main
git remote add origin https://github.com/<your-user>/<repo>.git
git push -u origin main
```

---

## Step 7 — Start and configure Jenkins

### 7.1 Start Jenkins

```powershell
cd jenkins
docker compose up -d --build     # first build takes ~5 minutes
docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
cd ..
```

1. Open **http://localhost:8081** and paste the password.
2. Choose **Install suggested plugins**.
3. Create your admin user.

Check that Jenkins can use Docker, Terraform and the AWS CLI:

```powershell
docker exec jenkins sh -c "docker ps && terraform version && aws --version"
```

### 7.2 Add the credentials

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**. Add both of these, and use the IDs exactly as shown:

| Kind | ID | Values |
|------|----|--------|
| **AWS Credentials** | `aws-deployer` | Access Key ID + Secret Access Key from Step 5 |
| **Username with password** | `dockerhub` | Username: your Docker Hub username · Password: the access token from Step 2 |

For a **private** GitHub repo, also add **Username with password** with ID `github`, your GitHub username and a personal access token.

### 7.3 Create the pipeline job

1. **New Item** → name `ecs-demo` → **Pipeline** → OK.
2. In the **Pipeline** section:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git** → Repository URL: your repo (+ `github` credential if private)
   - Branch Specifier: `*/main`
   - Script Path: `Jenkinsfile`
3. *(Optional)* **Build Triggers** → **Poll SCM** → `H/5 * * * *` to build automatically on new commits.
4. **Save**.

---

## Step 8 — Deploy to AWS

1. Click **Build Now** once. The first run only registers the pipeline parameters, so it may fail or run with defaults.
2. Click **Build with Parameters** → `ACTION = deploy` → **Build**.
3. Watch progress in **Stage View** or **Console Output**:

   | Stage | What happens |
   |-------|--------------|
   | Checkout | Pulls code, sets image tag `<git-sha>-<build-number>` |
   | Unit Tests | Runs pytest inside the Docker test stage |
   | Terraform Init & Validate | Connects to the S3 state, runs `fmt -check` and `validate` |
   | Build Image | Builds the runtime image |
   | Push to Docker Hub | Logs in with the `dockerhub` credential, pushes `<tag>` and `latest` |
   | Terraform Plan | Plans the changes and archives `tfplan.txt` |
   | Approval | Waits for you to click **Apply** |
   | Terraform Apply | Creates VPC, ALB, ECS cluster, task definition, service, IAM, autoscaling |
   | Verify Deployment | Waits for the service to be stable and checks the new version is live |

4. At **Approval**, optionally open **Build Artifacts → tfplan.txt** to review, then click **Apply**.
5. The first deploy takes about 5–8 minutes. The console ends with:

   ```
   Version abc1234-2 is live at http://ecs-demo-dev-alb-xxxx.us-east-1.elb.amazonaws.com
   ```

Open that URL. Refresh a few times: **Served by task** changes because two tasks share the traffic.
On Docker Hub, **Repositories → ecs-demo → Tags** now shows the new tag and `latest`.

To see the URL again later:

```powershell
cd terraform
Copy-Item backend.hcl.example backend.hcl   # then edit the bucket name
terraform init -backend-config=backend.hcl
terraform output alb_url
terraform output image
cd ..
```

---

## Step 9 — Demo scaling

All scaling runs through **Build with Parameters**.

| Demo | Parameters | What you'll see |
|------|-----------|-----------------|
| **Vertical** (bigger tasks) | `ACTION=scale`, `TASK_CPU=512`, `TASK_MEMORY=1024` | New task definition revision; tasks are replaced one by one with no downtime |
| **Horizontal** (more tasks) | `ACTION=scale`, `DESIRED_COUNT=3`, `MAX_TASKS=5` | Service grows to 3 running tasks |
| **New release** | Change the `<h1>Calculator</h1>` title in `app/src/templates/index.html`, commit, push, then `ACTION=deploy` | New tag on Docker Hub, new version on the page |
| **Dry run** | `ACTION=plan-only` | Tests and plan only, no changes |

Valid CPU / memory pairs:

| CPU | Memory (MiB) |
|-----|--------------|
| 256 | 512, 1024, 2048 |
| 512 | 1024 – 4096 |
| 1024 | 2048 – 8192 |
| 2048 | 4096 – 16384 |
| 4096 | 8192 – 30720 |

To watch the rollout: AWS Console → **ECS → Clusters → ecs-demo-dev-cluster → Services → ecs-demo-dev-svc → Tasks / Deployments**.
Container logs: **CloudWatch → Log groups → /ecs/ecs-demo-dev**.

---

## Step 10 — Tear down

The stack costs roughly **$1 per day** while running.

1. Jenkins → **Build with Parameters** → `ACTION = destroy` → approve.
2. Stop Jenkins locally:

   ```powershell
   cd jenkins
   docker compose down        # add -v to also delete Jenkins data
   cd ..
   ```

3. *(Optional)* Delete the image repository on Docker Hub: **Repositories → ecs-demo → Settings → Delete repository**.

The S3 state bucket is kept (it costs almost nothing). To delete it too, empty the bucket (including old versions), then run `terraform destroy -var="bucket_name=<name>"` in `terraform\bootstrap`.

---

## Common problems

| Problem | Fix |
|---------|-----|
| `failed to connect to the docker API ... docker_engine` | Docker Desktop is not running. Start it and wait for *Engine running*. |
| `aws` / `terraform` not recognized | Open a new terminal after installing, or reinstall with `winget`. |
| Jenkins: `permission denied ... docker.sock` | Restart Jenkins: `cd jenkins; docker compose down; docker compose up -d`. On Linux hosts, set `DOCKER_GID` (see docs/SETUP.md). |
| Jenkins: `Could not find credentials entry with ID 'aws-deployer'` or `'dockerhub'` | The IDs must match exactly. `aws-deployer` must be of kind **AWS Credentials**, and `dockerhub` of kind **Username with password**. |
| Push: `denied: requested access to the resource is denied` | The username in `DOCKERHUB_REPO` doesn't match the `dockerhub` credential, or the token is not **Read & Write**. |
| Tasks stuck, `CannotPullContainerError` | The tag isn't on Docker Hub, or the repo is private (it must be public). |
| `toomanyrequests: ... pull rate limit` | Docker Hub anonymous pull limit. Wait and retry; ECS keeps trying. |
| `terraform fmt -check` fails in Jenkins | Run `terraform fmt -recursive` in the `terraform` folder, then commit and push. |
| `NoSuchBucket` / `AccessDenied` on init | `TF_STATE_BUCKET` in the Jenkinsfile doesn't match your bucket, or the IAM policy still has `CHANGE-ME`. |
| Apply fails with an invalid CPU / memory error | Use a pair from the table in Step 9. |
| Deployment rolled back automatically | New tasks failed health checks. Check logs in CloudWatch `/ecs/ecs-demo-dev`. |
| `Error acquiring the state lock` | A previous run stopped mid-apply. Make sure nothing is running, then `terraform force-unlock <LOCK_ID>`. |
| Scale fails with `output "image_tag" not found` | Nothing is deployed yet. Run `ACTION=deploy` first. |
