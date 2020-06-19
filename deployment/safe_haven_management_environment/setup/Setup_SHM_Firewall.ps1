param(
    [Parameter(Position = 0, Mandatory = $true, HelpMessage = "Enter SHM ID (usually a string e.g enter 'testa' for Turing Development Safe Haven A)")]
    [string]$shmId
)

Import-Module Az
Import-Module $PSScriptRoot/../../common/Configuration.psm1 -Force
Import-Module $PSScriptRoot/../../common/Deployments.psm1 -Force
Import-Module $PSScriptRoot/../../common/Logging.psm1 -Force


# Get config and original context before changing subscription
# ------------------------------------------------------------
$config = Get-ShmFullConfig $shmId
$originalContext = Get-AzContext
$_ = Set-AzContext -SubscriptionId $config.subscriptionName


# Ensure that firewall subnet exists
# ----------------------------------
$virtualNetwork = Get-AzVirtualNetwork -Name $config.network.vnet.name -ResourceGroupName $config.network.vnet.rg
$null = Deploy-Subnet -Name $config.network.subnets.firewall.name -VirtualNetwork $virtualNetwork -AddressPrefix $config.network.subnets.firewall.cidr


# Create the firewall with a public IP address
# NB. the firewall needs to be in the same resource group as the VNet
# NB. it is not possible to assign a private IP address to the firewall - it will take the first available one in the subnet
# --------------------------------------------------------------------------------------------------------------------------------
Add-LogMessage -Level Info "Create the firewall with a public IP address"
$firewall = Deploy-Firewall -Name $config.firewall.name -ResourceGroupName $config.network.vnet.rg -Location $config.location -VirtualNetworkName $config.network.vnet.name


# Enable logging for this firewall
# --------------------------------
Add-LogMessage -Level Info "Enable logging for this firewall"
$workspace = Deploy-LogAnalyticsWorkspace -Name $config.logging.workspaceName -ResourceGroupName $config.logging.rg -Location $config.location
$null = Set-AzDiagnosticSetting -ResourceId $firewall.Id -WorkspaceId $workspace.ResourceId -Enabled $true
if ($?) {
    Add-LogMessage -Level Success "Enabled logging to workspace '$($config.logging.workspaceName)'"
} else {
    Add-LogMessage -Level Fatal "Failed to enabled logging to workspace '$($config.logging.workspaceName)'!"
}


# Create a routing table ensuring that BGP propagation is disabled
# Without this, VMs might be able to jump directly to the target without going through the firewall
# -------------------------------------------------------------------------------------------------
$routeTable = Deploy-RouteTable -Name $config.firewall.routeTableName -ResourceGroupName $config.network.vnet.rg -Location $config.location


# Set firewall rules from template
# --------------------------------
Add-LogMessage -Level Info "Setting firewall rules from template..."
$rules = (Get-Content (Join-Path $PSScriptRoot ".." "arm_templates" "shm-firewall-rules-template.json") -Raw).
             Replace("<shm-firewall-private-ip>", $firewall.IpConfigurations.PrivateIpAddress).
             Replace("<shm-id>", $config.id).
             Replace("<subnet-identity-cidr>", $config.network.subnets.identity.cidr).
             Replace("<subnet-vpn-cidr>", $config.network.vpn.cidr) | ConvertFrom-Json -AsHashtable


# Add routes to the route table
# We need to keep all routing symmetric, or it will be dropped by the firewall.
# VPN gateway connections do not come via the firewall so they must return by the same route.
# All other requests should be routed via the firewall.
# Since the gateway subnet CIDR is more specific than the general rule, it will take precedence
# ---------------------------------------------------------------------------------------------
foreach ($route in $rules.routes) {
    $null = Deploy-Route -Name $route.name -RouteTable $routeTable -AppliesTo $route.properties.addressPrefix -NextHop $route.properties.nextHop
}


# Attach all subnets except the VPN gateway to the firewall route table
# ---------------------------------------------------------------------
$null = Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $VirtualNetwork -Name $config.network.subnets.identity.name -AddressPrefix $config.network.subnets.identity.cidr -RouteTable $RouteTable | Set-AzVirtualNetwork


# Application rules
# -----------------
Add-LogMessage -Level Info "Setting firewall application rules..."
foreach ($ruleCollection in $rules.applicationRuleCollections) {
    foreach ($rule in $ruleCollection.properties.rules) {
        $params = @{}
        if ($rule.fqdnTags) { $params["TargetTag"] = $rule.fqdnTags }
        if ($rule.protocols) { $params["Protocol"] = $rule.protocols }
        if ($rule.targetFqdns) { $params["TargetFqdn"] = $rule.targetFqdns }
        $_ = Deploy-FirewallApplicationRule -Name $rule.name -CollectionName $ruleCollection.name -Firewall $firewall -SourceAddress $rule.sourceAddresses -Priority $ruleCollection.properties.priority -ActionType $ruleCollection.properties.action.type @params
    }
}


# Network rules
# -------------
Add-LogMessage -Level Info "Setting firewall network rules..."
foreach ($ruleCollection in $rules.networkRuleCollections) {
    foreach ($rule in $ruleCollection.properties.rules) {
        $_ = Deploy-FirewallNetworkRule -Name $rule.name -CollectionName $ruleCollection.name -Firewall $firewall -SourceAddress $rule.sourceAddresses -DestinationAddress $rule.destinationAddresses -DestinationPort $rule.destinationPorts -Protocol $rule.protocols -Priority $ruleCollection.properties.priority -ActionType $ruleCollection.properties.action.type
    }
}


# Switch back to original subscription
# ------------------------------------
$_ = Set-AzContext -Context $originalContext
