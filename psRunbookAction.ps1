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
    $Action,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [bool]
    $ContinueOnError = $false
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
$maxWaitTimeForVMRetryInSeconds = 30

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

function PerformActionOnSequencedTaggedVMRGs($Sequences, $TagName)
{
    foreach($rg in $rgstartstop.split(",")
    {
        foreach ( $seq in $sequences)
        {
            $TmpList = Get-AzResource -TagValue $seq | Where-Object {($_.ResourceType -eq “Microsoft.Compute/virtualMachines”) -and ($_.ResourceGroupName -eq $rg.Trim())} | Select Name

            foreach($vm in $TmpList.Name)
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

function CheckVMState ($VMObject,[string]$Action)
{
    [bool]$IsValid = $false

    $CheckVMState = (Get-AzVM -ResourceGroupName $rg -Name $vm -Status -ErrorAction SilentlyContinue).Statuses.Code[1]
    if($Action.ToLower() -eq 'start' -and $CheckVMState -eq 'PowerState/running')
    {
        $IsValid = $true
    }
    elseif($Action.ToLower() -eq 'stop' -and $CheckVMState -eq 'PowerState/deallocated')
    {
        $IsValid = $true
    }
    return $IsValid
}

if($Action -eq "Stop")
{
    PerformActionOnSequencedTaggedVMRGs -Sequences $stopSequences -TagName $stopTagValue
    Write-Output "Stopping VMs";
    foreach ($AzureVM in $AzureVMsToHandle)
    {
        $CheckVMStatus = CheckVMState -VMObject $AzureVM -Action $Action
        if ( $CheckVMStatus -eq $false )
        {
            Stop-AzVM -Force -ResourceGroupName $rg -Name $AzureVM
        }
        While($CheckVMStatus -eq $false)
        {
            Write-Output "Checking the VM Status in 10 seconds..."
            Start-Sleep -Seconds 10
            $SleepCount+=10
            if($SleepCount -gt $maxWaitTimeForVMRetryInSeconds -and $ContinueOnError -eq $false)
            {
                Write-Output "Unable to $($Action) the VM $($AzureVM). ContinueOnError is set to False, hence terminating the sequenced $($Action)..."
                Write-Output "Completed the sequenced $($Action)..."
                exit
            }
            elseif($SleepCount -gt $maxWaitTimeForVMRetryInSeconds -and $ContinueOnError -eq $true)
            {
                Write-Output "Unable to $($Action) the VM $($AzureVM). ContinueOnError is set to True, hence moving to the next resource..."
                break
            }
            $CheckVMStatus = CheckVMState -VMObject $AzureVM -Action $Action
        }
    }
}
else
{
    PerformActionOnSequencedTaggedVMRGs -Sequences $startSequences -TagName $startTagValue
    Write-Output "Starting VMs";
    foreach ($AzureVM in $AzureVMsToHandle)
    {
        $CheckVMStatus = CheckVMState -VMObject $AzureVM -Action $Action
        if ( $CheckVMStatus -eq $false )
        {
            Start-AzVM -Force -ResourceGroupName $rg -Name $AzureVM
        }
        While($CheckVMStatus -eq $false)
        {
            Write-Output "Checking the VM Status in 10 seconds..."
            Start-Sleep -Seconds 10
            $SleepCount+=10
            if($SleepCount -gt $maxWaitTimeForVMRetryInSeconds -and $ContinueOnError -eq $false)
            {
                Write-Output "Unable to $($Action) the VM $($AzureVM). ContinueOnError is set to False, hence terminating the sequenced $($Action)..."
                Write-Output "Completed the sequenced $($Action)..."
                exit
            }
            elseif($SleepCount -gt $maxWaitTimeForVMRetryInSeconds -and $ContinueOnError -eq $true)
            {
                Write-Output "Unable to $($Action) the VM $($AzureVM). ContinueOnError is set to True, hence moving to the next resource..."
                break
            }
            $CheckVMStatus = CheckVMState -VMObject $AzureVM -Action $Action
        }
    }
}