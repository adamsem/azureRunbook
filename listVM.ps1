$rg = "kaas-backend-stg-central-rg"
[System.Collections.ArrayList]$VmList = @()
$exclude = "kaas-db-02-stg-central-vm,kaas-db-03-stg-central-vm"


$TmpList = Get-AzureRmVM -ResourceGroupName $rg | select Name

Foreach ($i in $TmpList.Name)

{
    $VmList.Add($i)
    Write-Output $i
}

foreach($r in $exclude.split(",")){
    $VmList.remove($r)
}

Write-Output -------------------------------------------------------------------

Foreach ($i in $VmList)

{
    Write-Output $i
    #Get-AzureRmVMSize -ResourceGroupName $rg -VMName $i
}