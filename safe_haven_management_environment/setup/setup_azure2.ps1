param([string] $SubscriptionId = "", 
        [string] $vaultName = "shmvault")


# Set the subscriptionID
Set-AzContext -SubscriptionId $SubscriptionId
        
New-AzResourceGroupDeployment -resourcegroupname "RG_SHM_NPS" -templatefile "../arm_templates/shmnps/shmnps-template.json" -Administrator_User atiadmin -Domain_Name TURINGDSHTEST.ac.uk

# TO RUN THIS SCRIPT (second is my personal subscription)
# ./setup_azure2.ps1 -SubscriptionId "ff4b0757-0eb8-4e76-a53d-4065421633a6"
