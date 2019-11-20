param(
  [Parameter(Position=0, Mandatory = $true, HelpMessage = "Enter SHM ID (usually a string e.g enter 'testa' for Turing Development Safe Haven A)")]
  [string]$shmId
)

Import-Module Az
Import-Module $PSScriptRoot/../../common_powershell/Security.psm1 -Force
Import-Module $PSScriptRoot/../../common_powershell/Configuration.psm1 -Force
Import-Module $PSScriptRoot/../../common_powershell/GenerateSasToken.psm1 -Force


# Get SHM config
# --------------
$config = Get-ShmFullConfig($shmId)


# Temporarily switch to SHM subscription
# --------------------------------------
$prevContext = Get-AzContext
Set-AzContext -SubscriptionId $config.subscriptionName;


# Fetch usernames/passwords from the keyvault
# -------------------------------------------
# Fetch DC/NPS admin username
$dcNpsAdminUsername = EnsureKeyvaultSecret -keyvaultName $config.keyVault.name -secretName $config.keyVault.secretNames.dcNpsAdminUsername -defaultValue "shm$($config.id)admin".ToLower()

# Fetch DC/NPS admin password
$dcNpsAdminPassword = EnsureKeyvaultSecret -keyvaultName $config.keyVault.name -secretName $config.keyVault.secretNames.dcNpsAdminPassword

# Fetch DC safe mode password
$dcSafemodePassword = EnsureKeyvaultSecret -keyvaultName $config.keyVault.name -secretName $config.keyVault.secretNames.dcSafemodePassword


# Generate or create certificates
# -------------------------------
# Attempt to fetch certificates
$vpnClientCertificate = (Get-AzKeyVaultCertificate -VaultName $config.keyVault.name -Name $config.keyVault.secretNames.vpnClientCertificate).Certificate
$vpnCaCertificate = (Get-AzKeyVaultCertificate -vaultName $config.keyVault.name -name $config.keyVault.secretNames.vpnCaCertificate).Certificate
$vpnCaCertificatePlain = (Get-AzKeyVaultSecret -vaultName $config.keyVault.name -name $config.keyVault.secretNames.vpnCaCertificatePlain).SecretValueText

# Define cert folder outside of conditional cert creation to ensure cleanup on next run if code exits with error during cert creation
$certFolderPathName = "certs"
$certFolderPath = "$PSScriptRoot/$certFolderPathName"

if($vpnClientCertificate -And $vpnCaCertificate -And $vpnCaCertificatePlain){
  Write-Host "Both CA and Client certificates already exist in KeyVault. Skipping certificate creation."
} else {
  # Generate certificates
  Write-Host "===Started creating certificates==="
  # Fetch VPN Client certificate password (or create if not present)
  $vpnClientCertPassword = (Get-AzKeyVaultSecret -vaultName $config.keyVault.name -name $config.keyVault.secretNames.vpnClientCertPassword).SecretValueText;
  if ($null -eq $vpnClientCertPassword) {
    # Create password locally but round trip via KeyVault to ensure it is successfully stored
    $secretValue = New-Password;
    $secretValue = (ConvertTo-SecureString $secretValue -AsPlainText -Force);
    $_ = Set-AzKeyVaultSecret -VaultName $config.keyVault.name -Name  $config.keyVault.secretNames.vpnClientCertPassword -SecretValue $secretValue;
    $vpnClientCertPassword  = (Get-AzKeyVaultSecret -VaultName $config.keyVault.name -Name $config.keyVault.secretNames.vpnClientCertPassword ).SecretValueText
  }
  # Fetch VPN CA certificate password (or create if not present)
  $vpnCaCertPassword = (Get-AzKeyVaultSecret -vaultName $config.keyVault.name -name $config.keyVault.secretNames.vpnCaCertPassword).SecretValueText;
  if ($null -eq $vpnCaCertPassword) {
    # Create password locally but round trip via KeyVault to ensure it is successfully stored
    $secretValue = New-Password;
    $secretValue = (ConvertTo-SecureString $secretValue -AsPlainText -Force);
    $_ = Set-AzKeyVaultSecret -VaultName $config.keyVault.name -Name  $config.keyVault.secretNames.vpnCaCertPassword -SecretValue $secretValue;
    $vpnCaCertPassword  = (Get-AzKeyVaultSecret -VaultName $config.keyVault.name -Name $config.keyVault.secretNames.vpnCaCertPassword ).SecretValueText
  }

  # Generate keys and certificates
  $caValidityDays = 2196 # 5 years
  $clientValidityDays = 732 # 2 years
  $_ = new-item -Path $PSScriptRoot -Name $certFolderPathName -ItemType directory -Force
  $caStem = "SHM-P2S-$($config.id)-CA"
  $clientStem = "SHM-P2S-$($config.id)-Client"
  # Create self-signed CA certificate
  openssl req -subj "/CN=$caStem" -new -newkey rsa:2048 -sha256 -days $caValidityDays -nodes -x509 -keyout $certFolderPath/$caStem.key -out $certFolderPath/$caStem.crt
  # Create Client key
  openssl genrsa -out $certFolderPath/$clientStem.key 2048
  # Create Client CSR
  openssl req -new -sha256 -key $certFolderPath/$clientStem.key -subj "/CN=$clientStem" -out $certFolderPath/$clientStem.csr
  # Sign Client cert
  openssl x509 -req -in $certFolderPath/$clientStem.csr -CA $certFolderPath/$caStem.crt -CAkey $certFolderPath/$caStem.key -CAcreateserial -out $certFolderPath/$clientStem.crt -days $clientValidityDays -sha256
  # Create Client private key + signed cert bundle
  openssl pkcs12 -in "$certFolderPath/$clientStem.crt" -inkey "$certFolderPath/$clientStem.key" -certfile $certFolderPath/$caStem.crt -export -out "$certFolderPath/$clientStem.pfx" -password "pass:$vpnClientCertPassword"
  # Create CA private key + signed cert bundle
  openssl pkcs12 -in "$certFolderPath/$caStem.crt" -inkey "$certFolderPath/$caStem.key" -export -out "$certFolderPath/$caStem.pfx" -password "pass:$vpnCaCertPassword"
  Write-Host "===Completed creating certificates==="

  # The certificate only seems to work for the VNET Gateway if the first and last line are removed and it is passed as a single string with white space removed
  $vpnCaCertificatePlain = $(Get-Content -Path "$certFolderPath/$caStem.crt") | Select-Object -Skip 1 | Select-Object -SkipLast 1
  $vpnCaCertificatePlain = [string]$vpnCaCertificatePlain
  $vpnCaCertificatePlain = $vpnCaCertificatePlain.replace(" ", "")

  # Store CA cert in KeyVault
  Write-Host "Storing CA cert in '$($config.keyVault.name)' KeyVault as secret $($config.keyVault.secretNames.vpnCaCertificatePlain) (no private key)"
  $_ = Set-AzKeyVaultSecret -VaultName $config.keyVault.name -Name $config.keyVault.secretNames.vpnCaCertificatePlain -SecretValue (ConvertTo-SecureString $vpnCaCertificatePlain -AsPlainText -Force);
  $vpnCaCertificatePlain = (Get-AzKeyVaultSecret -VaultName $config.keyVault.name -Name $config.keyVault.secretNames.vpnCaCertificatePlain ).SecretValueText;

  # Store CA key + cert bundle in KeyVault
  Write-Host "Storing CA private key + cert bundle in '$($config.keyVault.name)' KeyVault as certificate $($config.keyVault.secretNames.vpnCaCertificate) (includes private key)"
  $_ = Import-AzKeyVaultCertificate -VaultName $config.keyVault.name -Name $config.keyvault.secretNames.vpnCaCertificate -FilePath "$certFolderPath/$caStem.pfx" -Password (ConvertTo-SecureString $vpnCaCertPassword -AsPlainText -Force);

  # Store Client key + cert bundle in KeyVault
  Write-Host "Storing Client private key + cert bundle in '$($config.keyVault.name)' KeyVault as certificate $($config.keyVault.secretNames.vpnClientCertificate) (includes private key)"
  $_ = Import-AzKeyVaultCertificate -VaultName $config.keyVault.name -Name $config.keyvault.secretNames.vpnClientCertificate -FilePath "$certFolderPath/$clientStem.pfx" -Password (ConvertTo-SecureString $vpnClientCertPassword -AsPlainText -Force);

}
# Delete local copies of certificates and private keys
Get-ChildItem $certFolderPath -Recurse | Remove-Item -Recurse


# Setup storage account and upload artifacts
# ------------------------------------------
$storageAccountRg = $config.storage.artifacts.rg;
$storageAccountName = $config.storage.artifacts.accountName;
$storageAccountLocation = $config.location;
New-AzResourceGroup -Name $storageAccountRg -Location $storageAccountLocation -Force
$storageAccount = Get-AzStorageAccount -Name $storageAccountName -ResourceGroupName $storageAccountRg -ErrorVariable notExists -ErrorAction SilentlyContinue
if ($notExists) {
  Write-Host " - Creating storage account '$storageAccountName'"
  $storageAccount = New-AzStorageAccount -Name $storageAccountName -ResourceGroupName $storageAccountRg -Location $storageAccountLocation -SkuName "Standard_LRS" -Kind "StorageV2"
}
# Create blob storage containers
ForEach ($containerName in ("armdsc", "dcconfiguration", "rds-sh-packages", "rds-gateway-scripts")) {
  if(-not (Get-AzStorageContainer -Context $storageAccount.Context | Where-Object { $_.Name -eq "$containerName" })){
    Write-Host " - Creating container '$containerName' in storage account '$storageAccountName'"
    New-AzStorageContainer -Name $containerName -Context $storageAccount.Context;
  }
}
# Create file storage shares
ForEach ($shareName in ("sqlserver")) {
  if(-not (Get-AzStorageShare -Context $storageAccount.Context | Where-Object { $_.Name -eq "$shareName" })){
    Write-Host " - Creating share '$shareName' in storage account '$storageAccountName'"
    New-AzStorageShare -Name $shareName -Context $storageAccount.Context;
  }
}

# Upload scripts
Write-Host " - Uploading DSC files to storage account '$storageAccountName'"
Set-AzStorageBlobContent -Container "armdsc" -Context $storageAccount.Context -File "$PSScriptRoot/../arm_templates/shmdc/dscdc1/CreateADPDC.zip" -Force
Set-AzStorageBlobContent -Container "armdsc" -Context $storageAccount.Context -File "$PSScriptRoot/../arm_templates/shmdc/dscdc2/CreateADBDC.zip" -Force

# Artifacts for configuring the DC
Write-Host " - Uploading DC configuration files to storage account '$storageAccountName'"
Set-AzStorageBlobContent -Container "dcconfiguration" -Context $storageAccount.Context -File "$PSScriptRoot/../scripts/shmdc/artifacts/GPOs.zip" -Force
Set-AzStorageBlobContent -Container "dcconfiguration" -Context $storageAccount.Context -File "$PSScriptRoot/../scripts/shmdc/artifacts/Run_ADSync.ps1" -Force

Write-Host " - Uploading SQL server installation files to storage account '$storageAccountName'"
# URI to Azure File copy does not support 302 redirect, so get the latest working endpoint redirected from "https://go.microsoft.com/fwlink/?linkid=853017"
Start-AzStorageFileCopy -AbsoluteUri "https://download.microsoft.com/download/5/E/9/5E9B18CC-8FD5-467E-B5BF-BADE39C51F73/SQLServer2017-SSEI-Expr.exe" -DestShareName "sqlserver" -DestFilePath "SQLServer2017-SSEI-Expr.exe" -DestContext $storageAccount.Context -Force
# URI to Azure File copy does not support 302 redirect, so get the latest working endpoint redirected from "https://go.microsoft.com/fwlink/?linkid=2088649"
Start-AzStorageFileCopy -AbsoluteUri "https://download.microsoft.com/download/5/4/E/54EC1AD8-042C-4CA3-85AB-BA307CF73710/SSMS-Setup-ENU.exe" -DestShareName "sqlserver" -DestFilePath "SSMS-Setup-ENU.exe" -DestContext $storageAccount.Context -Force


# Deploy VNet from template
# -------------------------
$vnetCreateParams = @{
  "Virtual_Network_Name" = $config.network.vnet.name
  "P2S_VPN_Certificate" = $vpnCaCertificatePlain
  "VNET_CIDR" = $config.network.vnet.cidr
  "Subnet_Identity_Name" = $config.network.subnets.identity.name
  "Subnet_Identity_CIDR" = $config.network.subnets.identity.cidr
  "Subnet_Web_Name" = $config.network.subnets.web.name
  "Subnet_Web_CIDR" = $config.network.subnets.web.cidr
  "Subnet_Gateway_Name" = $config.network.subnets.gateway.name
  "Subnet_Gateway_CIDR" = $config.network.subnets.gateway.cidr
  "VNET_DNS1" = $config.dc.ip
  "VNET_DNS2" = $config.dcb.ip
}
New-AzResourceGroup -Name $config.network.vnet.rg -Location $config.location -Force
New-AzResourceGroupDeployment -resourcegroupname $config.network.vnet.rg `
                              -templatefile "$PSScriptRoot/../arm_templates/shmvnet/shmvnet-template.json" `
                              @vnetCreateParams -Verbose;


# Deploy SHM-DC from template
# ---------------------------
# Get SAS token
$artifactLocation = "https://" + $config.storage.artifacts.accountName + ".blob.core.windows.net";
$artifactSasToken = (New-AccountSasToken -subscriptionName $config.subscriptionName -resourceGroup $config.storage.artifacts.rg `
  -accountName $config.storage.artifacts.accountName -service Blob,File -resourceType Service,Container,Object `
  -permission "rl" -validityHours 2);
# Check NetBios name
$netbiosNameMaxLength = 15
if($config.domain.netbiosName.length -gt $netbiosNameMaxLength) {
    throw "Netbios name must be no more than 15 characters long. '$($config.domain.netbiosName)' is $($config.domain.netbiosName.length) characters long."
}
New-AzResourceGroup -Name $config.dc.rg  -Location $config.location -Force
New-AzResourceGroupDeployment -resourcegroupname $config.dc.rg `
        -templatefile "$PSScriptRoot/../arm_templates/shmdc/shmdc-template.json"`
        -Administrator_User $dcNpsAdminUsername `
        -Administrator_Password (ConvertTo-SecureString $dcNpsAdminPassword -AsPlainText -Force)`
        -SafeMode_Password (ConvertTo-SecureString $dcSafemodePassword -AsPlainText -Force)`
        -Virtual_Network_Resource_Group $config.network.vnet.rg `
        -Artifacts_Location $artifactLocation `
        -Artifacts_Location_SAS_Token (ConvertTo-SecureString $artifactSasToken -AsPlainText -Force)`
        -Domain_Name $config.domain.fqdn `
        -Domain_Name_NetBIOS_Name $config.domain.netbiosName `
        -VM_Size $config.dc.vmSize `
        -Virtual_Network_Name $config.network.vnet.name `
        -Virtual_Network_Subnet $config.network.subnets.identity.name `
        -Shm_Id "$($config.id)".ToLower() `
        -DC1_VM_Name $config.dc.vmName `
        -DC2_VM_Name $config.dcb.vmName `
        -DC1_Host_Name $config.dc.hostname `
        -DC2_Host_Name $config.dcb.hostname `
        -DC1_IP_Address $config.dc.ip `
        -DC2_IP_Address $config.dcb.ip `
        -Verbose;


# Import artifacts from blob storage
# ----------------------------------
Write-Host "Importing configuration artifacts for: $($config.dc.vmName)..."

# Get list of blobs in the storage account
# $storageAccount = Get-AzStorageAccount -Name $config.storage.artifacts.accountName -ResourceGroupName $config.storage.artifacts.rg -ErrorVariable notExists -ErrorAction SilentlyContinue
$storageContainerName = "dcconfiguration"
$blobNames = Get-AzStorageBlob -Container $storageContainerName -Context $storageAccount.Context | ForEach-Object{$_.Name}
$artifactSasToken = New-ReadOnlyAccountSasToken -subscriptionName $config.subscriptionName -resourceGroup $config.storage.artifacts.rg -accountName $config.storage.artifacts.accountName;

# Run import script remotely
$scriptPath = Join-Path $PSScriptRoot ".." "scripts" "shmdc" "remote" "Import_Artifacts.ps1" -Resolve
$params = @{
  remoteDir = "`"C:\Installation`""
  pipeSeparatedBlobNames = "`"$($blobNames -join "|")`""
  storageAccountName = "`"$($config.storage.artifacts.accountName)`""
  storageContainerName = "`"$storageContainerName`""
  sasToken = "`"$artifactSasToken`""
}
$result = Invoke-AzVMRunCommand -Name $config.dc.vmName -ResourceGroupName $config.dc.rg `
                                -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $params;
Write-Output $result.Value;


# Configure Active Directory remotely
# -----------------------------------
Write-Host "Configuring Active Directory for: $($config.dc.vmName)..."

# Fetch ADSync user password
$adsyncPassword = EnsureKeyvaultSecret -keyvaultName $config.keyVault.name -secretName $config.keyVault.secretNames.adsyncPassword
$adsyncAccountPasswordEncrypted = ConvertTo-SecureString $adsyncPassword -AsPlainText -Force | ConvertFrom-SecureString -Key (1..16)

# # Fetch DC/NPS admin username
# $dcNpsAdminUsername = EnsureKeyvaultSecret -keyvaultName $config.keyVault.name -secretName $config.keyVault.secretNames.dcNpsAdminUsername -defaultValue "shm$($config.id)admin".ToLower()

# Run configuration script remotely
$scriptPath = Join-Path $PSScriptRoot ".." "scripts" "shmdc" "remote" "Active_Directory_Configuration.ps1"
$params = @{
  oubackuppath = "`"C:\Installation\GPOs`""
  domainou = "`"$($config.domain.dn)`""
  domain = "`"$($config.domain.fqdn)`""
  identitySubnetCidr = "`"$($config.network.subnets.identity.cidr)`""
  webSubnetCidr = "`"$($config.network.subnets.web.cidr)`""
  serverName = "`"$($config.dc.vmName)`""
  serverAdminName = "`"$dcNpsAdminUsername`""
  adsyncAccountPasswordEncrypted = "`"$adsyncAccountPasswordEncrypted`""
}
$result = Invoke-AzVMRunCommand -Name $config.dc.vmName -ResourceGroupName $config.dc.rg `
                                -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $params;
Write-Output $result.Value;


# Set the OS language to en-GB remotely
# -------------------------------------
$scriptPath = Join-Path $PSScriptRoot ".." "scripts" "shmdc" "remote" "Set_OS_Language.ps1"
# Run on the primary DC
Write-Host "Setting OS language for: $($config.dc.vmName)..."
$result = Invoke-AzVMRunCommand -Name $config.dc.vmName -ResourceGroupName $config.dc.rg `
                                -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath;
Write-Output $result.Value;
# Run on the secondary DC
Write-Host "Setting OS language for: $($config.dcb.vmName)..."
$result = Invoke-AzVMRunCommand -Name $config.dcb.vmName -ResourceGroupName $config.dc.rg `
                                -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath;
Write-Output $result.Value;


# Configure group policies
# ------------------------
Write-Host "Configuring group policies for: $($config.dc.vmName)..."
$scriptPath = Join-Path $PSScriptRoot ".." "scripts" "shmdc" "remote" "Configure_Group_Policies.ps1"
$result = Invoke-AzVMRunCommand -Name $config.dc.vmName -ResourceGroupName $config.dc.rg `
                                -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath;
Write-Output $result.Value;


# Active directory delegation
# ---------------------------
Write-Host "Enabling Active Directory delegation: $($config.dc.vmName)..."
$scriptPath = Join-Path $PSScriptRoot ".." "scripts" "shmdc" "remote" "Active_Directory_Delegation.ps1"
$params = @{
  netbiosName = "`"$($config.domain.netbiosName)`""
  ldapUsersGroup = "`"$($config.domain.securityGroups.dsvmLdapUsers.name)`""
}
$result = Invoke-AzVMRunCommand -Name $config.dc.vmName -ResourceGroupName $config.dc.rg `
                                -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath -Parameter $params;
Write-Output $result.Value;


# Switch back to original subscription
# ------------------------------------
Set-AzContext -Context $prevContext;
