#!/usr/bin/env bash
# Print the public URL of every running task in an ECS service.
# Usage: scripts/get-app-urls.sh <cluster> <service> [port]
#
# There is no load balancer, so each task has its own public IP,
# and that IP changes whenever a task is replaced (deploy, scale, crash).
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <cluster> <service> [port]" >&2
  exit 1
fi

CLUSTER="$1"
SERVICE="$2"
PORT="${3:-8080}"

# 1. Running tasks of the service
TASKS=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
  --desired-status RUNNING --query 'taskArns' --output text)

if [[ -z "$TASKS" || "$TASKS" == "None" ]]; then
  echo "No running tasks in $SERVICE" >&2
  exit 1
fi

# 2. Network interface attached to each task
# shellcheck disable=SC2086
ENIS=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASKS \
  --query "tasks[].attachments[].details[?name=='networkInterfaceId'].value" --output text)

# 3. Public IP of each network interface
# shellcheck disable=SC2086
aws ec2 describe-network-interfaces --network-interface-ids $ENIS \
  --query 'NetworkInterfaces[].Association.PublicIp' --output text \
  | tr '\t' '\n' | sed "s|^|http://|; s|\$|:$PORT|"
