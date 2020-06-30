Param
(
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
    [String]
    $azuresubid,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
    [String]
    $rgstartstop="",
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]
    $excludedvm="",
    [Parameter(Mandatory=$true)][ValidateSet("Start","Stop")]
    [String]
    $Action
)
do
{
    #----------------------------------------------------------------------------------
    #---------------------LOGIN TO AZURE AND SELECT THE SUBSCRIPTION-------------------
    #----------------------------------------------------------------------------------
    Write-Output "Logging into Azure subscription using Az cmdlets..."
    $connectionName = "AzureRunAsConnection"
    try{
        $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName
        Add-AzAccount `
               -ServicePrincipal `
               -TenantId $servicePrincipalConnection.TenantId `
               -ApplicationId $servicePrincipalConnection.ApplicationId `
               -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint
        Write-Output "Loging into Azure subscription using Az cmdlets..."
        $RetryFlag = $false
    }
    catch
    {
        if (!$servicePrincipalConnection)
        {
            $ErrorMessage = "Connection $connectionName not found."
            $RetryFlag = $false
            throw $ErrorMessage
        }
        if ($Attempt -gt $RetryCount)
        {
            Write-Output "$FailureMessage! Total retry attempts: $RetryCount"
            Write-Output "[Error Message] $($_.exception.message) `n"
            $RetryFlag = $false
        }
        else
        {
            Write-Output "[$Attempt/$RetryCount] $FailureMessage. Retrying in $TimeoutInSecs seconds..."
            Start-Sleep -Seconds $TimeoutInSecs
            $Attempt = $Attempt + 1
        }
    }
}
while($RetryFlag)
$AzureVMsToHandle = [System.Collections.ArrayList]@()
$startSequences = [System.Collections.ArrayList]@()
$stopSequences = [System.Collections.ArrayList]@()
$startTagValue = "sequencestart"
$stopTagValue = "sequencestop"
$startTagKey = Get-AzVM | Where-Object {$_.Tags.Keys -eq $startTagValue.ToLower()} | Select Tags
$stopTagKey = Get-AzVM | Where-Object {$_.Tags.Keys -eq $stopTagValue.ToLower()} | Select Tags

foreach($tag in $startTagKey.Tags){
    foreach ($key in $tag.keys)
    {
        if ($key.ToLower() -eq $startTagValue.ToLower())
        {
            [void]$startSequences.add([int]$tag[$key])
        }
    }
}

foreach($tag in $stopTagKey.Tags){
    foreach ($key in $tag.keys)
    {
        if ($key.ToLower() -eq $stopTagValue.ToLower())
        {
            [void]$stopSequences.add([int]$tag[$key])
        }
    }
}
$startSequences = $startSequences | Sort-Object -Unique
$stopSequences = $stopSequences | Sort-Object -Unique

function PerformActionOnSequencedTaggedVMRGs($sequences, [string]$Action, $TagName, [string[]]$VMRGList, $ExcludeList)
{
    foreach($rg in $rgstartstop.split(",")
    {
        foreach ( $seq in $sequences)
        {
            $TmpList = Get-AzResource -TagValue $seq | Where-Object {($_.ResourceType -eq “Microsoft.Compute/virtualMachines”) -and ($_.ResourceGroupName -eq $rg.Trim())} | Select Name, ResourceGroupName

            foreach($vm in $TmpList)
            {
                $FilterTagVMs = Get-AzVM -ResourceGroupName $rg -Name $vm

                $CaseSensitiveTagName = $FilterTagVMs.Tags.Keys | Where-Object -FilterScript {$_ -eq $TagName}

                if($CaseSensitiveTagName -ne $null)
                {
                    if($FilterTagVMs.Tags[$CaseSensitiveTagName] -eq $seq)
                    {
                        $AzureVMsToHandle.Add($vm)
                    }
                }

            }
        }

        foreach($vm in $excludedvm.split(","){
            $AzureVMsToHandle.remove($vm)
        }
    }
}

if($Action -eq "Stop")
{
    PerformActionOnSequencedTaggedVMRGs -Sequences $stopSequences -TagName $stopTagValue
    Write-Output "Stopping VMs";
    foreach -parallel ($AzureVM in $AzureVMsToHandle)
    {
        Stop-AzVM -Force -ResourceGroupName $rg -Name $AzureVM
    }
}
else
{
    PerformActionOnSequencedTaggedVMRGs -Sequences $startSequences -TagName $startTagValue
    Write-Output "Starting VMs";
    foreach -parallel ($AzureVM in $AzureVMsToHandle)
    {
        Start-AzVM -ResourceGroupName $rg -Name $AzureVM
    }
}