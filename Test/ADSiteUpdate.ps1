param ( [parameter(Mandatory=$false)] [Object]$RecoveryPlanContext,[parameter(Mandatory=$false)][String]$AsrServersTable="asrservers")
#Script Purpose : To perform Registry update for SiteName to reflect the recovery site based on FailoverDirection.
#Version : v3.0a
#Date : 8-Oct-2020

Function CreateRunScript-AD-SiteNameUpdate {
# Script to update AD site name
If($Global:FailoverDirection -eq "PrimaryToSecondary")
{
$mycmd.add('$FailoverDirection="PrimaryToSecondary"')
}
else
{
$mycmd.add('$FailoverDirection="SecondaryToPrimary"')
}
$mycmd.add('if($FailoverDirection -eq "PrimaryToSecondary")')
$mycmd.add('{')
$mycmd.add('Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Services\Netlogon\Parameters" -Name "SiteName" -Value "Azure-Pune-DR"')
$mycmd.add('$RegValue = (Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Services\Netlogon\Parameters" -Name "SiteName").SiteName')
$mycmd.add('if($RegValue -eq "Azure-Pune-DR")   { Write-Output "Success"   }   else   { Write-Output "Failed"    }')
$mycmd.add('}')
$mycmd.add('else')
$mycmd.add('{')
$mycmd.add('Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Services\Netlogon\Parameters" -Name "SiteName" -Value "Azure-IND"')
$mycmd.add('$RegValue = (Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Services\Netlogon\Parameters" -Name "SiteName").SiteName')
$mycmd.add('if($RegValue -eq "Azure-IND")   { Write-Output "Success"   }   else   { Write-Output "Failed"    }')
$mycmd.add('}')
$mycmd.add('Clear-DnsClientCache')
$mycmd.add('Register-DnsClient')

}
Function AD-SiteNameUpdate {
param([parameter(Mandatory=$true)][String]$Task,[parameter(Mandatory=$true)][String]$Runbook,[parameter(Mandatory=$true)][Object]$Table,[parameter(Mandatory=$true)][Object]$AllVMList)
If($Global:CanProceedExecution -eq $false)
{
Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -Status $Global:VMPrequisiteStatus -Partition $Global:PartitionKey 
break
}

If($Global:FailoverDirection -match "PrimaryToSecondary") 
{
Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -Status "Failover Direction: Azure South India (Primary) => Central India (DR)" -Partition $Global:PartitionKey 
}
 else 
 {
 Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -Status "Failover Direction: Azure Central India (DR) => South India (Primary)" -Partition $Global:PartitionKey 
 }

# Create a data table to store important values while processing
$Global:datatable = New-Object system.Data.DataTable "VM"
$col1 = New-Object system.Data.DataColumn VM,([string])
$col2 = New-Object system.Data.DataColumn RG,([string])
$col3 = New-Object system.Data.DataColumn Location,([string])
$col4 = New-Object system.Data.DataColumn VMStatus,([string])
$col5 = New-Object system.Data.DataColumn JobStatus,([string])
$col6 = New-Object system.Data.DataColumn JobID,([string])
$Global:datatable.columns.add($col1)
$Global:datatable.columns.add($col2)
$Global:datatable.columns.add($col3)
$Global:datatable.columns.add($col4)
$Global:datatable.columns.add($col5)
$Global:datatable.columns.add($col6)
# To capture Run command status against vm
$jobiddatatable = New-Object system.Data.DataTable "JobID"
$col1 = New-Object system.Data.DataColumn VM,([string])
$col2 = New-Object system.Data.DataColumn 'Update_Status',([string])
$jobiddatatable.columns.add($col1)
$jobiddatatable.columns.add($col2)

# Script to update AD Site Name, script is generated in run time and temporary file path will be given to Invoke-AzVMRunCommand
$temppath=$Env:temp+"\adsiteupdate.ps1"
$Global:mycmd = New-Object 'System.Collections.Generic.List[String]'
CreateRunScript-AD-SiteNameUpdate
$mycmd | out-file -FilePath $temppath
$scriptFile = get-item $temppath
$Global:fullPath = $scriptfile.fullname
$Global:scriptfile = $scriptfile.name
Set-AzContext -SubscriptionId $Global:ITProdSubscriptionID -TenantId $Global:Tenantid
$storageAccount = Get-AzStorageAccount -ResourceGroupName $Global:StorageRG -Name $Global:StorageAccountName
$ctx = $storageAccount.Context
Set-AzStorageBlobContent -Container "scripts" -File $Global:fullpath -Context $ctx -Force | Out-Null
$ScriptPath = "https://"+$Global:StorageAccountName+".blob.core.windows.net/scripts/"+$Global:scriptfile
#$ScriptFileName = $Global:scriptfile

#To store background job ids
$jobIDs= New-Object System.Collections.Generic.List[System.Object]
$Global:VMFor2ndAttempt=@("VMsToBeAdded")
$AttemptCounter = 1
$VMhasBug = @()
# Select correct subscription context to get VM status
Switch-Subscription
Do{
    foreach($vm in $AllVMList) 
    {  
    $vmname=$vm.name
If ($AttemptCounter -gt 1 -and $Global:VMFor2ndAttempt -notcontains $vmname )
    {
    $jobIDs.Clear()
    continue
    }
    elseIf($AttemptCounter -gt 1)
    {
    $jobIDs.Clear()
    }
    Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -VMName $vmname -Status "Attempt# $($AttemptCounter)" -Partition $Global:PartitionKey
   
    $newjob = $null
   If($Global:FailoverDirection -match "PrimaryToSecondary")
                                {
                                $vmrg=$vm.DRRG
                                $vmlocation="Central India"
                                }
                                Else
                                {
                                $vmrg=$vm.PrimaryRG
                                $vmlocation="South India"
                                }
Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -VMName $vmname -Status "Argument Value = $Global:argument" -Partition $Global:PartitionKey
# Handle test failover
    If ($Global:FailoverType -match "Test")
                             {
                             $vmname=$vmname+"-test"
                             }
                           

Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -Status "Checking VM & VM Agent service are running or max wait time is 4 mins.." -Partition $Global:PartitionKey
# all values in seconds
$totalTimeToWait = 240
$timeWaited = 0
$recheckAfter = 10
do{
$vmhealthy = Is-VMRunning -vmname $vmname -vmrg $vmrg  

if($vmhealthy)
{
break
}
    Start-Sleep -Seconds $recheckAfter
    $timeWaited += $recheckAfter
} While ($timeWaited -lt $totalTimeToWait)
 #Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -VMName $vmname -Status $row.JobStatus -Partition $Global:PartitionKey -Remarks "VM is ($Global:vmstatus);VM Agent is ($Global:agtstat)"


   If ($vmhealthy)
               {
# Starting Run command execution as a background job
            Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -VMName $vmname -Status "Invoking RUN command (AD site update & Update 'A' record with AD DNS).." -Partition $Global:PartitionKey
                            $newJob = Start-ThreadJob `
                            -ScriptBlock `
                            { `
                            param($resourceGroup, $vmName, $scriptPath) `
                            $a=Invoke-AzVMRunCommand -ResourceGroupName $resourceGroup -VMName $VmName -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath; return $a `
                            } `
                            -ArgumentList $vmrg, $vmname, $fullPath -ErrorAction SilentlyContinue -ErrorVariable cmdleterror
                       
                }
                        if ($newJob)
                        {
                    $jobIDs.Add($newJob.Id)
                    $jobid = $newJob.Id
                        }
 					$jobstat = "Initiated with the job ID $($jobid)"
                        
    If($AttemptCounter -eq 1)
            {
             $row = $Global:datatable.NewRow()
             $row.VM =  $vmname
             $row.RG = $vmrg
             $row.Location=$vmlocation
             $row.VMStatus=$Global:vmstatus                   
			 $row.JobID =  $jobid
             $row.JobStatus = $jobstat
             $Global:datatable.Rows.Add($row)
             }
             else
             {
             $Global:datatable | where{$_.VM -eq $vmname} | Foreach{$_.JobStatus=$jobstat}
             $Global:datatable | where{$_.VM -eq $vmname} | Foreach{$_.JobID=$jobid}
             $Global:datatable | where{$_.VM -eq $vmname} | Foreach{$_.VMStatus=$Global:vmstatus}
             }
             $newstatus = ($Global:datatable | where{$_.VM -eq $vmname} | Select JobStatus).JobStatus


               If($cmdleterror)
                         {
                         Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -VMName $vmname -Status $newstatus -Partition $Global:PartitionKey -Remarks "VM is ($Global:vmstatus);VM Agent is ($Global:agtstat);Error:$($cmdleterror)"
                         $cmdleterror.clear()
                         }
                        Else
                         {            
                       Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -VMName $vmname -Status $newstatus -Partition $Global:PartitionKey -Remarks "VM is ($Global:vmstatus);VM Agent is ($Global:agtstat)"
                        }
            }
If ($AttemptCounter -gt 1 -and $Global:VMFor2ndAttempt -notcontains $vmname )
    {
    $AttemptCounter+=1
    continue
    }
# getting all job ids into array
$jobsList = $jobIDs.ToArray()
Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -Status "Waiting for max 5 mins for background jobs to finish executing..." -Partition $Global:PartitionKey
[DateTime]$StartTime = Get-Date
# all values in seconds
$totalTimeToWait = 600
$timeWaited = 0
$recheckAfter = 10

do{
$runningjobs = Get-Job -Id $jobsList | where{ $_.State -ne "Completed"}

if(IsNull($runningjobs))
{
break
}

  ForEach($rj in $runningjobs)
  {
  
  $runningvm = ($Global:datatable | where{$_.JobID -match $rj.id} | Select VM).VM
  Write-Output $($runningvm + " > "+$rj.state)
   }

    Start-Sleep -Seconds $recheckAfter
    $timeWaited += $recheckAfter
} While ($timeWaited -lt $totalTimeToWait)

  ForEach($vm in $Global:datatable.rows)
  {
  $remark=""
If ($vm.jobid -ne "None")
                {
                  $job = Get-Job -Id $vm.jobid
                  $jobstate = [string]$Job.JobStateInfo.State
                 # Handling long running job, runs for more than 5 mins
                 [DateTime]$CurrentTime = Get-Date
                 $timelapsed = New-Timespan –Start $StartTime –End $CurrentTime
                 $longrunning = "Restart: "+$($vm.VM)+"/RG:"+$($vm.RG)+" is RESTARTED as RUN cmd executes for $(($timelapsed.TotalSeconds)/60) mins (exceeds 5 mins)"
                  If($jobstate -eq "Running" -and $($timelapsed.TotalSeconds) -ge 300 -and $AttemptCounter -eq 1)
                     {
                     Restart-AzVM -Name $vm.VM -ResourceGroupName $vm.RG -NoWait
                     $Global:VMFor2ndAttempt +=$vm.VM
                     Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -Status $longrunning -Partition $Global:PartitionKey
                     Email-Notification -Subject "$Global:RecoveryPlanName | $Task - error handling" -Body $longrunning 
					Switch-Subscription
                     }
                     elseif($jobstate -eq "Running" -and $($timelapsed.TotalSeconds) -ge 300 -and $AttemptCounter -gt 1)
                     {
                     Restart-AzVM -Name $vm.VM -ResourceGroupName $vm.RG -NoWait
                     Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -Status $longrunning -Partition $Global:PartitionKey
                     Email-Notification -Subject "$Global:RecoveryPlanName | $Task - error handling" -Body $longrunning
                     Switch-Subscription
                     $VMhasBug +=$VM
                     }
                  
                  If($AttemptCounter -eq 1)
                  {
                        if ($job.Error)
                        {
                 $runcmdstatus= "Thread job execution error"
                 $remark=[string]$job.Error
                 $body =  "error: $Task on $($vm.vm) has following error: $($runcmdstatus)"
                 Email-Notification -Subject "$Global:RecoveryPlanName | $Task - error" -Body $body -JobError $remark  
				Switch-Subscription
                 $Global:VMFor2ndAttempt +=$vm.VM
                 # Handling - existing run command exec is in progress
                     If($jobstate -eq "Completed" -and $remark -like "Run command extension execution is in progress*")
                     {
                     Restart-AzVM -Name $vm.VM -ResourceGroupName $vm.RG -NoWait
                     if(-not ($Global:VMFor2ndAttempt -contains $($vm.VM))) { $Global:VMFor2ndAttempt +=$vm.VM }
                     $longrunning = "Restart: "+$($vm.VM)+"/RG:"+$($vm.RG)+" is RESTARTED as Previous RUN cmd execution is still in progress"
                     Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -Status $longrunning -Partition $Global:PartitionKey
                     Email-Notification -Subject "$Global:RecoveryPlanName | $Task - error handling" -Body $longrunning -JobError $remark 
                     Switch-Subscription
                     }
                        }
                        Else
                        {
                  $runcmdstatus=[string]$job.output[0].value.message
                  $remark = "Provisioning State:"+$jobstate
                   if(IsNull($runcmdstatus)) { $runcmdstatus = "Job didn't complete within permitted time; has $remark" }
                      if(($remark -like "*failure*" -or $remark -like "*exception*"))
                      {
                      Restart-AzVM -Name $vm.VM -ResourceGroupName $vm.RG -NoWait
                      $Global:VMFor2ndAttempt +=$vm.VM
                      $failmsg = "Restart: "+$($vm.VM)+"/RG:"+$($vm.RG)+" is RESTARTED due to "+$remark
                      Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -Status $failmsg -Partition $Global:PartitionKey
                      Email-Notification -Subject "$Global:RecoveryPlanName | $Task - error handling" -Body $failmsg -JobError $remark 
					Switch-Subscription
                      }
               
                    }
                  }
  Else
                  {
                    if ($job.Error)
                        {
                 $runcmdstatus= "Thread job execution error"
                 $remark=[string]$job.Error
                 $body =  "error: $Task on $($vm.vm) has following error: $($runcmdstatus)"
                 Email-Notification -Subject "$Global:RecoveryPlanName | $Task - error" -Body $body -JobError $remark  
                 Switch-Subscription
                        }
                        else
                          { 
                          $runcmdstatus=[string]$job.output[0].value.message
                          $remark = "Provisioning State:"+$jobstate
                          if(IsNull($runcmdstatus)) { $runcmdstatus = "Job didn't complete within permitted time; has $remark" }
                          }
                    }

                       
                  }
  Else
                  {
                  $runcmdstatus = "Job could not start"
                  $remark = "Thread job creation failed"
                  }
Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -VMName $($vm.vm) -Status $runcmdstatus -Partition $Global:PartitionKey -Remarks $remark
Write-OutputAndLogTable -Table $Table -Task $Task -Runbook $Runbook -VMName $($vm.vm) -Status $runcmdstatus -Partition $Global:ValidationPartitionKey -Remarks $remark
                   If($AttemptCounter -eq 1)
                   {
                       $row = $jobiddatatable.NewRow()
                       $row.VM = $vm.vm
                       $row.'Update_Status' = $runcmdstatus
                       $jobiddatatable.Rows.Add($row)
                   }
                   else
                   {
                   $jobiddatatable | where{$_.VM -eq $($vm.vm)} | Foreach{$_.'Update_Status' = $runcmdstatus}
                   }
  }
  Email-Results -Subject "Attempt# $AttemptCounter > $Global:RecoveryPlanName | $Task"  -BodyMsgHeader "$Task Status" -DataTable $jobiddatatable
  Switch-Subscription
  $AttemptCounter += 1
}While($AttemptCounter -lt 3)
  
  }

Azure-Login
Import-Module AzureDR-Runbooks -DisableNameChecking -verbose

#$RecoveryPlanContext='{"RecoveryPlanName":"Non-Prod-1CApps-RP","FailoverType":"Unplanned","FailoverDirection":"SecondaryToPrimary","GroupId":"Group1","VmMap":{"636d62a4-e5ae-468e-ae79-8c33a85c702d":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVW002","RecoveryPointId":"90d07581-e85e-4590-84cf-005137be8505","RecoveryPointTime":"\/Date(1533304134358)\/"},"c2b475ef-98e8-42db-ad72-7968d0e97aeb":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVAPP01","RecoveryPointId":"4cb02374-0aa7-409d-a5df-5291d250f90d","RecoveryPointTime":"\/Date(1533304133572)\/"},"8c655371-dac6-4ab4-ba97-c18a70b2cf19":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVBJ01","RecoveryPointId":"24ceea9e-b4b4-40cb-b022-8407cc13f26e","RecoveryPointTime":"\/Date(1533304140219)\/"},"bd1346bf-7c34-4cca-b146-bb3dbf32b22c":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVAPP02","RecoveryPointId":"2ce5b077-23c0-4fa4-bbad-44637aeb66ba","RecoveryPointTime":"\/Date(1533304127134)\/"},"5026b044-5798-4ed1-b985-5245f5f07c40":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVW001","RecoveryPointId":"9d897302-e308-4b89-b2e2-58f3e33cf5a4","RecoveryPointTime":"\/Date(1533304149515)\/"}}}' | ConvertFrom-Json
#$RecoveryPlanContext='{"RecoveryPlanName":"Non-Prod-1CApps-RP","FailoverType":"Unplanned","FailoverDirection":"PrimaryToSecondary","GroupId":"Group1","VmMap":{"636d62a4-e5ae-468e-ae79-8c33a85c702d":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVW002","RecoveryPointId":"90d07581-e85e-4590-84cf-005137be8505","RecoveryPointTime":"\/Date(1533304134358)\/"},"c2b475ef-98e8-42db-ad72-7968d0e97aeb":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVAPP01","RecoveryPointId":"4cb02374-0aa7-409d-a5df-5291d250f90d","RecoveryPointTime":"\/Date(1533304133572)\/"},"8c655371-dac6-4ab4-ba97-c18a70b2cf19":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVBJ01","RecoveryPointId":"24ceea9e-b4b4-40cb-b022-8407cc13f26e","RecoveryPointTime":"\/Date(1533304140219)\/"},"bd1346bf-7c34-4cca-b146-bb3dbf32b22c":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVAPP02","RecoveryPointId":"2ce5b077-23c0-4fa4-bbad-44637aeb66ba","RecoveryPointTime":"\/Date(1533304127134)\/"},"5026b044-5798-4ed1-b985-5245f5f07c40":{"SubscriptionId":"5d8489a3-e9e7-464d-bf8b-9a0ba7f4a71f","ResourceGroupName":"ctsinpunrg01","CloudServiceName":null,"RoleName":"CTSINAZDEVW001","RecoveryPointId":"9d897302-e308-4b89-b2e2-58f3e33cf5a4","RecoveryPointTime":"\/Date(1533304149515)\/"}}}' | ConvertFrom-Json

If ($RecoveryPlanContext.GetType().FullName -eq "System.String") {
        $RecoveryPlanContext = $RecoveryPlanContext | ConvertFrom-Json
    } 

Initialize-Variables -FailoverDirection $RecoveryPlanContext.FailoverDirection -FailoverType $RecoveryPlanContext.FailoverType -RecoveryPlanName $RecoveryPlanContext.RecoveryPlanName

$AllVMListTableName = $AsrServersTable

$AllVMListTable = Get-Table -StorageTableName $AllVMListTableName
[Object]$AllVMList = Get-AzTableRow -Table $AllVMListTable

$StorageTableName = "ASRDRSCRIPTLOGS"
[Object]$Table = Get-Table -StorageTableName $StorageTableName

[String]$ColumnTask  =  "AD site name update" 
[String]$ColumnRunbook =  "ADSiteNameUpdate_v3.0"

Check-VM-Prequisite -Task $ColumnTask -Table $Table -AllVMList $AllVMList
AD-SiteNameUpdate -Task $ColumnTask -Runbook $ColumnRunbook -Table $Table -AllVMList $AllVMList

