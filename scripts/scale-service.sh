#!/usr/bin/env bash
# Horizontally scale an ECS service by updating its desired task count.
# Usage: scripts/scale-service.sh <cluster> <service> <desired-count>
#
# Note: when autoscaling is enabled, the autoscaler keeps the count within
# [min_capacity, max_capacity]; values outside that range will be pulled back.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <cluster> <service> <desired-count>" >&2
  exit 1
fi

CLUSTER="$1"
SERVICE="$2"
DESIRED="$3"
REGION="${AWS_REGION:-us-east-1}"

if ! [[ "$DESIRED" =~ ^[0-9]+$ ]]; then
  echo "desired-count must be a non-negative integer, got '$DESIRED'" >&2
  exit 1
fi

echo "Scaling $SERVICE in $CLUSTER to $DESIRED task(s)..."
aws ecs update-service \
  --region "$REGION" \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --desired-count "$DESIRED" \
  --output text --query 'service.serviceName' >/dev/null

aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE"

aws ecs describe-services \
  --region "$REGION" \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --query 'services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount,TaskDefinition:taskDefinition}' \
  --output table
