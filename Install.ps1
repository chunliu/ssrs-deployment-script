<#
.SYNOPSIS
    Deploy all reports to SSRS server.
.DESCRIPTION
    This is a script to automate the deployment of SSRS reports.
.PARAMETER RSUri
    The Uri of the report server. 
.PARAMETER RPUri
    The Uri of the report server portal.
.PARAMETER excludedFolders
    The folders that need to be ignored.
.NOTES
    Author: Chun Liu
    Version: 0.1
.EXAMPLE
    .\Install.ps1 -RSUri "http://localhost/reportserver/" -RPUri "http://localhost/reports/"
#>

param(
    [Parameter(Mandatory=$false)][String]$RSUri = "http://localhost/reportserver/",
    [Parameter(Mandatory=$false)][String]$RPUri = "http://localhost/reports/",
    [Parameter(Mandatory=$false)][String[]]$excludedFolders = @()
)

$dsFolderName = "DataSources"

if(-not (Get-Module -Name "ReportingServicesTools" -ListAvailable)) {
    Invoke-Expression (Invoke-WebRequest https://raw.githubusercontent.com/Microsoft/ReportingServicesTools/master/Install.ps1)
}

# Update the shared data source for report or dataset
Function UpdateSharedDS {
    param(
        [string]$rsItem, 
        [string]$dsFolderName,
        [AllowNull()][string]$dsName
    )

    $dsrefs = Get-RsItemDataSource -RsItem $rsItem
    foreach($dsref in $dsrefs) {
        if($dsName) {
            $dsPath = "/$($dsFolderName)/$($dsName)"
        } else {
            $dsPath = "/$($dsFolderName)/$($dsref.Name)"
        }
        $ds = Get-RsDataSource -Path $dsPath -ErrorAction SilentlyContinue
        if($ds) {
            Write-Host "Update the data source reference for $($rsItem) to $($dsPath)"
            Set-RsDataSourceReference -Path $rsItem -DataSourceName $dsref.Name -DataSourcePath $dsPath
        } else {
            Write-Host "##vso[task.LogIssue type=warning;]/$($dsPath) doesn't exist!"
        }
    }
}

# Initialize the connection
Connect-RsReportServer -ReportServerUri $RSUri -ReportPortalUri $RPUri

$serverReportFolders = Get-RsFolderContent -RsFolder "/" | Select -ExpandProperty Name
$localReportFolders = Get-ChildItem -Path $PSScriptRoot -Directory | Select -ExpandProperty PSChildName

# Create data source folder
if($serverReportFolders -notcontains $dsFolderName) {
    Write-Host "Create data source folder"
    New-RsFolder -RsFolder "/" -FolderName $dsFolderName -Hidden
}

foreach($rfName in $localReportFolders) {
    if($excludedFolders -contains $rfName) {
        continue
    }
    # Create report folder if it doesn't exist.
    if($serverReportFolders -notcontains $rfName) {
        Write-Host "Create folder $($rfName)"
        New-RsFolder -RsFolder "/" -FolderName $rfName
    }

    # Upload the data source if it doesn't exist.
    $dss = Get-ChildItem -Path "$($PSScriptRoot)\$($rfName)" -File -Filter "*.rds"
    foreach($ds in $dss) {
        $ret = Get-RsFolderContent -RsFolder "/$($dsFolderName)" | Where Name -EQ $ds.BaseName
        if($ret.Count -eq 0) {
            Write-Host "Upload data source $($ds.Name)"
            Write-RsCatalogItem -Path $ds.FullName -RsFolder "/$($dsFolderName)"
        }
    }

    # Upload shared datasets
    $rsds = Get-ChildItem -Path "$($PSScriptRoot)\$($rfName)" -File -Filter "*.rsd"
    foreach($rds in $rsds) {
        Write-Host "Upload shared datasets..."
        Write-RsCatalogItem -Path $rds.FullName -RsFolder "/$($rfName)" -Overwrite -Hidden

        [xml]$rdsxml = Get-Content $rds.FullName
        $dsName = $rdsxml.SharedDataSet.DataSet.Query.DataSourceReference
        if($dsName) {
            UpdateSharedDS "/$($rfName)/$($rds.BaseName)" $dsFolderName $dsName
        }
    }

    # Upload reports in this folder and overwrite the old version. 
    $reports = Get-ChildItem -Path "$($PSScriptRoot)\$($rfName)" -File -Filter "*.rdl"
    foreach($report in $reports) {
        # Upload reports
        Write-Host "Upload report $($report.Name) to folder $($rfName)"
        Write-RsCatalogItem -Path $report.FullName -RsFolder "/$($rfName)" -Overwrite
        # Update report's data source reference
        UpdateSharedDS "/$($rfName)/$($report.BaseName)" $dsFolderName
    }

    Write-Host "Reports have been deployed successfully!"
}