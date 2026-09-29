// CI/CD pipeline: test -> build -> push to Docker Hub -> terraform plan/apply -> verify on ECS Fargate.
//
// Actions:
//   deploy     build a new image from this commit and roll it out (plus any infra / task-size changes)
//   plan-only  run tests and show the Terraform plan, change nothing
//   scale      keep the current image, apply new CPU/memory (vertical) and task counts (horizontal)
//   destroy    tear everything down (always requires approval)
//
// Required Jenkins setup (see docs/SETUP.md):
//   - Credential "aws-deployer" of type "AWS Credentials" (AWS Credentials plugin)
//   - Credential "dockerhub" of type "Username with password" (Docker Hub user + access token)
//   - DOCKERHUB_REPO below set to <your-dockerhub-user>/ecs-demo
//   - Agent with docker, terraform >= 1.10, aws cli v2, curl, git

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 60, unit: 'MINUTES')
  }

  parameters {
    choice(name: 'ACTION', choices: ['deploy', 'plan-only', 'scale', 'destroy'], description: 'What this run should do')
    choice(name: 'TASK_CPU', choices: ['256', '512', '1024', '2048', '4096'], description: 'Vertical scaling: Fargate CPU units per task')
    string(name: 'TASK_MEMORY', defaultValue: '512', description: 'Vertical scaling: memory (MiB) per task, must match CPU (e.g. 256->512-2048, 512->1024-4096, 1024->2048-8192)')
    string(name: 'DESIRED_COUNT', defaultValue: '2', description: 'Horizontal scaling: task count (applied on first deploy and by the scale action)')
    string(name: 'MIN_TASKS', defaultValue: '1', description: 'Autoscaling minimum tasks')
    string(name: 'MAX_TASKS', defaultValue: '4', description: 'Autoscaling maximum tasks')
    booleanParam(name: 'AUTO_APPROVE', defaultValue: false, description: 'Skip the manual approval before apply (never skipped for destroy)')
  }

  environment {
    AWS_CREDS_ID       = 'aws-deployer'
    DOCKERHUB_CREDS_ID = 'dockerhub'
    DOCKERHUB_REPO     = 'CHANGE-ME/ecs-demo'           // <dockerhub-username>/<repository>
    AWS_REGION         = 'us-east-1'
    AWS_DEFAULT_REGION = 'us-east-1'
    PROJECT_NAME       = 'ecs-demo'
    DEPLOY_ENV         = 'dev'
    TF_DIR             = 'terraform'
    TF_STATE_BUCKET    = 'CHANGE-ME-ecs-demo-tfstate'   // bucket created by terraform/bootstrap
    TF_IN_AUTOMATION   = 'true'
    TF_INPUT           = '0'

    // Terraform input variables (picked up automatically as TF_VAR_<name>)
    TF_VAR_aws_region    = "${AWS_REGION}"
    TF_VAR_project_name  = "${PROJECT_NAME}"
    TF_VAR_environment   = "${DEPLOY_ENV}"
    TF_VAR_dockerhub_repository = "${DOCKERHUB_REPO}"
    TF_VAR_task_cpu      = "${params.TASK_CPU}"
    TF_VAR_task_memory   = "${params.TASK_MEMORY}"
    TF_VAR_desired_count = "${params.DESIRED_COUNT}"
    TF_VAR_min_capacity  = "${params.MIN_TASKS}"
    TF_VAR_max_capacity  = "${params.MAX_TASKS}"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          def sha = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()
          env.IMAGE_TAG = "${sha}-${env.BUILD_NUMBER}"
          env.TF_VAR_image_tag = env.IMAGE_TAG
          currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.ACTION} ${env.IMAGE_TAG}"
        }
      }
    }

    stage('Unit Tests') {
      when { expression { params.ACTION in ['deploy', 'plan-only'] } }
      steps {
        // The Dockerfile's "test" stage runs pytest; a failing test fails the build.
        sh 'docker build --target test -t "$PROJECT_NAME:test-$IMAGE_TAG" app'
      }
    }

    stage('Terraform Init & Validate') {
      steps {
        withCredentials([aws(credentialsId: env.AWS_CREDS_ID)]) {
          dir(env.TF_DIR) {
            sh '''
              terraform init -reconfigure \
                -backend-config="bucket=$TF_STATE_BUCKET" \
                -backend-config="region=$AWS_REGION"
              terraform fmt -check -recursive
              terraform validate
            '''
          }
        }
      }
    }

    stage('Build Image') {
      when { expression { params.ACTION == 'deploy' } }
      steps {
        sh '''
          docker build --target runtime \
            --build-arg APP_VERSION="$IMAGE_TAG" \
            -t "$PROJECT_NAME:$IMAGE_TAG" app
        '''
      }
    }

    stage('Push to Docker Hub') {
      when { expression { params.ACTION == 'deploy' } }
      steps {
        withCredentials([usernamePassword(credentialsId: env.DOCKERHUB_CREDS_ID,
                                          usernameVariable: 'DOCKERHUB_USER',
                                          passwordVariable: 'DOCKERHUB_TOKEN')]) {
          // The repository is created automatically on first push (public by default).
          sh '''
            echo "$DOCKERHUB_TOKEN" | docker login --username "$DOCKERHUB_USER" --password-stdin
            docker tag "$PROJECT_NAME:$IMAGE_TAG" "$DOCKERHUB_REPO:$IMAGE_TAG"
            docker tag "$PROJECT_NAME:$IMAGE_TAG" "$DOCKERHUB_REPO:latest"
            docker push "$DOCKERHUB_REPO:$IMAGE_TAG"
            docker push "$DOCKERHUB_REPO:latest"
          '''
        }
      }
      post {
        always { sh 'docker logout >/dev/null 2>&1 || true' }
      }
    }

    stage('Resolve Current Image') {
      when { expression { params.ACTION == 'scale' } }
      steps {
        // Scaling must not change the running image, so reuse the deployed tag.
        withCredentials([aws(credentialsId: env.AWS_CREDS_ID)]) {
          script {
            env.TF_VAR_image_tag = sh(returnStdout: true,
              script: 'terraform -chdir="$TF_DIR" output -raw image_tag').trim()
            echo "Scaling service while keeping image tag ${env.TF_VAR_image_tag}"
          }
        }
      }
    }

    stage('Terraform Plan') {
      steps {
        withCredentials([aws(credentialsId: env.AWS_CREDS_ID)]) {
          dir(env.TF_DIR) {
            script {
              def destroyFlag = params.ACTION == 'destroy' ? '-destroy' : ''
              sh "terraform plan ${destroyFlag} -out=tfplan"
              sh 'terraform show -no-color tfplan > tfplan.txt'
            }
          }
        }
        archiveArtifacts artifacts: "${env.TF_DIR}/tfplan.txt", fingerprint: true
      }
    }

    stage('Approval') {
      when {
        expression { params.ACTION != 'plan-only' && (params.ACTION == 'destroy' || !params.AUTO_APPROVE) }
      }
      steps {
        timeout(time: 30, unit: 'MINUTES') {
          input message: "Apply Terraform plan for '${params.ACTION}' (${env.TF_VAR_image_tag})? Review tfplan.txt in the build artifacts.",
                ok: 'Apply'
        }
      }
    }

    stage('Terraform Apply') {
      when { expression { params.ACTION != 'plan-only' } }
      steps {
        withCredentials([aws(credentialsId: env.AWS_CREDS_ID)]) {
          dir(env.TF_DIR) {
            sh 'terraform apply -auto-approve tfplan'
          }
        }
      }
    }

    stage('Scale Task Count') {
      when { expression { params.ACTION == 'scale' } }
      steps {
        // desired_count is ignored by Terraform after creation, so set it directly.
        withCredentials([aws(credentialsId: env.AWS_CREDS_ID)]) {
          sh '''
            chmod +x scripts/scale-service.sh
            scripts/scale-service.sh \
              "$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)" \
              "$(terraform -chdir="$TF_DIR" output -raw ecs_service_name)" \
              "$DESIRED_COUNT"
          '''
        }
      }
    }

    stage('Verify Deployment') {
      when { expression { params.ACTION in ['deploy', 'scale'] } }
      steps {
        withCredentials([aws(credentialsId: env.AWS_CREDS_ID)]) {
          sh '''
            CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)
            SERVICE=$(terraform -chdir="$TF_DIR" output -raw ecs_service_name)
            URL=$(terraform -chdir="$TF_DIR" output -raw alb_url)

            echo "Waiting for $SERVICE to reach a steady state..."
            aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"

            echo "Smoke testing $URL"
            for i in $(seq 1 20); do
              if INFO=$(curl -fsS --max-time 5 "$URL/api/info"); then
                echo "$INFO"
                if echo "$INFO" | grep -q "\\"$TF_VAR_image_tag\\""; then
                  echo "Version $TF_VAR_image_tag is live at $URL"
                  exit 0
                fi
              fi
              echo "Attempt $i: not ready yet, retrying in 10s"
              sleep 10
            done
            echo "Smoke test failed"
            exit 1
          '''
        }
      }
    }
  }

  post {
    success {
      echo "Pipeline '${params.ACTION}' succeeded for ${env.TF_VAR_image_tag}"
    }
    failure {
      echo "Pipeline '${params.ACTION}' failed. ECS circuit breaker rolls back failed deployments automatically."
    }
    always {
      sh 'rm -f "$TF_DIR/tfplan"; docker image prune -f >/dev/null 2>&1 || true'
    }
  }
}
