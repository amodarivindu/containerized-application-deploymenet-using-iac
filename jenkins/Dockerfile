# Jenkins controller with everything the pipeline needs: docker CLI + buildx,
# Terraform, AWS CLI v2. Uses the host's Docker daemon via the mounted socket.
FROM jenkins/jenkins:lts-jdk21

USER root

ARG TERRAFORM_VERSION=1.12.2
ARG DOCKER_VERSION=27.3.1
ARG BUILDX_VERSION=v0.17.1

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI (static binary) + buildx plugin
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
      | tar -xz -C /tmp \
 && mv /tmp/docker/docker /usr/local/bin/docker \
 && rm -rf /tmp/docker \
 && mkdir -p /usr/local/lib/docker/cli-plugins \
 && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-buildx \
      "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
 && chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx

# Terraform
RUN curl -fsSL -o /tmp/terraform.zip \
      "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
 && unzip -q /tmp/terraform.zip -d /usr/local/bin \
 && rm /tmp/terraform.zip

# AWS CLI v2
RUN curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
 && unzip -q /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscliv2.zip

USER jenkins

# Pre-install the plugins the Jenkinsfile relies on.
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
