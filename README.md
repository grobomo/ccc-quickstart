# CCC Fleet Quickstart

Deploy a Claude Code Computer fleet on AWS in one command.

```
ccc-quickstart/
  fleet-config.sh          # <-- Edit this one file
  deploy.sh                # <-- Run this one command
  status.sh                # Fleet health dashboard
  submit.sh                # Submit tasks to fleet
  teardown.sh              # Clean removal
  Dockerfile               # Worker container image
  entrypoint.sh            # Worker entrypoint
  cloudformation/
    network.yaml            # VPC, subnets, security groups
    storage.yaml            # S3 bucket, IAM roles
    workers.yaml            # Auto Scaling Group for workers
    proxy.yaml              # Nginx proxy + dashboard
```

## Quickstart

### 1. Configure

Edit `fleet-config.sh` -- only 3 values are required:

```bash
CLAUDE_API_KEY="sk-ant-..."     # Your Anthropic API key
SSH_KEY_NAME="my-keypair"       # Existing EC2 key pair
FLEET_NAME="my-fleet"           # Unique name for your fleet
```

Everything else has smart defaults (region auto-detected, admin IP auto-detected, 2 spot workers, etc).

### 2. Deploy

```bash
./deploy.sh
```

This will:
- Validate prerequisites (AWS CLI, credentials, secrets)
- Create VPC, subnets, and security groups
- Create S3 bucket and IAM roles
- Store API keys in AWS Secrets Manager
- Launch worker instances with Docker
- Deploy nginx proxy with dashboard
- Print your dashboard URL

### 3. Use

```bash
# Submit a task
./submit.sh "Fix the login bug in auth.py"

# Submit with repo context
./submit.sh --repo "Refactor the auth module"

# Submit multiple tasks from file
./submit.sh --file tasks.txt

# Check task status
./submit.sh --status task-1234567890-abc123

# List all tasks
./submit.sh --list

# Fleet health
./status.sh
```

### 4. Tear Down

```bash
./teardown.sh
```

Deletes all stacks, secrets, and SSM parameters. S3 bucket is retained (delete manually if desired).

## Prerequisites

- AWS CLI v2 configured with credentials
- `jq` installed
- EC2 key pair created in your target region
- Anthropic API key

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_NAME` | `ccc-fleet` | Prefix for all AWS resources |
| `AWS_PROFILE` | (default) | AWS CLI profile |
| `AWS_REGION` | (auto-detected) | AWS region |
| `WORKER_COUNT` | `2` | Number of worker instances |
| `WORKER_INSTANCE_TYPE` | `m5.xlarge` | Worker EC2 type |
| `USE_SPOT` | `true` | Use spot instances |
| `SPOT_MAX_PRICE` | (on-demand cap) | Max spot bid |
| `PROXY_INSTANCE_TYPE` | `t3.medium` | Proxy EC2 type |
| `ADMIN_IP` | (auto-detected) | Your IP for SSH |
| `VPC_CIDR` | `10.0.0.0/16` | VPC network range |
| `SSH_KEY_NAME` | (required) | EC2 key pair name |
| `CLAUDE_API_KEY` | (required) | Anthropic API key |
| `GITHUB_TOKEN` | (optional) | GitHub PAT for private repos |
| `GITHUB_REPO` | (optional) | Repo to clone (org/repo) |
| `S3_BUCKET` | (auto-generated) | Artifact bucket name |

## Architecture

```
                    +------------------+
  User ----------> |  Nginx Proxy     |
  (HTTP :80)       |  + Dashboard     |
                    +--------+---------+
                             |
              +--------------+--------------+
              |              |              |
        +-----+-----+ +-----+-----+ +-----+-----+
        |  Worker 1  | |  Worker 2  | |  Worker N  |
        |  (Docker)  | |  (Docker)  | |  (Docker)  |
        |  Claude CC | |  Claude CC | |  Claude CC |
        +-----+------+ +-----+------+ +-----+------+
              |              |              |
              +--------------+--------------+
                             |
                    +--------+---------+
                    |  S3 Artifacts    |
                    |  Secrets Manager |
                    +------------------+
```

Workers run as Docker containers on EC2 spot instances. The nginx proxy load-balances
across workers and serves a real-time dashboard. Workers pull secrets from AWS Secrets
Manager and artifacts from S3 at boot.

## Dry Run

Preview what will be deployed without creating anything:

```bash
./deploy.sh --dry-run
```

## Customizing Workers

Edit `Dockerfile` and `entrypoint.sh` to customize the worker environment. Workers
are rebuilt from S3 on each instance launch, so changes take effect on next scale event
or instance replacement.
