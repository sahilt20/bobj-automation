# Troubleshooting Guide

## Common Issues

### Authentication Failures

**Symptom:** "Authentication failed" or "Invalid credentials"

**Solutions:**
1. Verify credentials in Key Vault are correct
2. Check auth type matches BOBJ configuration (`secEnterprise`, `secLDAP`, etc.)
3. Ensure service account is not locked
4. Verify CMS port (default 6400) is accessible

```powershell
# Test connection
./scripts/powershell/Get-BOBJConnection.ps1 -ServerUrl "http://bobj:8080" -CmsServer "bobj-cms" -Username "user" -Password "pass"
```

### Network Connectivity

**Symptom:** "Connection timed out" or "Unable to connect to remote server"

**Solutions:**
1. Verify agent has network access to BOBJ servers
2. Check firewall rules allow:
   - Port 8080 (Web App Server)
   - Port 6400 (CMS)
3. Test from agent machine:
   ```bash
   curl -v http://bobj-server:8080/biprws
   telnet bobj-cms 6400
   ```

### LCMBIAR Export Failures

**Symptom:** "Promotion job failed" or empty LCMBIAR

**Solutions:**
1. Check source folder exists and contains objects
2. Verify service account has export permissions
3. Check BOBJ server logs for errors
4. Ensure sufficient disk space on BOBJ server

### Import Conflicts

**Symptom:** "Object already exists" errors

**Solutions:**
1. Use appropriate conflict resolution:
   - `UpdateExisting` - Overwrite existing
   - `SkipExisting` - Keep existing versions
   - `RenameNew` - Rename incoming objects
2. Check target folder permissions
3. Review object dependencies

### Pipeline Timeout

**Symptom:** Pipeline stage times out

**Solutions:**
1. Increase timeout in stage template
2. Check for long-running BOBJ jobs
3. Reduce export scope if too large
4. Verify agent is responding

### Key Vault Access

**Symptom:** "Access denied" to Key Vault

**Solutions:**
1. Verify service connection has Key Vault access
2. Check Key Vault access policies
3. Ensure subscription permissions are correct:
   ```bash
   az keyvault set-policy --name kv-bobj-dev \
     --spn <service-principal-id> \
     --secret-permissions get list
   ```

### Approval Issues

**Symptom:** Deployment stuck waiting for approval

**Solutions:**
1. Check environment approvers are correctly configured
2. Verify approvers received notification
3. Review approval timeout settings
4. Check Teams/Email notifications are working

## Logging

### Enable Verbose Logging

In pipeline YAML:
```yaml
variables:
  verboseLogging: true
  System.Debug: true
```

In PowerShell:
```powershell
./Export-BOBJContent.ps1 -VerboseLogging
```

### Check Azure DevOps Logs

1. Go to failed pipeline run
2. Click on failed stage/job
3. Expand task logs
4. Download full logs if needed

### BOBJ Server Logs

Check logs on BOBJ server:
- Windows: `C:\Program Files (x86)\SAP BusinessObjects\SAP BusinessObjects Enterprise XI 4.0\logging`
- Linux: `/opt/sap/bobj/logging`

## Getting Help

1. Check this troubleshooting guide
2. Review [SAP BOBJ documentation](https://help.sap.com/viewer/product/SAP_BUSINESSOBJECTS_BUSINESS_INTELLIGENCE_PLATFORM)
3. Search [SAP Community](https://community.sap.com/)
4. Create a GitHub issue with:
   - Error message
   - Pipeline logs
   - Environment details
