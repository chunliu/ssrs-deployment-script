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
.PARAMETER dataSources
    The array of data sources.
#>

param(
    [String]$RSUri = "http://localhost/reportserver/",
    [String]$RPUri = "http://localhost/reports/",
    [String[]]$excludedFolders = @("CDR-Reports-Cube"),
    [hashtable[]]$dataSources = @(<#@{DsName="Galactic";ConnString="Data Source=10.0.0.5;Initial Catalog=Galactic";userName="username";password="password"}#>)
)

$dsFolderName = "DataSources"
$rtFolderName = "Reports"
$rtFolderPath = "/Reports"

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
            $dsPath = "$($rtFolderPath)/$($dsFolderName)/$($dsName)"
        } else {
            $dsPath = "$($rtFolderPath)/$($dsFolderName)/$($dsref.Name)"
        }
        $ds = Get-RsDataSource -Path $dsPath
        if($ds) {
            Write-Host "Update the data source reference for $($rsItem) to $($dsPath)"
            Set-RsDataSourceReference -Path $rsItem -DataSourceName $dsref.Name -DataSourcePath $dsPath
        } else {
            Write-Host "##vso[task.LogIssue type=warning;]/$($dsPath) doesn't exist!"
        }
    }
}

Function UpdateDSConnString {
    param(
        [string]$dsName
    )

    # Update connection string of the data sources
    foreach($dataSource in $dataSources) {
        if($dataSource.DsName -ne $dsName) {
            continue
        }

        $dsPath = "$($rtFolderPath)/$($dsFolderName)/$($dataSource.DsName)"
        Write-Host "Update the connection string of $($dataSource.DsName)"
        $ds = Get-RsDataSource -Path "$($rtFolderPath)/$($dsFolderName)/$($dataSource.DsName)"
        $ds.ConnectString = $dataSource.ConnString
        if($dataSource.userName) {
            $ds.CredentialRetrieval = "Store"
            $ds.UserName = $dataSource.userName
            $ds.Password = $dataSource.password
        }

        Set-RsDataSource -RsItem "$($rtFolderPath)/$($dsFolderName)/$($dataSource.DsName)" -DataSourceDefinition $ds
    }
}

# Initialize the connection
Connect-RsReportServer -ReportServerUri $RSUri -ReportPortalUri $RPUri

$rootFolder = Get-RsFolderContent -RsFolder "/" | Where {$_.Name -EQ $rtFolderName}
if(!$rootFolder) {
    New-RsFolder -RsFolder "/" -FolderName $rtFolderName
}

$serverReportFolders = Get-RsFolderContent -RsFolder $rtFolderPath | Select -ExpandProperty Name
$localReportFolders = Get-ChildItem -Path $PSScriptRoot -Directory | Select -ExpandProperty PSChildName

# Create data source folder
if($serverReportFolders -notcontains $dsFolderName) {
    Write-Host "Create data source folder"
    New-RsFolder -RsFolder $rtFolderPath -FolderName $dsFolderName -Hidden
}

foreach($rfName in $localReportFolders) {
    if($excludedFolders -contains $rfName) {
        continue
    }
    # Create report folder if it doesn't exist.
    if($serverReportFolders -notcontains $rfName) {
        Write-Host "Create folder $($rfName)"
        New-RsFolder -RsFolder $rtFolderPath -FolderName $rfName
    }

    # Upload the data source if it doesn't exist.
    $dss = Get-ChildItem -Path "$($PSScriptRoot)\$($rfName)" -File -Filter "*.rds"
    foreach($ds in $dss) {
        $ret = Get-RsFolderContent -RsFolder "$($rtFolderPath)/$($dsFolderName)" | Where Name -EQ $ds.BaseName
        if($ret.Count -eq 0) {
            Write-Host "Upload data source $($ds.Name)"
            Write-RsCatalogItem -Path $ds.FullName -RsFolder "$($rtFolderPath)/$($dsFolderName)"
            UpdateDSConnString $ds.BaseName
        }
    }

    # Upload shared datasets
    $rsds = Get-ChildItem -Path "$($PSScriptRoot)\$($rfName)" -File -Filter "*.rsd"
    foreach($rds in $rsds) {
        Write-Host "Upload shared datasets..."
        Write-RsCatalogItem -Path $rds.FullName -RsFolder "$($rtFolderPath)/$($rfName)" -Overwrite -Hidden

        [xml]$rdsxml = Get-Content $rds.FullName
        $dsName = $rdsxml.SharedDataSet.DataSet.Query.DataSourceReference
        if($dsName) {
            UpdateSharedDS "$($rtFolderPath)/$($rfName)/$($rds.BaseName)" $dsFolderName $dsName
        }
    }

    # Upload reports in this folder and overwrite the old version. 
    $reports = Get-ChildItem -Path "$($PSScriptRoot)\$($rfName)" -File -Filter "*.rdl"
    foreach($report in $reports) {
        # Upload reports
        Write-Host "Upload report $($report.Name) to folder $($rfName)"
        Write-RsCatalogItem -Path $report.FullName -RsFolder "$($rtFolderPath)/$($rfName)" -Overwrite
        # Update report's data source reference
        UpdateSharedDS "$($rtFolderPath)/$($rfName)/$($report.BaseName)" $dsFolderName
    }

    Write-Host "Reports have been deployed successfully!"
}