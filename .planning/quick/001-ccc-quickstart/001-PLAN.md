# CCC Fleet Quickstart Kit

## Goal
Build a one-click deployment kit for Claude Code Computer (CCC) fleets on AWS. Other teams edit one config file, run one command, and get a working fleet.

## Success Criteria
1. fleet-config.sh - bash-sourceable config with all customizable values and smart defaults
2. CloudFormation templates in cloudformation/ for network, storage, workers, nginx proxy - parameterized with FleetName
3. Dockerfile + entrypoint.sh for worker containers
4. deploy.sh - reads config, validates prereqs, deploys stacks, stores secrets, waits for readiness, prints dashboard URL
5. status.sh - colored fleet health output
6. submit.sh - submit tasks to fleet API
7. teardown.sh - clean removal of all stacks
8. README.md with quickstart guide
9. Edit one file, run one command, get a working fleet
