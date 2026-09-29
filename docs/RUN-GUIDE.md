# Run Guide (Windows)


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
| 7 | Prepare your Jenkins (tools, plugins, credentials, job) | No |
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

## Step 7 — Prepare your Jenkins

This guide assumes Jenkins is **already installed and running** on your machine. You only need to check it has what this pipeline needs, then add two credentials and one job.

### 7.1 Tools on the Jenkins machine

The pipeline runs `sh` steps that call these commands, so they must be on the `PATH` of the user Jenkins runs as:

| Tool | Check | Used for |
|------|-------|----------|
| Docker (with buildx) | `docker version` (must show a Server) | Tests, image build, push |
| Terraform >= 1.10 | `terraform version` | Infrastructure |
| AWS CLI v2 | `aws --version` | Wait for deploy, find task IPs |
| Git, curl, bash | `git --version`, `curl --version` | Checkout, smoke test, scripts |

> **Jenkins running directly on Windows (not in Docker)?** `sh` steps need a Unix shell. Install Git for Windows, then either add `C:\Program Files\Git\bin` to the system `PATH`, or set **Manage Jenkins → System → Shell executable** to `C:\Program Files\Git\bin\sh.exe`. Restart Jenkins afterwards.
>
> **Jenkins running in a Docker container?** The container needs the Docker CLI, the host's `/var/run/docker.sock` mounted, and Terraform and the AWS CLI installed inside it.

The quickest way to check all of this is a throwaway pipeline job (**New Item → Pipeline**) with this script:

```groovy
pipeline {
  agent any
  stages {
    stage('Check tools') {
      steps { sh 'docker version && terraform version && aws --version && git --version && curl --version' }
    }
  }
}
```

If it goes green, Jenkins is ready. You can delete the job afterwards.

### 7.2 Plugins

**Manage Jenkins → Plugins → Available plugins.** Install any of these that are missing:

| Plugin | Why |
|--------|-----|
| Pipeline | Runs the `Jenkinsfile` |
| Git | Checks out the repo |
| Credentials Binding | `withCredentials` in the pipeline |
| **AWS Credentials** | The `aws-deployer` credential type (usually not installed by default) |
| Timestamper | `timestamps()` in the console log |
| Pipeline: Stage View *(optional)* | The stage overview on the job page |

### 7.3 Add the credentials

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**. Add both of these, and use the IDs exactly as shown:

| Kind | ID | Values |
|------|----|--------|
| **AWS Credentials** | `aws-deployer` | Access Key ID + Secret Access Key from Step 5 |
| **Username with password** | `dockerhub` | Username: your Docker Hub username · Password: the access token from Step 2 |

For a **private** GitHub repo, also add **Username with password** with ID `github`, your GitHub username and a personal access token.

### 7.4 Create the pipeline job

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
   | Terraform Apply | Creates VPC, subnets, security group, IAM roles, ECS cluster, task definition, service |
   | Verify Deployment | Waits for the service to be stable, finds each task's public IP, checks the new version is live on every task, prints the URLs |

4. At **Approval**, optionally open **Build Artifacts → tfplan.txt** to review, then click **Apply**.
5. The first deploy takes about 3–5 minutes. The console ends with one URL per task:

   ```
   App URLs:
   http://3.91.20.14:8080
   http://54.166.7.201:8080
   ```

Open either URL. There is **no load balancer**, so each URL is one specific task: the footer's **Served by task** is different on each.

> These IPs **change on every deploy or scale**, because new tasks get new IPs. Always use the latest URLs.

On Docker Hub, **Repositories → ecs-demo → Tags** now shows the new tag and `latest`.

To find the current URLs later, use any of these:

- **AWS Console:** ECS → Clusters → `ecs-demo-dev-cluster` → Services → `ecs-demo-dev-svc` → **Tasks** → click a task → **Public IP**. Open `http://<Public IP>:8080`.
- **Git Bash:**
  ```bash
  bash scripts/get-app-urls.sh ecs-demo-dev-cluster ecs-demo-dev-svc
  ```
- **PowerShell:**
  ```powershell
  $tasks = aws ecs list-tasks --cluster ecs-demo-dev-cluster --service-name ecs-demo-dev-svc --query "taskArns" --output text
  $enis  = aws ecs describe-tasks --cluster ecs-demo-dev-cluster --tasks $tasks.Split() --query "tasks[].attachments[].details[?name=='networkInterfaceId'].value" --output text
  aws ec2 describe-network-interfaces --network-interface-ids $enis.Split() --query "NetworkInterfaces[].Association.PublicIp" --output text
  ```

---

## Step 9 — Demo scaling

All scaling runs through **Build with Parameters**.

| Demo | Parameters | What you'll see |
|------|-----------|-----------------|
| **Vertical** (bigger tasks) | `ACTION=scale`, `TASK_CPU=512`, `TASK_MEMORY=1024` | New task definition revision; new tasks start, then the old ones stop (new IPs) |
| **Horizontal** (more tasks) | `ACTION=scale`, `DESIRED_COUNT=3` | Service grows to 3 running tasks, and 3 URLs are printed |
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

The stack costs roughly **$0.80 per day** while running (2 small Fargate tasks plus their public IPs).

1. Jenkins → **Build with Parameters** → `ACTION = destroy` → approve.
2. *(Optional)* Delete the image repository on Docker Hub: **Repositories → ecs-demo → Settings → Delete repository**.

The S3 state bucket is kept (it costs almost nothing). To delete it too, empty the bucket (including old versions), then run `terraform destroy -var="bucket_name=<name>"` in `terraform\bootstrap`.

---

## Common problems

| Problem | Fix |
|---------|-----|
| `failed to connect to the docker API ... docker_engine` | Docker Desktop is not running. Start it and wait for *Engine running*. |
| `aws` / `terraform` not recognized | Open a new terminal after installing, or reinstall with `winget`. |
| Jenkins: `sh: not found` or `Cannot run program "sh"` | Jenkins runs on Windows without a Unix shell. See the note in Step 7.1. |
| Jenkins: `docker: not found` / `terraform: not found` | The tool isn't on the PATH of the Jenkins service. Add it, then restart Jenkins. |
| Jenkins: `permission denied ... docker.sock` | The Jenkins user can't use Docker. On Linux: `sudo usermod -aG docker jenkins`, then restart Jenkins. |
| Jenkins: `No such DSL method 'aws'` or no **AWS Credentials** kind | Install the **AWS Credentials** plugin (Step 7.2). |
| Jenkins: `Could not find credentials entry with ID 'aws-deployer'` or `'dockerhub'` | The IDs must match exactly. `aws-deployer` must be of kind **AWS Credentials**, and `dockerhub` of kind **Username with password**. |
| Push: `denied: requested access to the resource is denied` | The username in `DOCKERHUB_REPO` doesn't match the `dockerhub` credential, or the token is not **Read & Write**. |
| Tasks stuck, `CannotPullContainerError` | The tag isn't on Docker Hub, or the repo is private (it must be public). |
| `toomanyrequests: ... pull rate limit` | Docker Hub anonymous pull limit. Wait and retry; ECS keeps trying. |
| `terraform fmt -check` fails in Jenkins | Run `terraform fmt -recursive` in the `terraform` folder, then commit and push. |
| `NoSuchBucket` / `AccessDenied` on init | `TF_STATE_BUCKET` in the Jenkinsfile doesn't match your bucket, or the IAM policy still has `CHANGE-ME`. |
| Apply fails with an invalid CPU / memory error | Use a pair from the table in Step 9. |
| Browser can't open `http://<ip>:8080` | The task was replaced and has a new IP; get the current URLs (Step 8). Use `http://`, not `https://`. |
| Deployment rolled back automatically | New tasks failed health checks. Check logs in CloudWatch `/ecs/ecs-demo-dev`. |
| `Error acquiring the state lock` | A previous run stopped mid-apply. Make sure nothing is running, then `terraform force-unlock <LOCK_ID>`. |
| Scale fails with `output "image_tag" not found` | Nothing is deployed yet. Run `ACTION=deploy` first. |
