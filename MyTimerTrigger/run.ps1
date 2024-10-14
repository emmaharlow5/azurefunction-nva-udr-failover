#-------------------------------------------------------------------------
#
# Copyright (c) Microsoft.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#--------------------------------------------------------------------------
#
# High Availability (HA) Network Virtual Appliance (vMX) Failover Function
#
# This script provides a sample for monitoring HA vMX firewall status and performing
# failover and/or failback if needed.
#
# This script is used as part of an Azure function app called by a Timer Trigger event.  
#
# To configure this function app, the following items must be setup:
#
#   - Provision the pre-requisite Azure Resource Groups, Virtual Networks and Subnets, Network Virtual Appliances
#
#   - Create an Azure timer function app
#
#   - Set the Azure function app settings with credentials
#     SP_PASSWORD, SP_USERNAME, TENANTID, SUBSCRIPTIONID, AZURECLOUD must be added
#     AZURECLOUD = "AzureCloud" or "AzureUSGovernment"
#
#   - Set Firewall VM names and Resource Group in the Azure function app settings
#     vMX1NAME, vMX2NAME, FWMONITOR, vMX1FQDN, vMX1PORT, vMX2FQDN, vMX2PORT, vMX1RGNAME, vMX2RGNAME, FWTRIES, FWDELAY, FWUDRTAG must be added
#     FWMONITOR = "VMStatus" or "TCPPort" - If using "TCPPort", then also set vMX1FQDN, vMX2FQDN, vMX1PORT and vMX2PORT values
#
#   - Set Timer Schedule where positions represent: Seconds - Minutes - Hours - Day - Month - DayofWeek
#     Example:  "*/30 * * * * *" to run on multiples of 30 seconds
#     Example:  "0 */5 * * * *" to run on multiples of 5 minutes on the 0-second mark
#
#--------------------------------------------------------------------------
#$VerbosePreference = 'Continue'
param($myTimer)
Write-Verbose "HA vMX timer trigger function executed at:$(Get-Date)"

#--------------------------------------------------------------------------
# Set firewall monitoring variables here
#--------------------------------------------------------------------------

$VMVMX1Name = $env:VMVMX1Name
$VMVMX2Name = $env:VMVMX2Name
$VMX1RGName = $env:VMX1RGName
$VMX2RGName = $env:VMX2RGName
$Monitor = $env:VMXMONITOR
$VMXUDRTAG = $env:VMXUDRTAG
$SubscriptionID = $env:SUBSCRIPTIONID


# #--------------------------------------------------------------------------
# # The parameters below are required if using "TCPPort" mode for monitoring
# #--------------------------------------------------------------------------


# #--------------------------------------------------------------------------
# # Set the failover and failback behavior for the firewalls
# #--------------------------------------------------------------------------

$FailOver = $True              # Trigger to enable fail-over to secondary vMX firewall if primary vMX firewall drops when active
$FailBack = $True              # Trigger to enable fail-back to primary vMX firewall is secondary vMX firewall drops when active
$IntTries = $env:VMXTRIES       # Number of Firewall tests to try 
$IntSleep = $env:VMXDELAY       # Delay in seconds between tries

# #--------------------------------------------------------------------------
# # Code blocks for supporting functions
# #--------------------------------------------------------------------------



Function Test-VMStatus ($VM, $FWResourceGroup) {
  try {
    $VMDetail = Get-AzVM -ResourceGroupName $FWResourceGroup -Name $VM -Status -ErrorAction Stop
    foreach ($VMStatus in $VMDetail.Statuses) { 
      $Status = $VMStatus.code
      
      if ($Status.CompareTo('PowerState/running') -eq 0) {
        Return $False
      }
    }
    Return $True
  }
  catch {
    Write-Error "Failed to retrieve Virtual Machines from subscription - $SubscriptionID"
    throw "Error: $($_.Exception.Message)"
  }
}

Function Test-TCPPort ($Server, $Port) {
  $TCPClient = New-Object -TypeName system.Net.Sockets.TcpClient
  $Iar = $TCPClient.BeginConnect($Server, $Port, $Null, $Null)
  $Wait = $Iar.AsyncWaitHandle.WaitOne(1000, $False)
  return $Wait
}

Function Start-Failover {
  Write-Verbose "Starting Failover to vMX2"
  $RTable = @()
  $TagValue = $VMXUDRTAG # $env:VMXUDRTAG Update in Live
  try {
    $Res = Get-AzResource -TagName nva-ha-udr -TagValue $TagValue -ErrorAction Stop
  }
  catch {
    Write-Error "Failed to retrieve Route Tables from subscription - $SubscriptionID"
    throw "Error: $($_.Exception.Message)"
  }
  $x = 0

  if ($Res.count -eq 0) {
    Write-Verbose "No Route tables found matching tag in subscription $SubscriptionID"
  }
  else {

    foreach ($RTable in $Res) {
      try {
        $Table = Get-AzRouteTable -ResourceGroupName $RTable.ResourceGroupName -Name $RTable.Name -ErrorAction Stop
      }
      catch {
        Write-Error "Failed to retrieve Routes from $($RTable.Name)"
        throw "Error: $($_.Exception.Message)"
      }
      $RouteList = @($Table.Routes)
      foreach ($RouteName in $RouteList) {
        Write-Verbose "Checking route table $($RouteName.Name)"

        for ($i = 0; $i -lt $PrimaryInts.count; $i++) {
          if ($RouteName.NextHopIpAddress -eq $SecondaryInts[$i]) {
            Write-Verbose 'Secondary vMX is already ACTIVE' 
            
          }
          elseif ($RouteName.NextHopIpAddress -eq $PrimaryInts[$i]) {
            try {
              Set-AzRouteConfig -Name $RouteName.Name  -NextHopType VirtualAppliance -RouteTable $Table -AddressPrefix $RouteName.AddressPrefix -NextHopIpAddress $SecondaryInts[$i] -ErrorAction Stop | out-null
            }
            catch {
              Write-Error "Failed to update Route $($RouteName.Name)"
              throw "Error: $($_.Exception.Message)"
            }
            Write-Verbose 'Secondary vMX is now ACTIVE'
            $x++
          }
        }

      }
      try {
        $UpdateTable = [scriptblock] { param($Table) Set-AzRouteTable -RouteTable $Table -ErrorAction Stop }
        &$UpdateTable $Table | out-null  
      }
      catch {
        Write-Error "Failed to update routes in Route Table $($Table.Name)"
        throw "Error: $($_.Exception.Message)"
      }

    }
  
    if ($x -ge 1) { Write-Output -InputObject "Route tables failed over to vMX2 *This should raise an alert*" } else { Write-Verbose "Route tables already failed over to vMX2 - No action is required" }
  }

}

Function Start-Failback {
    
  Write-Verbose "Starting Failover to vMX1"
  $RTable = @()
  $TagValue = $VMXUDRTAG # $env:VMXUDRTAG Update in Live
  try {
    $Res = Get-AzResource -TagName nva-ha-udr -TagValue $TagValue -ErrorAction Stop
  }
  catch {
    Write-Error "Failed to retrieve Route Tables from subscription - $SubscriptionID"
    throw "Error: $($_.Exception.Message)"
  }
  $x = 0

  if ($Res.count -eq 0) {
    Write-Verbose "No Route tables found in subscription $SubscriptionID"
  }
  else {

    foreach ($RTable in $Res) {
      try {
        $Table = Get-AzRouteTable -ResourceGroupName $RTable.ResourceGroupName -Name $RTable.Name -ErrorAction Stop
      }
      catch {
        Write-Error "Failed to retrieve Routes from $($RTable.Name)"
        throw "Error: $($_.Exception.Message)"
      }
      $RouteList = @($Table.Routes)
      foreach ($RouteName in $RouteList) {
        Write-Verbose "Checking route table $($RouteName.Name)"

        for ($i = 0; $i -lt $PrimaryInts.count; $i++) {
          if ($RouteName.NextHopIpAddress -eq $PrimaryInts[$i]) {
            Write-Verbose 'Primary vMX is already ACTIVE' 
          
          }
          elseif ($RouteName.NextHopIpAddress -eq $SecondaryInts[$i]) {
            try {
              Set-AzRouteConfig -Name $RouteName.Name  -NextHopType VirtualAppliance -RouteTable $Table -AddressPrefix $RouteName.AddressPrefix -NextHopIpAddress $PrimaryInts[$i] -ErrorAction Stop | out-null
            }
            catch {
              Write-Error "Failed to update Route $($RouteName.Name)"
              throw "Error: $($_.Exception.Message)"
            }
            Write-Verbose 'Primary vMX is now ACTIVE'
            $x++
          }  
        }

      }  

      $UpdateTable = [scriptblock] { param($Table) Set-AzRouteTable -RouteTable $Table -ErrorAction Stop }
      &$UpdateTable $Table | out-null  
    }
    catch {
      Write-Error "Failed to update routes in Route Table $($Table.Name)"
      throw "Error: $($_.Exception.Message)"
    }

  }

  if ($x -ge 1) { Write-Output -InputObject "Route tables failed over to vMX2 *This should raise an alert*" } else { Write-Verbose "Route tables already failed over to vMX1 - No action is required" }
}  


Function Get-FWInterfaces {
  try {
    $Nics = Get-AzNetworkInterface | Where-Object -Property VirtualMachine -NE -Value $Null -ErrorAction Stop  
  }
  catch {
    Write-Error "Failed to retrieve Network Interfaces from subscription $SubscriptionID"
    throw "Error: $($_.Exception.Message)"
  }
  try {
    $VMS1 = Get-AzVM -Name $VMvMX1Name -ResourceGroupName $vMX1RGName -ErrorAction Stop  
  }
  catch {
    Write-Error "Failed to retrieve Virtual Machine $VMvMX1Name from subscription $SubscriptionID"
    throw "Error: $($_.Exception.Message)"
  }
  try {
    $VMS2 = Get-AzVM -Name $VMvMX2Name -ResourceGroupName $vMX2RGName -ErrorAction Stop  
  }
  catch {
    Write-Error "Failed to retrieve Virtual Machine $VMvMX2Name from subscription $SubscriptionID"
    throw "Error: $($_.Exception.Message)"
  }

  foreach ($Nic in $Nics) {

    if (($Nic.VirtualMachine.Id -EQ $VMS1.Id) -Or ($Nic.VirtualMachine.Id -EQ $VMS2.Id)) {
      $VM = $VMS | Where-Object -Property Id -EQ -Value $Nic.VirtualMachine.Id
      $Prv = $Nic.IpConfigurations | Select-Object -ExpandProperty PrivateIpAddress

      if ($VM.Name -eq $VMvMX1Name) {
        $Script:PrimaryInts += $Prv
      }
      elseif ($VM.Name -eq $vmvMX2Name) {
        $Script:SecondaryInts += $Prv
      }
    }

  }
}

# #--------------------------------------------------------------------------
# # Main code block for Azure function app                       
# #--------------------------------------------------------------------------

# #$Password = ConvertTo-SecureString $env:SP_PASSWORD -AsPlainText -Force
# #$Credential = New-Object System.Management.Automation.PSCredential ($env:SP_USERNAME, $Password)
# #$AzureEnv = Get-AzEnvironment -Name $env:AZURECLOUD
# #Add-AzAccount -ServicePrincipal -Tenant $env:TENANTID -Credential $Credential -SubscriptionId $env:SUBSCRIPTIONID -Environment $AzureEnv

# #$Context = Get-AzContext
# #Set-AzContext -Context $Context

# #--------------------------------------------------------------------------
# # Use Managed Identity                   
# #--------------------------------------------------------------------------

Connect-AzAccount -Identity | out-null

$Script:PrimaryInts = @()
$Script:SecondaryInts = @()
$Script:ListOfSubscriptionIDs = @()

# Check vMX firewall status $intTries with $intSleep between tries

$CtrvMX1 = 0
$CtrvMX2 = 0
$vMX1Down = $True
$vMX2Down = $True

try {
  $VMS = Get-AzVM -ErrorAction Stop  
}
catch {
  Write-Error "Failed to retrieve Virtual Machines from subscription $SubscriptionID"
  throw "Error: $($_.Exception.Message)"
}

#Get-Subscriptions
try {
  Set-AzContext -SubscriptionId $SubscriptionID -ErrorAction Stop | out-null 
}
catch {
  Write-Error "Failed to set Context to $SubscriptionID"
  throw "Error: $($_.Exception.Message)"
}
Get-FWInterfaces

# $PrimaryInts

# Test primary and secondary vMX firewall status 

For ($Ctr = 1; $Ctr -le $IntTries; $Ctr++) {
  
  if ($Monitor -eq 'VMStatus') {
    $vMX1Down = Test-VMStatus -VM $VMvMX1Name -FwResourceGroup $vMX1RGName
    $vMX2Down = Test-VMStatus -VM $VMvMX2Name -FwResourceGroup $vMX2RGName
  }

  if ($Monitor -eq 'TCPPort') {
    $vMX1Down = -not (Test-TCPPort -Server $TCPvMX1Server -Port $TCPvMX1Port)
    $vMX2Down = -not (Test-TCPPort -Server $TCPvMX2Server -Port $TCPvMX2Port)
  }

  Write-Verbose "Pass $Ctr of $IntTries - vMX1Down is $vMX1Down, vMX2Down is $vMX2Down"

  if ($vMX1Down) {
    $CtrvMX1++
  }

  if ($vMX2Down) {
    $CtrvMX2++
  }

  Write-Verbose "Sleeping $IntSleep seconds"
  Start-Sleep $IntSleep
}

# Reset individual test status and determine overall vMX firewall status

$vMX1Down = $False
$vMX2Down = $False

if ($CtrvMX1 -eq $intTries) {
  $vMX1Down = $True
}

if ($CtrvMX2 -eq $intTries) {
  $vMX2Down = $True
}

# Failover or failback if needed

if (($vMX1Down) -and -not ($vMX2Down)) {
  if ($FailOver) {
    Write-Verbose 'vMX1 Down - Failing over to vMX2'
    Start-Failover 
  }
}
elseif (-not ($vMX1Down) -and ($vMX2Down)) {
  if ($FailBack) {
    Write-Verbose 'vMX2 Down - Failing back to vMX1'
    Start-Failback
  }
  else {
    Write-Verbose 'vMX2 Down - Failing back disabled'
  }
}
elseif (($vMX1Down) -and ($vMX2Down)) {
  Write-Output -InputObject 'Both vMX1 and vMX2 Down - Manual recovery action required *This should raise an alert*'
}
else {
  Write-Verbose 'Both vMX1 and vMX2 Up - No action is required'
}
