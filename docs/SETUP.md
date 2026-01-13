# Setup Guide

This guide walks you through setting up the BOBJ Transport CI/CD framework.

## Prerequisites

### Azure DevOps

- Azure DevOps organization with project
- Permission to create pipelines and environments
- Service principal with Azure subscription access

### Self-Hosted Agents

Agents must have:
- Network connectivity to BOBJ servers
- PowerShell 7.0+
- Python 3.8+
- Java JDK 11+ (for BOBJ SDK if using Java API)

### SAP BusinessObjects

- BI Platform 4.2 SP5+ (or 4.3)
- REST API enabled on Web Application Server
- Service account with promotion management rights

## Step 1: Azure Key Vault Setup

Create Key Vaults for each environment:

```bash
# Create Key Vaults
az keyvault create --name kv-bobj-dev --resource-group rg-bobj --location eastus
az keyvault create --name kv-bobj-qa --resource-group rg-bobj --location eastus
az keyvault create --name kv-bobj-prod --resource-group rg-bobj --location eastus

# Add secrets
az keyvault secret set --vault-name kv-bobj-dev --name bobj-username --value "BOBJServiceAccount"
az keyvault secret set --vault-name kv-bobj-dev --name bobj-password --value "YourSecurePassword"

# (Repeat for qa and prod)
```

## Step 2: Configure Environments

Edit `config/environments/*.json` files with your BOBJ server details.

### Key Settings

| Setting | Description |
|---------|-------------|
| `server.url` | BOBJ Web Application Server URL |
| `server.cms.host` | CMS Server hostname |
| `authentication.keyVault` | Key Vault name for this environment |
| `agentPool` | Azure DevOps agent pool name |

## Step 3: Azure DevOps Setup

### Create Service Connections

1. Go to Project Settings → Service Connections
2. Create Azure Resource Manager connection for each environment
3. Grant access to corresponding Key Vault

### Create Environments

1. Go to Pipelines → Environments
2. Create environments:
   - `bobj-dev` (no approvals)
   - `bobj-qa` (add approval checks)
   - `bobj-prod` (add multi-reviewer approval)

### Create Variable Groups

1. Go to Pipelines → Library
2. Create variable group `bobj-common`:
   - `teamsWebhookUrl` (linked to Key Vault if needed)

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
