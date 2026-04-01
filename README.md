# CCC Fleet Quickstart

One-click deployment kit for Claude Code Computer (CCC) fleets on AWS. Edit one config file, run one command, get a working fleet.

## Architecture

```
                    +------------------+
                    |   Nginx Proxy    |
                    |   (Dashboard +   |
    Internet ------>|    Load Balancer) |
                    +--------+---------+
                             |
              +--------------+--------------+
              |              |              |
        +-----+----+  +-----+----+  +------+---+
        | Worker 1  |  | Worker 2  |  | Worker N |
        | (Docker)  |  | (Docker)  |  | (Docker) |
        | Claude CLI|  | Claude CLI|  | Claude CLI|
        +-----------+  +-----------+  +----------+
              |              |              |
              +--------------+--------------+
                             |
                    +--------+---------+
                    |   S3 Artifacts   |
                    |   Secrets Mgr    |
                    +------------------+
```

**Stacks deployed:**
- **Network** - VPC, subnets, security groups
- **Storage** - S3 bucket, IAM roles for workers
- **Workers** - Auto Scaling Group with Docker containers running Claude CLI
- **Proxy** - Nginx reverse proxy with web dashboard

## Quickstart

### Prerequisites

- AWS CLI configured with appropriate permissions
- An Anthropic API key
- (Optional) Docker for local image builds
- (Optional) An EC2 key pair for SSH access

### 1. Configure

```bash
cp fleet-config.sh fleet-config.local.sh  # optional: keep defaults separate
vi fleet-config.sh
```

At minimum, set these:

```bash
FLEET_NAME="my-team-fleet"
CLAUDE_API_KEY="sk-ant-..."
SSH_KEY_NAME="my-keypair"        # optional, for SSH access
GITHUB_TOKEN="ghp_..."           # optional, for private repos
GITHUB_REPO="myorg/myrepo"      # optional
```

All other values have smart defaults (auto-detect region, auto-detect IP, spot instances enabled).

### 2. Deploy

```bash
chmod +x deploy.sh status.sh submit.sh teardown.sh
./deploy.sh
```

Takes ~10 minutes. Deploys 4 CloudFormation stacks, stores secrets, uploads Docker assets, and prints the dashboard URL when ready.

Use `./deploy.sh --dry-run` to see what would happen without creating resources.

### 3. Submit Tasks

```bash
# Single task
./submit.sh "Fix the login bug in auth.py"

# Task in repo context
./submit.sh --repo "Add unit tests for utils.py"

# Batch from file
./submit.sh --file tasks.txt

# Check task status
./submit.sh --status task-1234567890-abc123

# List all tasks
./submit.sh --list
```

### 4. Monitor

```bash
# Terminal status
./status.sh

# Web dashboard
open http://<proxy-ip>
```

### 5. Tear Down

```bash
./teardown.sh              # interactive confirmation
./teardown.sh --force      # skip confirmation
./teardown.sh --keep-bucket  # preserve S3 data
```

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_NAME` | `ccc-fleet` | Prefix for all AWS resources |
| `AWS_PROFILE` | (default) | AWS CLI profile |
| `AWS_REGION` | auto-detect | AWS region |
| `WORKER_COUNT` | `2` | Number of worker instances |
| `WORKER_INSTANCE_TYPE` | `m5.xlarge` | Worker EC2 instance type |
| `USE_SPOT` | `true` | Use spot instances for workers |
| `SPOT_MAX_PRICE` | (on-demand cap) | Max hourly spot price |
| `PROXY_INSTANCE_TYPE` | `t3.medium` | Proxy EC2 instance type |
| `ADMIN_IP` | auto-detect | CIDR for SSH access |
| `VPC_CIDR` | `10.0.0.0/16` | VPC network range |
| `SSH_KEY_NAME` | (none) | EC2 key pair for SSH |
| `CLAUDE_API_KEY` | **required** | Anthropic API key |
| `GITHUB_TOKEN` | (none) | GitHub PAT for private repos |
| `GITHUB_REPO` | (none) | Repo to clone (org/repo) |
| `S3_BUCKET` | auto-generated | Artifact bucket name |
| `DOCKER_REGISTRY` | (local build) | ECR URI for pre-built images |

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Fleet health status |
| `/api/submit` | POST | Submit a task (`{"prompt": "..."}`) |
| `/api/status` | GET | List all tasks |
| `/api/status/:id` | GET | Get task status by ID |

## Security Notes

- Worker security group only allows port 8080 from the proxy
- SSH is restricted to `ADMIN_IP`
- Secrets (API keys, tokens) are stored in AWS Secrets Manager
- Workers access secrets via IAM instance profile (no keys on disk)
- S3 bucket has server-side encryption enabled

## Customization

### Using a Pre-built Docker Image

Set `DOCKER_REGISTRY` to your ECR URI. Workers will pull instead of building locally:

```bash
DOCKER_REGISTRY="123456789.dkr.ecr.us-east-1.amazonaws.com/ccc-worker"
```

### Scaling

Change `WORKER_COUNT` in config and re-run `./deploy.sh` -- the ASG updates in place.

### Custom Worker Software

Edit `Dockerfile` and `entrypoint.sh` to add tools, languages, or MCP servers to worker containers.
