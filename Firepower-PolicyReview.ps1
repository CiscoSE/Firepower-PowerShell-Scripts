##
# Copyright (c) 2020 Cisco and/or its affiliates.
# 
# This software is licensed to you under the terms of the Cisco Sample
# Code License, Version 1.1 (the "License"). You may obtain a copy of the
# License at
# 
# 			   https://developer.cisco.com/docs/licenses
# 
# All use of the material herein must be in accordance with the terms of
# the License. All rights not expressly granted by the License are
# reserved. Unless required by applicable law or agreed to separately in
# writing, software distributed under the License is distributed on an "AS
# IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied.
##

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName PresentationFramework

$global:firepowerAccessToken = $null
$global:fmcDomainID = $null

$global:csvOutput = $null

$global:rateLimitSleep = 500

$windowCode = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:Firepower_Policy_Logging_Review"
        Title="Firepower Policy Logging Review" Height="745" Width="888.525" ResizeMode="NoResize">
        <Grid Height="741" VerticalAlignment="Top">
        <Button x:Name="getPolicyRules" Content="Get Policy Set Rules" HorizontalAlignment="Left" Margin="185,254,0,0" VerticalAlignment="Top" Width="157" Height="32" IsEnabled="False"/>
        <TextBox x:Name="textBox" HorizontalAlignment="Left" Height="31" Margin="10,10,0,0" TextWrapping="Wrap" VerticalAlignment="Top" Width="757" Text="https://"/>
        <ListView x:Name="listView" HorizontalAlignment="Left" Height="409" Margin="10,293,0,-183" VerticalAlignment="Top" Width="858" AutomationProperties.IsColumnHeader="True">
            <ListView.View>
                <GridView>
                    <GridViewColumn Header="ID" Width="50" DisplayMemberBinding="{Binding ID}"/>
                    <GridViewColumn Header="Rule Name" Width="300" DisplayMemberBinding="{Binding Name}"/>
                    <GridViewColumn Header="Rule Action" Width="100" DisplayMemberBinding="{Binding RuleAction}"/>
                    <GridViewColumn Header="Syslog" Width="100" DisplayMemberBinding="{Binding Syslog}"/>
                    <GridViewColumn Header="Log Beginning" Width="100" DisplayMemberBinding="{Binding LogBegin}"/>
                    <GridViewColumn Header="Log End" Width="100" DisplayMemberBinding="{Binding LogEnd}"/>
                    <GridViewColumn Header="FMC Eventing" Width="100" DisplayMemberBinding="{Binding LogFmc}"/>
                </GridView>
            </ListView.View>
        </ListView>
        <Button x:Name="getAccessPolicies" Content="Get Access Policies" HorizontalAlignment="Left" Height="32" Margin="10,254,0,0" VerticalAlignment="Top" Width="157" IsEnabled="False"/>
        <ListBox x:Name="listBox" HorizontalAlignment="Left" Height="203" Margin="10,46,0,0" VerticalAlignment="Top" Width="858"/>
        <Label x:Name="lblRuleCount" Content="" HorizontalAlignment="Left" Height="32" Margin="486,254,0,0" VerticalAlignment="Top" Width="382" FontSize="16"/>
        <Button x:Name="btnLogin" Content="Login" HorizontalAlignment="Left" Height="31" Margin="780,10,0,0" VerticalAlignment="Top" Width="88"/>
        <Button x:Name="btnSaveCSV" Content="Export as CSV" HorizontalAlignment="Left" Height="32" Margin="711,254,0,0" VerticalAlignment="Top" Width="157" IsEnabled="False"/>
    </Grid>
</Window>
'@

$inputXML = $windowCode -replace 'mc:Ignorable="d"', '' -replace "x:N", 'N'
[XML]$XAML = $inputXML

#Read XAML
$reader = (New-Object System.Xml.XmlNodeReader $XAML)
try {
    $window = [Windows.Markup.XamlReader]::Load( $reader )
} catch {
    Write-Warning $_.Exception
    throw
}

#Create ArrayList to hold available Access Control Policies
$acpList = New-Object System.Collections.ArrayList

#Create variables for dialog control
$XAML.SelectNodes("//*[@Name]") | ForEach-Object {
    try {
        Set-Variable -Name "variable_$($_.Name)" -Value $window.FindName($_.Name) -ErrorAction Stop
    } catch {
        throw
    }
}

#Login Process to FMC
$variable_btnLogin.Add_Click( {
    $fmcUrl = $variable_textBox.Text

    $cred = Get-Credential
    
    $pair = "$($cred.UserName):$($cred.GetNetworkCredential().password)"

    $encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))

    $basicAuthValue = "Basic $encodedCreds"

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", $basicAuthValue)
 
    $variable_getAccessPolicies.IsEnabled = $true

    $result = try {
        $authTokenRequest = Invoke-WebRequest "$fmcUrl/api/fmc_platform/v1/auth/generatetoken" -Headers $headers -Method POST
        
        $global:firepowerAccessToken = $authTokenRequest.Headers.Item('X-auth-access-token')
        $global:fmcDomainID = $authTokenRequest.Headers.Item('DOMAIN_UUID')

        $variable_getAccessPolicies.IsEnabled = $true

        $variable_btnLogin.Content = "Logged In"

        $variable_btnLogin.IsEnabled = $false
        
        $variable_textBox.IsEnabled = $false

    } catch {
        [System.Windows.MessageBox]::Show("Failure to login to the FMC") 
    } 
})

#Get FMC Access Policies from FMC
$variable_getAccessPolicies.Add_Click( { 
    
    if($global:firepowerAccessToken -ne $null){
        $fmcUrl = $variable_textBox.Text

        $variable_listBox.Items.Clear()

        $requestLimit = 100
   
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add("X-auth-access-token", $global:firepowerAccessToken)

        $acpRecords = Invoke-WebRequest "$fmcUrl/api/fmc_config/v1/domain/$global:fmcDomainID/policy/accesspolicies?limit=$requestLimit" -Headers $headers -Method GET -ContentType 'application/json'

        $jsonContent = ConvertFrom-Json $acpRecords.Content
    
        $itemCount = $jsonContent.paging.count

        $nextUrl = $jsonContent.paging.next
    
        $totalPages = $jsonContent.paging.pages

        $variable_lblRuleCount.Content = "Total Access Policies Count: $($itemCount)"

        $rulecount = 0
    
        for (($page = 0); $page -lt $totalPages; $page++)
        {

            $offset = $page * $requestLimit
    
            $acpRecords = Invoke-WebRequest "$fmcUrl/api/fmc_config/v1/domain/$global:fmcDomainID/policy/accesspolicies?limit=$requestLimit&offset=$offset" -Headers $headers -Method GET -ContentType 'application/json'
        
            $jsonContent = ConvertFrom-Json $acpRecords.Content
    
            foreach ($record in $jsonContent.items)
            {
               $variable_listBox.Items.Add($record.name)
               $acpList.Add($record.id)

            }
        }

        $variable_getPolicyRules.IsEnabled = $true
    }else{
        [System.Windows.MessageBox]::Show("Please login to FMC")
    }
})

#Get FMC Access Policy Rules from FMC
$variable_getPolicyRules.Add_Click( {

    if($global:firepowerAccessToken -ne $null){

        $fmcUrl = $variable_textBox.Text
        
        $global:csvOutput = "Rule-ID,Rule-Name,RuleAction,Syslog,Log-Beginning,Log-End,FMC-Eventing`r`n"

        $variable_listView.Items.Clear()

        $requestLimit = 100

        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add("X-auth-access-token", $global:firepowerAccessToken)

        $result = Invoke-WebRequest "$fmcUrl/api/fmc_config/v1/domain/$global:fmcDomainID/policy/accesspolicies/$($acpList[$variable_listBox.SelectedIndex])/accessrules?limit=$requestLimit" -Headers $headers -Method GET -ContentType 'application/json'

        $jsonContent = ConvertFrom-Json $result.Content
    
        $itemCount = $jsonContent.paging.count

        $nextUrl = $jsonContent.paging.next
    
        $totalPages = $jsonContent.paging.pages

        $rulecount = 1

        $variable_lblRuleCount.Content = "Total Rule Count: $($itemCount)"

        for (($page = 0); $page -lt $totalPages; $page++)
        {

            $offset = $page * $requestLimit
    
            $result = Invoke-WebRequest "$fmcUrl/api/fmc_config/v1/domain/$global:fmcDomainID/policy/accesspolicies/$($acpList[$variable_listBox.SelectedIndex])/accessrules?limit=$requestLimit&offset=$offset" -Headers $headers -Method GET -ContentType 'application/json'
    
            $jsonContent = ConvertFrom-Json $result.Content
    
            foreach ($record in $jsonContent.items)
            {
               $ruleUrl = $record.links.self

               $ruleResult = Invoke-WebRequest "$ruleUrl" -Headers $headers -Method GET -ContentType 'application/json'

               $jsonRule = ConvertFrom-Json $ruleResult.Content

               $variable_listView.Items.Add([pscustomobject]@{ID="$($ruleCount)";Name="$($record.name)";RuleAction="$($jsonRule.action)";Syslog="$($jsonRule.enableSyslog)";LogBegin="$($jsonRule.logBegin)";LogEnd="$($jsonRule.logEnd)";LogFmc="$($jsonRule.sendEventsToFMC)"})

               $global:csvOutput = $global:csvOutput + "$ruleCount,$($record.name),$($jsonRule.action),$($jsonRule.enableSyslog),$($jsonRule.logBegin),$($jsonRule.logEnd),$($jsonRule.sendEventsToFMC)`r`n"

               $ruleCount = $ruleCount + 1

               #Delay the process to ensure we do not exceed the API Rate Limit
               Start-Sleep -Milliseconds $global:rateLimitSleep
            }
        }

        $variable_btnSaveCSV.IsEnabled = $true
    }else{
        [System.Windows.MessageBox]::Show("Please login to FMC")
    }
})

#Save last Access Control Policy Rule output as CSV
$variable_btnSaveCSV.Add_Click( {

    [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null

    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.filter = "CSV Files (*.csv)| *.csv"

    if($saveDialog.ShowDialog() -eq 'Ok'){
        Out-File -FilePath $saveDialog.filename -InputObject $global:csvOutput -Encoding ASCII
        Write-host "Saved CSV Data to file: $($saveDialog.filename)"
    }
})

#Load the Dialog Window
$Null = $window.ShowDialog()
