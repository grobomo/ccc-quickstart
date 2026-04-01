#!/usr/bin/env bash
# =============================================================================
# CCC Fleet Configuration
# =============================================================================
# Edit this file, then run: ./deploy.sh
# All values below can be customized. Smart defaults are provided where possible.
# =============================================================================

# -- Fleet Identity -----------------------------------------------------------
# Unique name for this fleet (used as prefix for all AWS resources)
FLEET_NAME="${FLEET_NAME:-ccc-fleet}"

# -- AWS Configuration --------------------------------------------------------
# AWS CLI profile to use (blank = default profile)
AWS_PROFILE="${AWS_PROFILE:-}"
# AWS region (auto-detected from current CLI config if blank)
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"

# -- Compute ------------------------------------------------------------------
# Number of worker instances
WORKER_COUNT="${WORKER_COUNT:-2}"
# EC2 instance type for workers
WORKER_INSTANCE_TYPE="${WORKER_INSTANCE_TYPE:-m5.xlarge}"
# Use spot instances? (true/false)
USE_SPOT="${USE_SPOT:-true}"
# Max spot price (USD/hour, blank = on-demand price cap)
SPOT_MAX_PRICE="${SPOT_MAX_PRICE:-}"
# EC2 instance type for nginx proxy
PROXY_INSTANCE_TYPE="${PROXY_INSTANCE_TYPE:-t3.medium}"

# -- Networking ---------------------------------------------------------------
# Your IP for SSH/admin access (auto-detected if blank)
ADMIN_IP="${ADMIN_IP:-$(curl -s https://checkip.amazonaws.com 2>/dev/null || echo "0.0.0.0")/32}"
# VPC CIDR block
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
# SSH key pair name (must exist in your AWS account)
SSH_KEY_NAME="${SSH_KEY_NAME:-}"

# -- Secrets ------------------------------------------------------------------
# GitHub personal access token (for cloning private repos)
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
# GitHub repo to clone into workers (org/repo format)
GITHUB_REPO="${GITHUB_REPO:-}"
# Anthropic API key for Claude
CLAUDE_API_KEY="${CLAUDE_API_KEY:-}"

# -- Docker -------------------------------------------------------------------
# Docker image tag for worker containers
DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-ccc-worker:latest}"
# Docker registry (blank = local build, or ECR URI)
DOCKER_REGISTRY="${DOCKER_REGISTRY:-}"

# -- Storage ------------------------------------------------------------------
# S3 bucket name for fleet artifacts (auto-generated if blank)
S3_BUCKET="${S3_BUCKET:-${FLEET_NAME}-artifacts-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "000000000000")}"

# -- Tags --------------------------------------------------------------------
# Additional tags applied to all resources (JSON format)
EXTRA_TAGS="${EXTRA_TAGS:-[]}"

# =============================================================================
# Internal helpers -- do not edit below
# =============================================================================
_profile_arg() {
  [[ -n "$AWS_PROFILE" ]] && echo "--profile $AWS_PROFILE" || echo ""
}

_region_arg() {
  echo "--region $AWS_REGION"
}

_aws() {
  # shellcheck disable=SC2046
  aws $(_profile_arg) $(_region_arg) "$@"
}

_stack_name() {
  echo "${FLEET_NAME}-${1}"
}
