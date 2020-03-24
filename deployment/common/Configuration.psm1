Import-Module $PSScriptRoot/Security.psm1 -Force

# Get root directory for configuration files
# ------------------------------------------
function Get-ConfigRootDir {
    $configRootDir = Join-Path (Get-Item $PSScriptRoot).Parent.Parent "environment_configs" -Resolve
    return $configRootDir
}

# Get SHM configuration
# ---------------------
function Get-ShmFullConfig {
    param(
        [Parameter(Position = 0,Mandatory = $true,HelpMessage = "Enter SHM ID ('test' or 'prod')")]
        $shmId
    )
    $configRootDir = Get-ConfigRootDir
    $shmCoreConfigFilename = "shm_${shmId}_core_config.json"
    $shmCoreConfigPath = Join-Path $configRootDir "core" $shmCoreConfigFilename -Resolve

    # Import minimal management config parameters from JSON config file - we can derive the rest from these
    $shmConfigBase = Get-Content -Path $shmCoreConfigPath -Raw | ConvertFrom-Json

    # Safe Haven management config
    # ----------------------------
    $shm = [ordered]@{}
    $shmPrefix = $shmConfigBase.ipPrefix

    # Deconstruct VNet address prefix to allow easy construction of IP based parameters
    $shmPrefixOctets = $shmPrefix.Split('.')
    $shmBasePrefix = "$($shmPrefixOctets[0]).$($shmPrefixOctets[1])"
    $shmThirdOctet = ([int]$shmPrefixOctets[2])

    # --- Top-level config ---
    $shm.subscriptionName = $shmConfigBase.subscriptionName
    $shm.computeVmImageSubscriptionName = $shmConfigBase.computeVmImageSubscriptionName
    $shm.computeVmImageResourceGroupName = "RG_SH_IMAGE_GALLERY"
    $shm.computeVmImageImageGalleryName = "SAFE_HAVEN_COMPUTE_IMAGES"

    $shm.id = $shmConfigBase.shmId
    $shm.name = $shmConfigBase.name
    $shm.organisation = $shmConfigBase.organisation
    $shm.location = $shmConfigBase.location
    $shm.adminSecurityGroupName = $shmConfigBase.adminSecurityGroupName

    # --- Domain config ---
    $shm.domain = [ordered]@{}
    $shm.domain.fqdn = $shmConfigBase.domain
    $netbiosNameMaxLength = 15
    if ($shmConfigBase.netbiosName.length -gt $netbiosNameMaxLength) {
        throw "Netbios name must be no more than 15 characters long. '$($shmConfigBase.netbiosName)' is $($shmConfigBase.netbiosName.length) characters long."
    }
    $shm.domain.netbiosName = $shmConfigBase.netbiosName
    $shm.domain.dn = "DC=" + ($shm.domain.fqdn.Replace('.',',DC='))
    $shm.domain.serviceServerOuPath = "OU=Safe Haven Service Servers,$($shm.domain.dn)"
    $shm.domain.serviceOuPath = "OU=Safe Haven Service Accounts,$($shm.domain.dn)"
    $shm.domain.userOuPath = "OU=Safe Haven Research Users,$($shm.domain.dn)"
    $shm.domain.securityOuPath = "OU=Safe Haven Security Groups,$($shm.domain.dn)"
    $ldapUsersGroup = "SG Safe Haven LDAP Users"
    $serverAdminsGroup = "SG Safe Haven Server Administrators"
    $shm.domain.securityGroups = [ordered]@{
        dsvmLdapUsers = [ordered]@{
            name = $ldapUsersGroup
            description = $ldapUsersGroup
        }
        serverAdmins = [ordered]@{
            name = $serverAdminsGroup
            description = $serverAdminsGroup
        }
    }

    # --- Network config ---
    $shm.network = [ordered]@{
        vnet = [ordered]@{
            rg = "RG_SHM_NETWORKING"
            name = "VNET_SHM_$($shm.id)".ToUpper()
            cidr = $shmBasePrefix + "." + $shmThirdOctet + ".0/21"
        }
        subnets = [ordered]@{}
    }
    # --- Identity subnet
    $shm.network.subnets.identity = [ordered]@{}
    $shm.network.subnets.identity.name = "IdentitySubnet" # Name to match required format of GatewaySubnet
    $shm.network.subnets.identity.prefix = $shmBasePrefix + "." + $shmThirdOctet
    $shm.network.subnets.identity.cidr = $shm.network.subnets.identity.prefix + ".0/24"
    # --- Web subnet
    $shm.network.subnets.web = [ordered]@{}
    $shm.network.subnets.web.name = "WebSubnet" # Name to match required format of GatewaySubnet
    $shm.network.subnets.web.prefix = $shmBasePrefix + "." + ([int]$shmThirdOctet + 1)
    $shm.network.subnets.web.cidr = $shm.network.subnets.web.prefix + ".0/24"
    # --- Gateway subnet
    $shm.network.subnets.gateway = [ordered]@{}
    $shm.network.subnets.gateway.name = "GatewaySubnet" # The Gateway subnet MUST be named 'GatewaySubnet' - see https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-vpn-faq#do-i-need-a-gatewaysubnet
    $shm.network.subnets.gateway.prefix = $shmBasePrefix + "." + ([int]$shmThirdOctet + 7)
    $shm.network.subnets.gateway.cidr = $shm.network.subnets.gateway.prefix + ".0/24"


    # --- Domain controller config ---
    $shm.dc = [ordered]@{}
    $shm.dc.rg = "RG_SHM_DC"
    $shm.dc.vmName = "DC1-SHM-$($shm.id)".ToUpper()
    $shm.dc.vmSize = "Standard_D2s_v3"
    $shm.dc.hostname = $shm.dc.vmName
    $shm.dc.fqdn = $shm.dc.hostname + "." + $shm.domain.fqdn
    $shm.dc.ip = $shm.network.subnets.identity.prefix + ".250"

    # Backup AD DC details
    $shm.dcb = [ordered]@{}
    $shm.dcb.vmName = "DC2-SHM-$($shm.id)".ToUpper()
    $shm.dcb.hostname = $shm.dcb.vmName
    $shm.dcb.fqdn = $shm.dcb.hostname + "." + $shm.domain.fqdn
    $shm.dcb.ip = $shm.network.subnets.identity.prefix + ".249"

    # --- NPS config ---
    $shm.nps = [ordered]@{}
    $shm.nps.rg = "RG_SHM_NPS"
    $shm.nps.vmName = "NPS-SHM-$($shm.id)".ToUpper()
    $shm.nps.vmSize = "Standard_D2s_v3"
    $shm.nps.hostname = $shm.nps.vmName
    $shm.nps.ip = $shm.network.subnets.identity.prefix + ".248"

    # --- Storage config --
    $storageRg = "RG_SHM_ARTIFACTS"
    $storageSuffix = New-RandomLetters -SeedPhrase $shm.subscriptionName
    $shm.storage = [ordered]@{
        artifacts = [ordered]@{
            rg = $storageRg
            accountName = "shm$($shm.id)artifacts${storageSuffix}".ToLower() | TrimToLength 24
        }
        bootdiagnostics = [ordered]@{
            rg = $storageRg
            accountName = "shm$($shm.id)bootdiags${storageSuffix}".ToLower() | TrimToLength 24
        }
    }

    # --- Secrets config ---
    $shm.keyVault = [ordered]@{
        rg = "RG_SHM_SECRETS"
        name = "kv-shm-" + "$($shm.id)".ToLower()
    }
    $shm.keyVault.secretNames = [ordered]@{
        aadAdminPassword = "shm-$($shm.id)-aad-admin-password".ToLower()
        dcSafemodePassword = "shm-$($shm.id)-dc-safemode-password".ToLower()
        domainAdminPassword = "shm-$($shm.id)-domain-admin-password".ToLower()
        localAdsyncPassword = "shm-$($shm.id)-localadsync-password".ToLower()
        npsAdminPassword = "shm-$($shm.id)-nps-admin-password".ToLower()
        testAdUserPassword = "shm-$($shm.id)-testaduser-password".ToLower()
        vmAdminUsername = "shm-$($shm.id)-vm-admin-username".ToLower()
        vpnCaCertificate = "shm-$($shm.id)-vpn-ca-cert".ToLower()
        vpnCaCertificatePlain = "shm-$($shm.id)-vpn-ca-cert-plain".ToLower()
        vpnCaCertPassword = "shm-$($shm.id)-vpn-ca-cert-password".ToLower()
        vpnClientCertificate = "shm-$($shm.id)-vpn-client-cert".ToLower()
        vpnClientCertPassword = "shm-$($shm.id)-vpn-client-cert-password".ToLower()
    }

    # --- DNS config ---
    $rgSuffix = ""
    if ($shm.adminSecurityGroupName -like "*Production*") {
        $rgSuffix = "_PRODUCTION"
    } elseif ($shm.adminSecurityGroupName -like "*Test*") {
        $rgSuffix = "_TEST"
    }
    $shm.dns = [ordered]@{
        subscriptionName = $shmConfigBase.domainSubscriptionName
        rg = "RG_SHM_DNS" + $rgSuffix
    }

    # --- Package mirror config ---
    # Please note that each mirror type must have a distinct ipOffset in the range 4-15
    $shm.mirrors = [ordered]@{
        rg = "RG_SHM_PKG_MIRRORS"
        vmSize = "Standard_D2s_v3"
        diskType = "Standard_LRS"
        pypi = [ordered]@{
            ipOffset = 4
            diskSize = [ordered]@{
                tier2 = 16384
                tier3 = 512
            }
        }
        cran = [ordered]@{
            ipOffset = 5
            diskSize = [ordered]@{
                tier2 = 512
                tier3 = 256
            }
        }
    }

    return $shm
}
Export-ModuleMember -Function Get-ShmFullConfig


function TrimToLength {
    param(
        [Parameter(Mandatory = $True,ValueFromPipeline = $True)]
        [string]$str,
        [Parameter(Mandatory = $True,Position = 1)]
        [int]$length
    )
    return $str[0..($length - 1)] -join ""
}
Export-ModuleMember -Function TrimToLength


# Add a new SRE configuration
# ---------------------------
function Add-SreConfig {
    param(
        [Parameter(Position = 0,Mandatory = $true,HelpMessage = "Enter SRE ID (usually a short string e.g '9' for SRE 9)")]
        $sreId
    )
    $configRootDir = Get-ConfigRootDir
    $sreCoreConfigFilename = "sre_${sreId}_core_config.json"
    $sreCoreConfigPath = Join-Path $configRootDir "core" $sreCoreConfigFilename -Resolve
    $sreFullConfigFilename = "sre_${sreId}_full_config.json"
    $sreFullConfigPath = Join-Path $configRootDir "full" $sreFullConfigFilename

    # Import minimal management config parameters from JSON config file - we can derive the rest from these
    $sreConfigBase = Get-Content -Path $sreCoreConfigPath -Raw | ConvertFrom-Json

    # Use hash table for config
    $config = [ordered]@{
        shm = Get-ShmFullConfig ($sreConfigBase.shmId)
        sre = [ordered]@{}
    }

    # === SRE configuration parameters ===
    $sre = [ordered]@{}
    # Import minimal SRE config parameters from JSON config file - we can derive the rest from these
    $sreConfigBase = Get-Content -Path $sreCoreConfigPath -Raw | ConvertFrom-Json
    $srePrefix = $sreConfigBase.ipPrefix

    # Deconstruct VNet address prefix to allow easy construction of IP based parameters
    $srePrefixOctets = $srePrefix.Split('.')
    $sreBasePrefix = $srePrefixOctets[0] + "." + $srePrefixOctets[1]
    $sreThirdOctet = $srePrefixOctets[2]

    # --- Top-level config ---
    $config.sre.subscriptionName = $sreConfigBase.subscriptionName
    $config.sre.id = $sreConfigBase.sreId
    if ($config.sre.id.length -gt 7) {
        Write-Host "sreId should be 7 characters or fewer if possible. '$($config.sre.id)' is $($config.sre.id.length) characters long."
    }
    $config.sre.shortName = "sre-$($sreConfigBase.sreId)".ToLower()
    $config.sre.location = $config.shm.location
    $config.sre.tier = $sreConfigBase.tier
    $config.sre.adminSecurityGroupName = $sreConfigBase.adminSecurityGroupName

    # -- Domain config ---
    $netbiosNameMaxLength = 15
    if ($sreConfigBase.netbiosName.length -gt $netbiosNameMaxLength) {
        throw "Netbios name must be no more than 15 characters long. '$($sreConfigBase.netbiosName)' is $($sreConfigBase.netbiosName.length) characters long."
    }
    $config.sre.domain = [ordered]@{}
    $config.sre.domain.fqdn = $sreConfigBase.domain
    $config.sre.domain.netbiosName = $sreConfigBase.netbiosName
    $config.sre.domain.dn = "DC=" + ($config.sre.domain.fqdn.Replace('.',',DC='))
    $serverAdminsGroup = "SG $($config.sre.domain.netbiosName) Server Administrators"
    $researchUsersGroup = "SG $($config.sre.domain.netbiosName) Research Users"
    $config.sre.domain.securityGroups = [ordered]@{
        serverAdmins = [ordered]@{
            name = $serverAdminsGroup
            description = $serverAdminsGroup
        }
        researchUsers = [ordered]@{
            name = $researchUsersGroup
            description = $researchUsersGroup
        }
    }

    # --- Network config ---
    $config.sre.network = [ordered]@{
        vnet = [ordered]@{}
        subnets = [ordered]@{
            identity = [ordered]@{}
            rds = [ordered]@{}
            data = [ordered]@{}
            gateway = [ordered]@{}
        }
        nsg = [ordered]@{
            data = [ordered]@{}
        }
    }
    $config.sre.network.vnet.rg = "RG_SRE_NETWORKING"
    $config.sre.network.vnet.name = "VNET_SRE_" + $($config.sre.id).ToUpper()
    $config.sre.network.vnet.cidr = $sreBasePrefix + "." + $sreThirdOctet + ".0/21"
    $config.sre.network.subnets.identity.name = "IdentitySubnet"
    $config.sre.network.subnets.identity.prefix = $sreBasePrefix + "." + $sreThirdOctet
    $config.sre.network.subnets.identity.cidr = $config.sre.network.subnets.identity.prefix + ".0/24"
    $config.sre.network.subnets.rds.name = "RDSSubnet"
    $config.sre.network.subnets.rds.prefix = $sreBasePrefix + "." + ([int]$sreThirdOctet + 1)
    $config.sre.network.subnets.rds.cidr = $config.sre.network.subnets.rds.prefix + ".0/24"
    $config.sre.network.subnets.data.name = "SharedDataSubnet"
    $config.sre.network.subnets.data.prefix = $sreBasePrefix + "." + ([int]$sreThirdOctet + 2)
    $config.sre.network.subnets.data.cidr = $config.sre.network.subnets.data.prefix + ".0/24"
    # The Gateway subnet MUST be named 'GatewaySubnet' - see https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-vpn-faq#do-i-need-a-gatewaysubnet
    $config.sre.network.subnets.gateway.name = "GatewaySubnet"
    $config.sre.network.subnets.gateway.prefix = $sreBasePrefix + "." + ([int]$sreThirdOctet + 7)
    $config.sre.network.subnets.gateway.cidr = $config.sre.network.subnets.gateway.prefix + ".0/27"

    # --- Storage config --
    $storageRg = "RG_SRE_ARTIFACTS"
    $storageSuffix = New-RandomLetters -SeedPhrase $config.sre.subscriptionName
    $config.sre.storage = [ordered]@{
        artifacts = [ordered]@{
            rg = $storageRg
            accountName = "sre$($shm.id)artifacts${storageSuffix}".ToLower() | TrimToLength 24
        }
        bootdiagnostics = [ordered]@{
            rg = $storageRg
            accountName = "sre$($shm.id)bootdiags${storageSuffix}".ToLower() | TrimToLength 24
        }
    }

    # --- Secrets ---
    $config.sre.keyVault = [ordered]@{
        name = "kv-$($config.shm.id)-sre-$($config.sre.id)".ToLower()
        rg = "RG_SRE_SECRETS"
        secretNames = [ordered]@{
            adminUsername = "$($config.sre.shortName)-vm-admin-username"
            rdsAdminPassword = "$($config.sre.shortName)-rdsvm-admin-password"
            dataServerAdminPassword = "$($config.sre.shortName)-dataservervm-admin-password"
            dsvmAdminPassword = "$($config.sre.shortName)-dsvm-admin-password"
            webappAdminPassword = "$($config.sre.shortName)-webappvm-admin-password"
            dsvmDbAdminPassword = "$($config.sre.shortName)-dsvm-pgdb-admin-password"
            dsvmDbReaderPassword = "$($config.sre.shortName)-dsvm-pgdb-reader-password"
            dsvmDbWriterPassword = "$($config.sre.shortName)-dsvm-pgdb-writer-password"
            dsvmLdapPassword = "$($config.sre.shortName)-dsvm-ldap-password"
            dataMountPassword = "$($config.sre.shortName)-datamount-password"
            gitlabLdapPassword = "$($config.sre.shortName)-gitlab-ldap-password"
            gitlabRootPassword = "$($config.sre.shortName)-gitlab-root-password"
            gitlabUserPassword = "$($config.sre.shortName)-gitlab-user-password"
            hackmdLdapPassword = "$($config.sre.shortName)-hackmd-ldap-password"
            hackmdUserPassword = "$($config.sre.shortName)-hackmd-user-password"
            letsEncryptCertificate = "$($config.sre.shortName)-lets-encrypt-certificate"
            npsSecret = "$($config.sre.shortName)-nps-secret"
            testResearcherPassword = "$($config.sre.shortName)-test-researcher-password"
        }
    }

    # --- Domain users ---
    $config.sre.users = [ordered]@{
        ldap = [ordered]@{
            gitlab = [ordered]@{
                name = "$($config.sre.domain.netbiosName) Gitlab LDAP"
                samAccountName = "gitlabldap$($sreConfigBase.sreId)".ToLower() | TrimToLength 20
            }
            hackmd = [ordered]@{
                name = "$($config.sre.domain.netbiosName) HackMD LDAP"
                samAccountName = "hackmdldap$($sreConfigBase.sreId)".ToLower() | TrimToLength 20
            }
            dsvm = [ordered]@{
                name = "$($config.sre.domain.netbiosName) DSVM LDAP"
                samAccountName = "dsvmldap$($sreConfigBase.sreId)".ToLower() | TrimToLength 20
            }
        }
        datamount = [ordered]@{
            name = "$($config.sre.domain.netbiosName) Data Mount"
            samAccountName = "datamount$($sreConfigBase.sreId)".ToLower() | TrimToLength 20
        }
        researchers = [ordered]@{
            test = [ordered]@{
                name = "$($config.sre.domain.netbiosName) Test Researcher"
                samAccountName = "testresrch$($sreConfigBase.sreId)".ToLower() | TrimToLength 20
            }
        }
    }

    # --- RDS Servers ---
    $config.sre.rds = [ordered]@{
        rg = "RG_SRE_RDS"
        gateway = [ordered]@{
            vmName = "RDG-SRE-$($config.sre.id)".ToUpper() | TrimToLength 15
            vmSize = "Standard_DS2_v2"
            nsg = "NSG_SRE_$($config.sre.id)_RDS_SERVER".ToUpper()
            networkRules = [ordered]@{}
        }
        sessionHost1 = [ordered]@{
            vmName = "APP-SRE-$($config.sre.id)".ToUpper() | TrimToLength 15
            vmSize = "Standard_DS2_v2"
            nsg = "NSG_SRE_$($config.sre.id)_RDS_SESSION_HOSTS".ToUpper()
        }
        sessionHost2 = [ordered]@{
            vmName = "DKP-SRE-$($config.sre.id)".ToUpper() | TrimToLength 15
            vmSize = "Standard_DS2_v2"
            nsg = "NSG_SRE_$($config.sre.id)_RDS_SESSION_HOSTS".ToUpper()
        }
    }

    # Set which IPs can access the Safe Haven: if 'default' is given then apply sensible defaults
    if ($sreConfigBase.rdsAllowedSources -eq "default") {
        if (@("3","4").Contains($config.sre.tier)) {
            $config.sre.rds.gateway.networkRules.allowedSources = "193.60.220.240"
        } elseif ($config.sre.tier -eq "2") {
            $config.sre.rds.gateway.networkRules.allowedSources = "193.60.220.253"
        } elseif (@("0","1").Contains($config.sre.tier)) {
            $config.sre.rds.gateway.networkRules.allowedSources = "Internet"
        }
    } else {
        $config.sre.rds.gateway.networkRules.allowedSources = $sreConfigBase.rdsAllowedSources
    }
    # Set whether internet access is allowed: if 'default' is given then apply sensible defaults
    if ($sreConfigBase.rdsInternetAccess -eq "default") {
        if (@("2","3","4").Contains($config.sre.tier)) {
            $config.sre.rds.gateway.networkRules.outboundInternet = "Deny"
        } elseif (@("0","1").Contains($config.sre.tier)) {
            $config.sre.rds.gateway.networkRules.outboundInternet = "Allow"
        }
    } else {
        $config.sre.rds.nsg.gateway.outboundInternet = $sreConfigBase.rdsInternetAccess
    }
    $config.sre.rds.gateway.hostname = $config.sre.rds.gateway.vmName
    $config.sre.rds.gateway.fqdn = "$($config.sre.rds.gateway.hostname).$($config.shm.domain.fqdn)"
    $config.sre.rds.gateway.ip = "$($config.sre.network.subnets.rds.prefix).250"
    $config.sre.rds.sessionHost1.hostname = $config.sre.rds.sessionHost1.vmName
    $config.sre.rds.sessionHost1.fqdn = "$($config.sre.rds.sessionHost1.hostname).$($config.shm.domain.fqdn)"
    $config.sre.rds.sessionHost1.ip = "$($config.sre.network.subnets.rds.prefix).249"
    $config.sre.rds.sessionHost2.hostname = $config.sre.rds.sessionHost2.vmName
    $config.sre.rds.sessionHost2.fqdn = "$($config.sre.rds.sessionHost2.hostname).$($config.shm.domain.fqdn)"
    $config.sre.rds.sessionHost2.ip = "$($config.sre.network.subnets.rds.prefix).248"

    # --- Secure servers ---

    # Data server
    $config.sre.dataserver = [ordered]@{}
    $config.sre.dataserver.rg = "RG_SRE_DATA"
    $config.sre.dataserver.nsg = "NSG_SRE_$($config.sre.id)_DATA".ToUpper()
    $config.sre.dataserver.vmName = "DAT-SRE-$($config.sre.id)".ToUpper() | TrimToLength 15
    $config.sre.dataserver.vmSize = "Standard_D2s_v3"
    $config.sre.dataserver.hostname = $config.sre.dataserver.vmName
    $config.sre.dataserver.fqdn = "$($config.sre.dataserver.hostname).$($config.shm.domain.fqdn)"
    $config.sre.dataserver.ip = "$($config.sre.network.subnets.data.prefix).250"
    $config.sre.dataserver.egressDiskGb = 64
    $config.sre.dataserver.ingressDiskGb = 512
    $config.sre.dataserver.sharedDiskGb = 256

    # HackMD and Gitlab servers
    $config.sre.webapps = [ordered]@{
        rg = "RG_SRE_WEBAPPS"
        nsg = "NSG_SRE_$($config.sre.id)_WEBAPPS".ToUpper()
        gitlab = [ordered]@{
            vmName = "GITLAB-SRE-$($config.sre.id)".ToUpper()
            vmSize = "Standard_D2s_v3"
        }
        hackmd = [ordered]@{
            vmName = "HACKMD-SRE-$($config.sre.id)".ToUpper()
            vmSize = "Standard_D2s_v3"
        }
    }
    $config.sre.webapps.gitlab.hostname = $config.sre.webapps.gitlab.vmName
    $config.sre.webapps.gitlab.fqdn = "$($config.sre.webapps.gitlab.hostname).$($config.shm.domain.fqdn)"
    $config.sre.webapps.gitlab.ip = "$($config.sre.network.subnets.data.prefix).151"
    $config.sre.webapps.hackmd.hostname = $config.sre.webapps.hackmd.vmName
    $config.sre.webapps.hackmd.fqdn = "$($config.sre.webapps.hackmd.hostname).$($config.shm.domain.fqdn)"
    $config.sre.webapps.hackmd.ip = "$($config.sre.network.subnets.data.prefix).152"

    # Compute VMs
    $config.sre.dsvm = [ordered]@{}
    $config.sre.dsvm.rg = "RG_SRE_COMPUTE"
    $config.sre.dsvm.nsg = "NSG_SRE_$($config.sre.Id)_COMPUTE".ToUpper()
    $config.sre.dsvm.deploymentNsg = "NSG_SRE_$($config.sre.Id)_COMPUTE_DEPLOYMENT".ToUpper()
    $config.sre.dsvm.vmImageSubscription = $config.shm.computeVmImageSubscriptionName
    $config.shm.Remove("computeVmImageSubscriptionName")
    $config.sre.dsvm.vmImageResourceGroup = $config.shm.computeVmImageResourceGroupName
    $config.shm.Remove("computeVmImageResourceGroupName")
    $config.sre.dsvm.vmImageGallery = $config.shm.computeVmImageImageGalleryName
    $config.shm.Remove("computeVmImageImageGalleryName")
    $config.sre.dsvm.vmSizeDefault = "Standard_D2s_v3"
    $config.sre.dsvm.vmImageType = $sreConfigBase.computeVmImageType
    $config.sre.dsvm.vmImageVersion = $sreConfigBase.computeVmImageVersion
    $config.sre.dsvm.osdisk = [ordered]@{
        type = "Standard_LRS"
        size_gb = "60"
    }
    $config.sre.dsvm.datadisk = [ordered]@{
        type = "Standard_LRS"
        size_gb = "512"
    }
    $config.sre.dsvm.homedisk = [ordered]@{
        type = "Standard_LRS"
        size_gb = "128"
    }

    # --- Package mirror config ---
    $config.sre.mirrors = [ordered]@{
        vnet = [ordered]@{}
        cran = [ordered]@{}
        pypi = [ordered]@{}
    }
    # Tier-2 and Tier-3 mirrors use different IP ranges for their VNets so they can be easily identified
    if (@("2","3").Contains($config.sre.tier)) {
        $config.sre.mirrors.vnet.name = "VNET_SHM_$($config.shm.id)_PACKAGE_MIRRORS_TIER$($config.sre.tier)".ToUpper()
        $config.sre.mirrors.pypi.ip = "10.20.$($config.sre.tier).20"
        $config.sre.mirrors.cran.ip = "10.20.$($config.sre.tier).21"
    } elseif (@("0","1").Contains($config.sre.tier)) {
        $config.sre.mirrors.vnet.name = $null
        $config.sre.mirrors.pypi.ip = $null
        $config.sre.mirrors.cran.ip = $null
    } else {
        Write-Error "Tier '$($config.sre.tier)' not supported (NOTE: Tier must be provided as a string in the core SRE config.)"
        return
    }

    $jsonOut = ($config | ConvertTo-Json -Depth 10)
    Write-Host $jsonOut
    Out-File -FilePath $sreFullConfigPath -Encoding "UTF8" -InputObject $jsonOut
}
Export-ModuleMember -Function Add-SreConfig


# Get a SRE configuration
# -----------------------
function Get-SreConfig {
    param(
        [string]$sreId
    )
    # Read SRE config from file
    $configRootDir = Join-Path $(Get-ConfigRootDir) "full" -Resolve
    $configFilename = "sre_${sreId}_full_config.json"
    $configPath = Join-Path $configRootDir $configFilename -Resolve
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    return $config
}
Export-ModuleMember -Function Get-SreConfig
