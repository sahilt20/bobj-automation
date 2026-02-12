# Setup Guide

This guide walks you through setting up the BOBJ Transport CI/CD framework.

## Prerequisites

### Azure DevOps

- Azure DevOps organization with project
- Permission to create pipelines and environments

### Self-Hosted Agents

Agents must have:
- Network connectivity to BOBJ servers
- PowerShell 7.0+
- LCMCLI tool installed (SAP BI Client Tools)

### SAP BusinessObjects

- BI Platform 2025 (or 4.2 SP5+)
- REST API enabled on Web Application Server (for connectivity tests)
- Service account with promotion management rights
- LCMCLI tool available on agent machines

## Step 1: Create Variable Groups

Create Variable Groups in Azure DevOps for each environment to store credentials:

1. Go to **Pipelines → Library → Variable Groups**
2. Create the following groups:

| Variable Group    | Variables                                   |
| ----------------- | ------------------------------------------- |
| `bobj-creds-dev`  | `bobj-username`, `bobj-password` (🔒 secret) |
| `bobj-creds-qa`   | `bobj-username`, `bobj-password` (🔒 secret) |
| `bobj-creds-prod` | `bobj-username`, `bobj-password` (🔒 secret) |

> **Important:** Mark `bobj-password` as a **secret variable** in each group.

## Step 2: Configure Environments

Edit `config/environments/*.json` files with your BOBJ server details.

### Key Settings

| Setting                        | Description                                 |
| ------------------------------ | ------------------------------------------- |
| `server.url`                   | BOBJ Web Application Server URL (port 8080) |
| `server.cms.host`              | CMS Server hostname                         |
| `authentication.variableGroup` | Variable Group name for this environment    |
| `agentPool`                    | Azure DevOps agent pool name                |

## Step 3: Azure DevOps Setup

### Create Environments

1. Go to Pipelines → Environments
2. Create environments:
   - `bobj-dev` (no approvals)
   - `bobj-qa` (add approval checks)
   - `bobj-prod` (add multi-reviewer approval)

### Import Pipelines

1. Go to Pipelines → Create Pipeline
2. Select your repository
3. Choose "Existing Azure Pipelines YAML file"
4. Select `azure-pipelines/ci-pipeline.yml`
5. Repeat for `cd-pipeline.yml`

## Step 4: Configure Agent Pools

### Option A: Microsoft-Hosted (Limited)

For validation-only stages, Microsoft-hosted agents work fine.

### Option B: Self-Hosted (Required for BOBJ)

1. Create agent pool in Azure DevOps
2. Install agent on server with BOBJ connectivity
3. Configure agent:
   ```bash
   ./config.sh --url https://dev.azure.com/yourorg --pool BOBJ-Dev-Agents
   ```

## Step 5: Test the Setup

1. **Test Connection**
   ```powershell
   ./scripts/powershell/Get-BOBJConnection.ps1 `
     -ServerUrl "http://your-bobj-server:8080" `
     -CmsServer "your-cms-server" `
     -Username "your-user" `
     -Password "your-pass"
   ```

2. **Run CI Pipeline**
   - Trigger manually or push to main branch
   - Verify export and validation stages complete

3. **Run CD Pipeline**
   - Select Dev environment first
   - Verify deployment succeeds
   - Test QA with approval workflow

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues.
See [LCMCLI_REFERENCE.md](LCMCLI_REFERENCE.md) for LCMCLI command reference.
