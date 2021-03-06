# Load dependent modules
if (!(Get-Module ".\DotNetDeployment.psm1")) { 
    Import-Module ".\DotNetDeployment.psm1" -ErrorAction Stop
}

# Iteratates over all "_package" folders in a given folder and attempts to deploy them to the locations defined in the supplied configuration file.
function DeployAllPackages {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The root folder containing all of the '_package' folders to be deployed.")]
		[System.IO.DirectoryInfo]$packageRoot,		
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the configuration .xml file containing how and where to deploy the package files.")]
		[System.IO.FileInfo]$configFile
	)
	
	if (!(Test-Path -Path $packageRoot)) {
		throw "Unable to resolve $($packageRoot)"
	}

	if (!(Test-Path -Path $configFile)) {
		throw "Unable to resolve $($configFile)"
	}

	[xml]$xml = Get-Content $configFile

	$packages = Get-ChildItem $packageRoot -Filter "*_package"
	foreach($package in $packages) {
		$packageNode = $xml.SelectSingleNode("//Application[PackageFolderName='$($package.Name)']")
		
		if ($packageNode -eq $null) {
			"Package $($package.Name) is not defined in the configuration file!"
			continue
		}
		
		$servers = @()
		$servers = $packageNode.Deployment.Servers.SelectNodes("Server")
		$packageFile = Get-ChildItem $package.FullName -Filter "*.zip"
		
		foreach($server in $servers) {		
			"Deploying $($packageNode.Name) as $($packageNode.Deployment.DeploymentType) to $($server.Name)!" 
			switch($packageNode.Deployment.DeploymentType) 
			{
				"WebApplication"  
				{ 
					if ($server.Username -ne $null) {
						# Check for deployment using Username/Password
						if (ShouldDeployDotNetWebApplication $packageFile.FullName $server.Name $server.SiteName $server.InstallationPath -userName $server.Username -password $server.Password) {
							if ($server.GWUserKeePassTitle -eq $null) {
								# Deploy using Userid/Password only
								DeployDotNetWebApplication $packageFile.FullName $server.Name $server.SiteName $server.InstallationPath -userName $server.Username -password $server.Password
							}
							else {
								# Deploy using Userid/Password and GWUser Name and Password
								DeployDotNetWebApplication $packageFile.FullName $server.Name $server.SiteName $server.InstallationPath -userName $server.Username -password $server.Password -guideWireUserKeePassGroup $server.GWUserKeePassGroup -guideWireUserKeePassTitle $server.GWUserKeePassTitle
							}
						}
						else {
							"No changes were identified by comparing package $($packageNode.Name) vs. $($server.Name).  The package will not be deployed!"
						}
					}
					else {
						# Check for deployment using KeePassGroup/KeePassTitle
						if (ShouldDeployDotNetWebApplication $packageFile.FullName $server.Name $server.SiteName $server.InstallationPath -keePassGroup $server.KeePassGroup -keePassTitle $server.KeePassTitle) {
							if ($server.GWUserKeePassTitle -eq $null) {
								# Deploy using KeePassGroup/KeePassTitle only
								DeployDotNetWebApplication $packageFile.FullName $server.Name $server.SiteName $server.InstallationPath -keePassGroup $server.KeePassGroup -keePassTitle $server.KeePassTitle
							}
							else {
								# Deploy using KeePassGroup/KeePassTitle and GWUser Name and Password
								DeployDotNetWebApplication $packageFile.FullName $server.Name $server.SiteName $server.InstallationPath -keePassGroup $server.KeePassGroup -keePassTitle $server.KeePassTitle -guideWireUserKeePassGroup $server.GWUserKeePassGroup -guideWireUserKeePassTitle $server.GWUserKeePassTitle
							}
						}
						else {
							"No changes were identified by comparing package $($packageNode.Name) vs. $($server.Name).  The package will not be deployed!"
						}
					}
				}
				"WindowsServiceApplication" 
				{ 
					if (ShouldDeployDotNetApplication $packageFile.FullName $server.Name) {
						$automaticStart = IsAutomaticStart $server.ServiceStartUp
						"The ServiceStartUp parameter indicates that service automatic startup is $($automaticStart)"
						if ($server.Username -ne $null) {
							# Deploy using Userid/Password
							DeployDotNetWindowsService $packageFile.FullName $server.Name $server.ServiceName -userName $server.Username -password $server.Password -automaticStart $automaticStart
						}
						else {
							# Deploy using KeePassGroup/KeePassTitle
							DeployDotNetWindowsService $packageFile.FullName $server.Name $server.ServiceName -keePassGroup $server.KeePassGroup -keePassTitle $server.KeePassTitle -automaticStart $automaticStart
						}
					}
					else {
						"No changes were identified by comparing package $($packageNode.Name) vs. $($server.Name).  The package will not be deployed!"
					}
				}
				"NServiceBusWindowsServiceApplication" 
				{ 
					if (ShouldDeployDotNetApplication $packageFile.FullName $server.Name) {
						$automaticStart = IsAutomaticStart $server.ServiceStartUp
						"The ServiceStartUp parameter indicates that service automatic startup is $($automaticStart)"
						if ($server.Username -ne $null) {
							# Deploy using Userid/Password
							DeployNServiceBusWindowsService $packageFile.FullName $server.Name $server.ServiceName -userName $server.Username -password $server.Password -automaticStart $automaticStart
						}
						else {
							# Deploy using KeePassGroup/KeePassTitle
							DeployNServiceBusWindowsService $packageFile.FullName $server.Name $server.ServiceName -keePassGroup $server.KeePassGroup -keePassTitle $server.KeePassTitle -automaticStart $automaticStart
						}
					}
					else {
						"No changes were identified by comparing package $($packageNode.Name) vs. $($server.Name).  The package will not be deployed!"
					}
				}
				"ConsoleApplication" 
				{ 
					if (ShouldDeployDotNetApplication $packageFile.FullName $server.Name) {
						if ($server.Username -ne $null) {
							# Deploy using Userid/Password
							DeployDotNetConsoleApp $packageFile.FullName $server.Name -userName $server.Username -password $server.Password
						}
						else {
							DeployDotNetConsoleApp $packageFile.FullName $server.Name -keePassGroup $server.KeePassGroup -keePassTitle $server.KeePassTitle
						}
					}
					else {
						"No changes were identified by comparing package $($packageNode.Name) vs. $($server.Name).  The package will not be deployed!"
					}
				}
				default { "Skipping $($package.Name)" }
			}
		}
	}
}

Function IsAutomaticStart {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The ServiceStartUp Xml Element.")]
		[AllowEmptyString()]
		[string]$element
	)
	$hasValue = (($server.ServiceStartUp -ne $null) -and ($server.ServiceStartUp.Length -gt 0))
	
	return ((($hasValue -eq $true) -and ($server.ServiceStartUp.ToUpper() -ne "MANUAL")) -or ($hasValue -eq $false))
}

# Function to open a Folder Dialog 
# NOTE:  Only works when invoked from a powershell session with the -STA flag
Function Get-FolderName() {   
	Add-Type -AssemblyName System.Windows.Forms
	$OpenFolderDialog = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{
		SelectedPath = "C:\"
	}

	[void]$OpenFolderDialog.ShowDialog()
	$OpenFolderDialog.SelectedPath 
}

# Function to open a File Dialog 
# NOTE:  Only works when invoked from a powershell session with the -STA flag
Function Get-FileName {   
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The start path for the file dialog")]
		[string]$initialDirectory
	)
	[System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null

	$OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
	$OpenFileDialog.initialDirectory = $initialDirectory
	$OpenFileDialog.filter = "All files (*.*)| *.*"
	$OpenFileDialog.ShowHelp = $true;
	$OpenFileDialog.ShowDialog() | Out-Null
	$OpenFileDialog.filename
} 

Function DeployPackages {
	$folder = Get-FolderName
	$configFile = Get-FileName "c:\"
	
	DeployAllPackages $folder $configFile
}
