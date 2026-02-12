# SAP BusinessObjects Transport CI/CD Framework

[![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-Pipelines-blue)](https://azure.microsoft.com/en-us/services/devops/)
[![SAP BOBJ](https://img.shields.io/badge/SAP-BusinessObjects-orange)](https://www.sap.com/products/bi-platform.html)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A comprehensive CI/CD framework for automating SAP BusinessObjects (BOBJ) content transport across environments using Azure DevOps YAML pipelines.

## 🎯 Features

- **Automated Export** - Export BOBJ content to LCMBIAR archives
- **Validation** - Validate packages before deployment
- **Multi-Environment Deployment** - Deploy to Dev → QA → Production
- **Approval Gates** - Manual approvals for QA and Production
- **Automatic Rollback** - Restore from backup on deployment failure
- **Notifications** - Teams and Email notifications
- **Security Integration** - Azure DevOps Variable Groups for credentials

## 📁 Project Structure

```
bobj-automation/
├── azure-pipelines/
│   ├── ci-pipeline.yml          # CI Pipeline
│   ├── cd-pipeline.yml          # CD Pipeline
│   └── templates/               # Reusable templates
├── scripts/
│   └── powershell/              # PowerShell scripts
├── config/
│   └── environments/            # Environment configs
└── docs/                        # Documentation
```

## 🚀 Quick Start

### Prerequisites

1. **Azure DevOps Organization** with pipelines enabled
2. **Self-hosted agents** with connectivity to BOBJ servers
3. **Azure DevOps Variable Groups** for storing credentials
4. **SAP BusinessObjects BI 2025** with LCMCLI tool available

### Setup Steps

1. **Clone this repository**
   ```bash
   git clone https://github.com/your-org/bobj-automation.git
   ```

2. **Configure environments**
   
   Edit files in `config/environments/` for your BOBJ servers:
   - `dev.json` - Development environment
   - `qa.json` - QA/Staging environment
   - `prod.json` - Production environment

3. **Create Variable Groups** in Azure DevOps
   
   Go to Pipelines → Library → Variable Groups and create:
   - `bobj-creds-dev` with `bobj-username` and `bobj-password` (🔒 secret)
   - `bobj-creds-qa` with `bobj-username` and `bobj-password` (🔒 secret)
   - `bobj-creds-prod` with `bobj-username` and `bobj-password` (🔒 secret)

4. **Create Azure DevOps environments**
   - `bobj-dev` - No approval required
   - `bobj-qa` - Manual approval required
   - `bobj-prod` - Multi-reviewer approval required

5. **Import pipelines**
   - Import `azure-pipelines/ci-pipeline.yml` as CI pipeline
   - Import `azure-pipelines/cd-pipeline.yml` as CD pipeline

## 📋 CI Pipeline

The CI pipeline exports and validates BOBJ content:

| Stage    | Description                                 |
| -------- | ------------------------------------------- |
| Export   | Exports content from source BOBJ to LCMBIAR |
| Validate | Validates package structure and security    |
| Publish  | Publishes artifact for deployment           |

**Trigger:** Push to `main` or `develop` branches

## 🚢 CD Pipeline

The CD pipeline deploys content across environments:

| Stage          | Description           | Approval     |
| -------------- | --------------------- | ------------ |
| Deploy to Dev  | Deploy to Development | Auto         |
| Deploy to QA   | Deploy to QA          | Manual       |
| Deploy to Prod | Deploy to Production  | 2+ Reviewers |

**Features:**
- Pre-deployment backup creation
- Automatic rollback on failure
- Deployment window enforcement (Prod)

## ⚙️ Configuration

### Pipeline Parameters

| Parameter            | Description                 | Default           |
| -------------------- | --------------------------- | ----------------- |
| `sourceEnvironment`  | Source system for export    | `dev`             |
| `exportFolder`       | BOBJ folder to export       | `/Public Folders` |
| `conflictResolution` | How to handle conflicts     | `UpdateExisting`  |
| `createBackup`       | Create backup before deploy | `true`            |
| `enableRollback`     | Auto-rollback on failure    | `true`            |

### Environment Variables

| Variable            | Description                |
| ------------------- | -------------------------- |
| `TEAMS_WEBHOOK_URL` | Teams notification webhook |
| `SMTP_HOST`         | Email SMTP server          |

## 🔧 Scripts

### PowerShell

| Script                        | Purpose           |
| ----------------------------- | ----------------- |
| `Export-BOBJContent.ps1`      | Export to LCMBIAR |
| `Import-BOBJContent.ps1`      | Import LCMBIAR    |
| `Get-BOBJConnection.ps1`      | Test connectivity |
| `Validate-LCMBIARPackage.ps1` | Validate package  |
| `Invoke-BOBJRollback.ps1`     | Execute rollback  |

## 📖 Documentation

- [Setup Guide](docs/SETUP.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

## 🆘 Support

For issues and questions:
- Create a GitHub issue
- Contact your SAP BOBJ administrator
