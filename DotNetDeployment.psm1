# Load dependent modules
if (!(Get-Module ".\WindowsServiceDeployment.psm1")) { 
    Import-Module ".\WindowsServiceDeployment.psm1" -ErrorAction Stop
}

# Interrogates Package file for evidence of NServiceBus.
# Returns $true if the pachage contains NServiceBus libraries, $false otherwise
function IsNServiceBusService {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package file.")]
		[System.IO.FileInfo]$packageFile		
	)
	[string[]]$msdeployArgs = @(
	  "-verb:dump",
	  "-xml",
	  "-source:package='$packageFile'")
	  
	$xml = InvokeMsDeploy $msdeployArgs	
	
	if ($lastexitcode -ne 0) {
		throw ("Error inspecting $packageFile!")
	}
	
	$node = ([Xml]$xml).SelectSingleNode("//filePath[@path='NServiceBus.Host.exe']")
	return ($node -ne $null)
}

function GetPackageParameters {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package file.")]
		[System.IO.FileInfo]$packageFile		
	)

	[string[]]$msdeployArgs = @(
	  "-verb:getparameters",
	  "-source:package='$packageFile'"
	)

	[xml]$xml = InvokeMsDeploy $msdeployArgs	
	
	if ($lastexitcode -ne 0) {
		throw ("Error inspecting $packageFile!")
	}
	$xml
}

function DoesParameterExist {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The parameters file as an Xml document")]
		[System.Xml.XmlDocument]$xmlFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The parameter to search for")]
		[string]$parameterName		
	)
	
	return ($xmlFile.SelectSingleNode("//parameter[@name='$parameterName']") -ne $null)
}

# Query KeePass for credentials
# KeePass manages Name Value Pairs by Group, Title, and Field.  Group and Title are user defined.  
# Field is KeePass defined (e.g. UserName, Password, etc.)
function QueryKeePass {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the group containing the Title to Query for")]
		[String]$groupName,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the Title to query for")]
		[String]$title,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The name of the Field to query for")]
		[String]$fieldName
	)
	Set-PSDebug -Strict
	# Keypass parameters
	$keePassPath = "C:\Program Files (x86)\KeePass Password Safe 2\keepass.exe"
	$keepassDataBase = "\\safeautonet\dfs\Configman\KeyPass\CMDatabase.kdbx"
	$keepassKeyFile = "\\safeautonet\dfs\Configman\KeyPass\CMDatabase.key"
	$keepassPassword = "S@fe@uto"

	# Load KeePass assembly and Initialise KeePass Composite key
	[Reflection.Assembly]::LoadFrom($keePassPath) | Out-Null
	$kpIOConn = New-Object KeePassLib.Serialization.IOConnectionInfo
	$kpPwd = New-Object KeePassLib.Keys.KcpPassword -ArgumentList $keepassPassword
	$kpKeyFile = New-Object KeePassLib.Keys.KcpKeyFile -ArgumentList $keePassKeyFile
	$kpCompKey = New-Object KeePassLib.Keys.CompositeKey

	# Setup IOConnectionInfo
	$kpIOConn.Path = $keepassDataBase
	$kpIOConn.CredSaveMode = [KeePassLib.Serialization.IOCredSaveMode]::NoSave

	# Setup Composite Key info
	$kpCompKey.AddUserKey($kpPwd)
	$kpCompKey.AddUserKey($kpKeyFile)

	$db = New-Object KeePassLib.PwDatabase
	[KeePassLib.PwEntry[]]$pwEntries = @()
	$rootGroup = [System.IO.Path]::GetFileNameWithoutExtension($keepassDataBase)

	# Open the connection to the KeePass database
	$db.Open($kpIOConn, $kpCompKey, $null)
	
	# Delegate for filtering KeePass Entries for matching Titles
	$delegate = [KeePassLib.Delegates.EntryHandler] { param($pwEntry)
		Write-Output $pwEntry.CreationTime
		foreach($kvp in $pwEntry.Strings) 
		{
			if ($kvp.Key -eq "Title") 
			{
				$val = $kvp.Value.ReadString()
				if ($val -eq $title) 
				{
					$pwEntries += $pwEntry
					return $true
				}
			}
		}
		return $false
	}
	# Invoke Query
	$db.RootGroup.TraverseTree([KeePassLib.TraversalMethod]::PreOrder, $null, $delegate) | Out-Null
	
	$output = ""
	# Loop through the results and their "Strings" to find a match on the GroupName
	foreach($item in $pwEntries) 
	{
		$groupString = ""
		$parentGroup = $item.ParentGroup
		while($parentGroup -ne $null) 
		{
			if ($parentGroup.Name -ne $rootGroup) 
			{
				if ($groupString -ne "") { $groupString = "/" + $groupString }
				$groupString = $parentGroup.Name + $groupString
			}
			$parentGroup = $parentGroup.ParentGroup
		}

		if ($groupString -eq $groupName) {
			$output = $item.Strings.ReadSafe($fieldName)
		}
	}

	# Close connection and spit out match (if any)
	$db.Close()	
	
	$lastexitcode = 0
	$output
}

function InvokeMsDeploy {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="MsDeploy parameters defined as a string array.")]
		[String[]]$parameters
	)
	$msdeploy_path = "C:\Program Files (x86)\IIS\Microsoft Web Deploy V3\msdeploy.exe"
	$output = cmd.exe /C $("`"`"$msdeploy_path`" $parameters`"")
	$output
}

function GetInstallationPath {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The MsDeploy 'DestManifext.xml' file.")]
		[System.IO.FileInfo]$destManifest
	)
	
	[xml]$xml = Get-Content $destManifest
	$path = $xml.sitemanifest.contentPath.path
	$path
}

# Function to deploy a regular Windows Service
# This functions does the following:
# 1. Stops and Removes the service if it already exists
# 2. Deploys the files via WebDeploy
# 3. Reinstalls and restarts the service
function DeployDotNetWindowsService {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package folder to be deployed.")]
		[System.IO.FileInfo]$packageFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the computer to install the service on.")]
		[string]$computerName,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The name of the windows service")]
		[string]$serviceName,
		[parameter(HelpMessage="Optional username to create the service under")]
		[string]$userName,
		[parameter(HelpMessage="Optional password of the username")]
		[string]$password,
		[parameter(HelpMessage="Optional KeePass Group containing the username and password to create the service under")]
		[string]$keePassGroup,
		[parameter(HelpMessage="Optional KeePass Title containing the username and password to create the service under")]
		[string]$keePassTitle,
		[parameter(HelpMessage="Indicate if the service should start automatically.")]
		[Boolean]$automaticStart=$true
	)

	# Stop the service
	StopService $computerName $serviceName $true

	# Deploy the new service files
	$fileNoExt = [System.IO.Path]::GetFileNameWithoutExtension($packageFile)	
	$destManifestFile = "$($packageFile.DirectoryName)\$($fileNoExt).DestManifest.xml"
	$settingsFile = "$($packageFile.DirectoryName)\$($fileNoExt).SetParameters.xml"
	$destinationRoot = GetInstallationPath $destManifestFile
	$destinationPath = "$($destinationRoot)\bin\$($fileNoExt).exe"

	$winServiceUser = ""
	$winServicePassword = ""
	# Derive windows service credentials
	if (($userName -eq $null) -or ($userName.Length -eq 0)) {
		$winServiceUser = QueryKeePass $keePassGroup $keePassTitle "UserName"
		$winServicePassword = QueryKeePass $keePassGroup $keePassTitle "Password"
	}
	else {
		$winServiceUser = $userName
		$winServicePassword = $password
	}

	[string[]]$msdeployArgs = @(
	  "-verb:sync",
	  "-source:package='$packageFile'",
	  "-dest:manifest=`"$destManifestFile`",computerName=`"$computerName`",authtype=`"NTLM`",includeAcls=`"False`"",
	  "-disableLink:AppPoolExtension",
	  "-disableLink:ContentExtension",
	  "-disableLink:CertificateExtension",
	  "-setParamFile:`"$settingsFile`"", 
	  "-enableRule:DoNotDeleteRule",
	  "-allowUntrusted",
	  "-verbose"
	  )
	  
	InvokeMsDeploy $msdeployArgs
	if ($lastexitcode -ne 0) {
		throw ("Error deploying $($packageFile)!")
	}

	# Create the service
	$Wmi = [wmiclass]("\\$computerName\ROOT\CIMV2:Win32_Service")
	if ($Wmi -eq $null) {
		throw "Error accessing 'Root\Cimv2' Namespace on $($computerName)"
	}	

	$inparams = $Wmi.PSBase.GetMethodParameters("Create")
	$inparams.DesktopInteract = $false
	$inparams.DisplayName = $serviceName
	$inparams.ErrorControl = 0
	$inparams.LoadOrderGroup = $null
	$inparams.LoadOrderGroupDependencies = $null
	$inparams.Name = $serviceName
	$inparams.PathName = $destinationPath
	$inparams.ServiceDependencies = $null
	$inparams.ServiceType = 16
	$inparams.StartMode = if ($automaticStart -eq $true) {"Automatic"} else {"Manual"}
	$inparams.StartName = if ([string]::IsNullOrEmpty($winServiceUser) -eq $true) { $null } else { $winServiceUser }
	$inparams.StartPassword = if ([string]::IsNullOrEmpty($winServicePassword) -eq $true) { $null } else { $winServicePassword }
	
	$result = $Wmi.PSBase.InvokeMethod("Create", $inparams, $null)
	if ($result.ReturnValue -ne 0) {
		throw ("Unable to create windows service on $($computerName)! ReturnValue = $($result.ReturnValue)")
	}
	
	# Start the service
	if ($automaticStart -eq $true) {
		StartService $computerName $serviceName
	}
}

function DeployDotNetConsoleApp {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package file to be deployed.")]
		[System.IO.FileInfo]$packageFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the computer to install the console applicaiton on.")]
		[string]$computerName,
		[parameter(HelpMessage="The username to use authenticating to external applications (e.g. Guidewire)")]
		[string]$userName,
		[parameter(HelpMessage="The password of the username")]
		[string]$password,
		[parameter(HelpMessage="Optional KeePass Group containing the username and password to use authenticating to external applications (e.g. Guidewire)")]
		[string]$keePassGroup,
		[parameter(HelpMessage="Optional KeePass Title containing the username and password to use authenticating to external applications (e.g. Guidewire)")]
		[string]$keePassTitle		
	)
	
	# Deploy the new service files
	$fileNoExt = [System.IO.Path]::GetFileNameWithoutExtension($packageFile)	
	$destManifestFile = "$($packageFile.DirectoryName)\$($fileNoExt).DestManifest.xml"
	$settingsFile = "$($packageFile.DirectoryName)\$($fileNoExt).SetParameters.xml"
	$destinationRoot = GetInstallationPath $destManifestFile
	
	[string[]]$msdeployArgs = @(
	  "-verb:sync",
	  "-source:package='$packageFile'",
	  "-dest:manifest=`"$destManifestFile`",computerName=`"$computerName`",authtype=`"NTLM`",includeAcls=`"False`"",
	  "-disableLink:AppPoolExtension",
	  "-disableLink:ContentExtension",
	  "-disableLink:CertificateExtension",
	  "-setParamFile:`"$settingsFile`"", 
	  "-enableRule:DoNotDeleteRule",
	  "-allowUntrusted",
	  "-verbose"
	)	
	
	# Get Parameters
	$xml = GetPackageParameters $packageFile
	
	# Add params for GW User Id parameter if defined
	$hasGwUserId = DoesParameterExist $xml "GW User Id"
	if ($hasGwUserId -eq $true) {
		$guideWireUser = ""
		$guideWirePassword = ""
		# Derive GuideWire credentials
		if (($userName -eq $null) -or ($userName.Length -eq 0)) {
			$guideWireUser = QueryKeePass $keePassGroup $keePassTitle "UserName"
			$guideWirePassword = QueryKeePass $keePassGroup $keePassTitle "Password"
		}
		else {
			$guideWireUser = $userName
			$guideWirePassword = $password
		}	
	
		$msdeployArgs += "-setParam:name=`"GW User Id`",value=`"$guideWireUser`""
		$msdeployArgs += "-setParam:name=`"GW Password`",value=`"$guideWirePassword`""
	}
	
	InvokeMsDeploy $msdeployArgs
	if ($lastexitcode -ne 0) {
		throw ("Error deploying $($packageFile)!")
	}
	
	if ($hasGwUserId -eq $true) {
		EncryptConfigFile "$destinationRoot\bin\$serviceName.exe.config" $computerName $destinationRoot "applicationSettings/Saic.Common.GuidewireIntegration.Properties.Settings"
	}	
}

function DeployNServiceBusWindowsService {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package folder to be deployed.")]
		[System.IO.FileInfo]$packageFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the computer to install the service on.")]
		[string]$computerName,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The name of the windows service")]
		[string]$serviceName,
		[parameter(HelpMessage="Optional username to create the service under")]
		[string]$userName,
		[parameter(HelpMessage="Optional password of the username")]
		[string]$password,
		[parameter(HelpMessage="Optional KeePass Group containing the username and password to create the service under")]
		[string]$keePassGroup,
		[parameter(HelpMessage="Optional KeePass Title containing the username and password to create the service under")]
		[string]$keePassTitle,
		[parameter(HelpMessage="Indicate if the service should start automatically.")]
		[Boolean]$automaticStart=$true
	)
	
	# Deploy the new service files
	$fileNoExt = [System.IO.Path]::GetFileNameWithoutExtension($packageFile)	
	$destManifestFile = "$($packageFile.DirectoryName)\$($fileNoExt).DestManifest.xml"
	$settingsFile = "$($packageFile.DirectoryName)\$($fileNoExt).SetParameters.xml"
	$destinationRoot = GetInstallationPath $destManifestFile
	
	[string[]]$msdeployArgs = @(
	  "-verb:sync",
	  "-source:package='$packageFile'",
	  "-dest:manifest=`"$destManifestFile`",computerName=`"$computerName`",authtype=`"NTLM`",includeAcls=`"False`"",
	  "-disableLink:AppPoolExtension",
	  "-disableLink:ContentExtension",
	  "-disableLink:CertificateExtension",
	  "-setParamFile:`"$settingsFile`"", 
	  "-enableRule:DoNotDeleteRule",
	  "-allowUntrusted",
	  "-verbose"
	)
		
	# Stop the Service
	StopNServiceBusService $computerName $serviceName $destinationRoot $true
	
	# Get Parameters
	$xml = GetPackageParameters $packageFile

	$deploymentUser = ""
	$deploymentPassword = ""
	# Derive GuideWire credentials
	if (($userName -eq $null) -or ($userName.Length -eq 0)) {
		$deploymentUser = QueryKeePass $keePassGroup $keePassTitle "UserName"
		$deploymentPassword = QueryKeePass $keePassGroup $keePassTitle "Password"
	}
	else {
		$deploymentUser = $userName
		$deploymentPassword = $password
	}		
	
	# Add params for GW User Id parameter if defined
	$hasGwUserId = DoesParameterExist $xml "GW User Id"
	if ($hasGwUserId -eq $true) {
		$msdeployArgs += "-setParam:name=`"GW User Id`",value=`"$deploymentUser`""
		$msdeployArgs += "-setParam:name=`"GW Password`",value=`"$deploymentPassword`""
	}
	
	InvokeMsDeploy $msdeployArgs
	if ($lastexitcode -ne 0) {
		throw ("Error deploying $($packageFile)!")
	}
	
	if ($hasGwUserId -eq $true) {
		EncryptConfigFile "$destinationRoot\bin\$serviceName.exe.config" $computerName $destinationRoot "applicationSettings/Saic.Common.GuidewireIntegration.Properties.Settings"
	}
	
	# Create new service
	CreateNServiceBusWindowsService $destinationRoot $computerName $serviceName $deploymentUser $deploymentPassword $automaticStart
		
	# Start the service
	if ($automaticStart -eq $true) {
		StartService $computerName $serviceName
	}
}

function EncryptConfigFile {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The local path of the configuration file to be encrypted.")]
		[string]$configFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the server where the configuration file resides.")]
		[string]$serverName,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The local root path of the service")]
		[AllowEmptyString()]
		[string]$rootPath,
		[parameter(Mandatory=$true, Position=3, HelpMessage="The configuration section to encrypt")]
		[string]$configSection
	)
	
	$scriptBlock = {
		Param($cfgFile, $path, $section)	
		$aspNetRegIISPath = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\aspnet_regiis.exe"
	
		# Get the config file
		$file = Get-ChildItem $cfgFile
		$isWebConfig = ($file.Name -eq "web.config")
	
		if ($isWebConfig -ne $true) {
	    	# rename to web.config so encryption will work property
	    	$file.MoveTo("$path\bin\web.config")
	    }
		
	    # shell to aspnet_regiis to encrypt config file sections
	    & $aspNetRegIISPath -pef $section "$path\bin" -prov RSAProtectedConfigurationProvider 
	    
		if ($isWebConfig -ne $true) {
		    # rename web.config file back to its original file name
		    $file.MoveTo($cfgFile)    
		}
	}
	
	Invoke-Command -ComputerName "$computerName" -ScriptBlock $scriptBlock -ArgumentList @($configFile, $rootPath, $configSection)
}

function GetSiteNumber {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the server hosting the web site.")]
		[string]$serverName,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the web site.")]
		[string]$siteName		
	)
	
	$scriptBlock = {
		Param($site)	
		$appCmdPath = "C:\Windows\system32\inetsrv\appcmd.exe"	
	
	    # shell to aspnet_regiis to encrypt config file sections
	    $number = & $appCmdPath list site "`"$($site)`"" /text:id 
		$number
	}
	
	$result = Invoke-Command -ComputerName "$serverName" -ScriptBlock $scriptBlock -ArgumentList @($siteName)
	$result
}

function EncryptWebConfigFile {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the server where the configuration file resides.")]
		[string]$serverName,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The number of the web site in IIS on the web server.")]
		[int]$siteNumber,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The application path containing the web.config file to encrypt.  Use '/' when the web site is the application.")]
		[string]$applicationPath,
		[parameter(Mandatory=$true, Position=3, HelpMessage="The configuration section to encrypt")]
		[string]$configSection
	)
	
	$scriptBlock = {
		Param($section, $site, $appPath)	
		$aspNetRegIISPath = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\aspnet_regiis.exe"	
	
	    # shell to aspnet_regiis to encrypt config file sections
	    & $aspNetRegIISPath -pe $section -app "$($appPath)" -site "`"$($site)`"" -prov RSAProtectedConfigurationProvider     
	}
	
	Invoke-Command -ComputerName "$serverName" -ScriptBlock $scriptBlock -ArgumentList @($configSection, $siteNumber, $applicationPath)
}

function CreateNServiceBusWindowsService {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The installation path of the windows service on the target machine.")]
		[string]$rootPath,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the computer to install the service on.")]
		[string]$computerName,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The name of the windows service")]
		[string]$serviceName,
		[parameter(Mandatory=$true, Position=3, HelpMessage="The username to create the service under")]
		[AllowEmptyString()]
		[string]$userName,
		[parameter(Mandatory=$true, Position=4, HelpMessage="The password of the username")]
		[AllowEmptyString()]
		[string]$password,
		[parameter(Position=5, HelpMessage="Indicates if the service should have an automatic start mode.")]
		[Boolean]$automaticStart = $true
	)

	$scriptBlock = {
		Param($svc, $user, $pwd, $path)		
		[string[]]$installArgs = @(
			"/install",
			"/serviceName:$svc",
			"/username:$user",
			"/password:$pwd"
		)

		if ($automaticStart -ne $true) {
			$installArgs += "/startManually"
		}

		& "$path\bin\NServiceBus.Host.exe" $installArgs | Out-Host	
	}
	
	Invoke-Command -ComputerName $computerName -ScriptBlock $scriptBlock -ArgumentList @($serviceName, $userName, $password, $rootPath)
}

# Function to check whether or not a .Net Web Application should be deployed.
function ShouldDeployDotNetWebApplication {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package file to be deployed.")]
		[System.IO.FileInfo]$packageFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the server to install the web application.")]
		[string]$serverName,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The web site name to deploy to")]
		[string]$siteName,
		[parameter(Mandatory=$true, Position=3, HelpMessage="The virtual path to deploy to")]
		[AllowEmptyString()]
		[string]$applicationPath,
		[parameter(HelpMessage="Optional username to authenticate to IIS")]
		[string]$userName,
		[parameter(HelpMessage="Optional password to authenticate to IIS")]
		[string]$password,
		[parameter(HelpMessage="Optional KeePass Group containing the username and password to lookup in order to authenticate to IIS")]
		[string]$keePassGroup,
		[parameter(HelpMessage="Optional KeePass Title containing the username and password to lookup in order to authenticate to IIS")]
		[string]$keePassTitle
	)
	# Derive settings File
	$fileNoExt = [System.IO.Path]::GetFileNameWithoutExtension($packageFile)	
	$settingsFile = "$($packageFile.DirectoryName)\$($fileNoExt).SetParameters.xml"

	$webDeployUser = ""
	$webDeployPassword = ""
	# Derive web deploy credentials
	if (($userName -eq $null) -or ($userName.Length -eq 0)) {
		$webDeployUser = QueryKeePass $keePassGroup $keePassTitle "UserName"
		$webDeployPassword = QueryKeePass $keePassGroup $keePassTitle "Password"
	}
	else {
		$webDeployUser = $userName
		$webDeployPassword = $password
	}

	# Use the same parameter values as before except includeAcls, -whatif, -usechecksum, and -xml 
	[string[]]$msdeployArgs = @(
	  "-verb:sync",
	  "-source:package='$packageFile'",
	  "-dest:auto,computerName=`"https://$($serverName):8172/msdeploy.axd?site=$($siteName)`",authtype=`"Basic`",username=`"$($webDeployUser)`",password=`"$($webDeployPassword)`",includeAcls=`"False`"",
	  "-setParam:name=`"IIS Web Application Name`",value=`"$($applicationPath)`"",
	  "-disableLink:AppPoolExtension",
	  "-disableLink:ContentExtension",
	  "-disableLink:CertificateExtension",
	  "-setParamFile:`"$settingsFile`"",
	  "-enableRule:DoNotDeleteRule",
	  "-disableRule:Dependency*",
	  "-allowUntrusted",
	  "-whatif",
	  "-useCheckSum",
	  "-xml"
	)
	
	$result = $false
	[xml]$xml = InvokeMsDeploy $msdeployArgs
	if ($lastexitcode -ne 0) {
		throw ("Error deploying $($packageFile)!")
	}
	
	# Check if xml was returned if it contains any summary information about number of objects affected
	if ($xml -ne $null){
		$node = $xml.SelectSingleNode("//output/syncResults")
		if ($node -ne $null) {
			$totals = ([int]$node.objectsAdded + [int]$node.objectsDeleted + [int]$node.objectsUpdated)
			$result = ($totals -gt 0)
		}
	}
	
	return $result
}

function ShouldDeployDotNetApplication {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package folder to be deployed.")]
		[System.IO.FileInfo]$packageFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the computer to install the service on.")]
		[string]$computerName
	)
	
	# Deploy the new service files
	$fileNoExt = [System.IO.Path]::GetFileNameWithoutExtension($packageFile)	
	$destManifestFile = "$($packageFile.DirectoryName)\$($fileNoExt).DestManifest.xml"
	$settingsFile = "$($packageFile.DirectoryName)\$($fileNoExt).SetParameters.xml"
	$destinationRoot = GetInstallationPath $destManifestFile
	
	[string[]]$msdeployArgs = @(
	  "-verb:sync",
	  "-source:package='$packageFile'",
	  "-dest:manifest=`"$destManifestFile`",computerName=`"$computerName`",authtype=`"NTLM`",includeAcls=`"False`"",
	  "-disableLink:AppPoolExtension",
	  "-disableLink:ContentExtension",
	  "-disableLink:CertificateExtension",
	  "-setParamFile:`"$settingsFile`"", 
	  "-enableRule:DoNotDeleteRule",
	  "-allowUntrusted",
	  "-whatif",
	  "-useCheckSum",
	  "-xml"
	)
	
	$result = $false
	[xml]$xml = InvokeMsDeploy $msdeployArgs
	if ($lastexitcode -ne 0) {
		throw ("Error deploying $($packageFile)!")
	}
	
	# Check if xml was returned if it contains any summary information about number of objects affected
	if ($xml -ne $null){
		$node = $xml.SelectSingleNode("//output/syncResults")
		if ($node -ne $null) {
			$totals = ([int]$node.objectsAdded + [int]$node.objectsDeleted + [int]$node.objectsUpdated)
			$result = ($totals -gt 0)
		}
	}
	
	return $result	
}		

function DeployDotNetWebApplication {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the MsDeploy Package file to be deployed.")]
		[System.IO.FileInfo]$packageFile,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the server to install the web application.")]
		[string]$serverName,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The web site name to deploy to")]
		[string]$siteName,
		[parameter(Mandatory=$true, Position=3, HelpMessage="The virtual path to deploy to")]
		[AllowEmptyString()]
		[string]$applicationPath,
		[parameter(HelpMessage="Optional username to authenticate to IIS")]
		[string]$userName,
		[parameter(HelpMessage="Optional password to authenticate to IIS")]
		[string]$password,
		[parameter(HelpMessage="Optional KeePass Group containing the username and password to lookup in order to authenticate to IIS")]
		[string]$keePassGroup,
		[parameter(HelpMessage="Optional KeePass Title containing the username and password to lookup in order to authenticate to IIS")]
		[string]$keePassTitle,
		[parameter(HelpMessage="Optional KeePass Group containing the username and password to lookup in order to authenticate to GuideWire")]
		[string]$guideWireUserKeePassGroup,
		[parameter(HelpMessage="Optional KeePass Title containing the username and password to lookup in order to authenticate to GuideWire")]
		[string]$guideWireUserKeePassTitle
	)

	# Derive settings File
	$fileNoExt = [System.IO.Path]::GetFileNameWithoutExtension($packageFile)	
	$settingsFile = "$($packageFile.DirectoryName)\$($fileNoExt).SetParameters.xml"

	$webDeployUser = ""
	$webDeployPassword = ""
	# Derive web deploy credentials
	if (($userName -eq $null) -or ($userName.Length -eq 0)) {
		$webDeployUser = QueryKeePass $keePassGroup $keePassTitle "UserName"
		$webDeployPassword = QueryKeePass $keePassGroup $keePassTitle "Password"
	}
	else {
		$webDeployUser = $userName
		$webDeployPassword = $password
	}

	[string[]]$msdeployArgs = @(
	  "-verb:sync",
	  "-source:package='$packageFile'",
	  "-dest:auto,computerName=`"https://$($serverName):8172/msdeploy.axd?site=$($siteName)`",authtype=`"Basic`",username=`"$($webDeployUser)`",password=`"$($webDeployPassword)`",includeAcls=`"True`"",
	  "-retryAttempts:5",
	  "-retryInterval:3000",
	  "-setParam:name=`"IIS Web Application Name`",value=`"$($applicationPath)`"",
	  "-disableLink:AppPoolExtension",
	  "-disableLink:ContentExtension",
	  "-disableLink:CertificateExtension",
	  "-setParamFile:`"$settingsFile`"",
	  "-enableRule:DoNotDeleteRule",
	  "-allowUntrusted",
	  "-verbose"
	)
	
	# Get Parameters
	$xml = GetPackageParameters $packageFile
	
	# Add params for GW User Id parameter if defined
	$hasGwUserId = DoesParameterExist $xml "GW User Id"
	if ($hasGwUserId -eq $true) {
		if (($guideWireUserKeePassTitle -ne $null) -and ($guideWireUserKeePassTitle.Length -gt 0)) {
			$guideWireUser = QueryKeePass $guideWireUserKeePassGroup $guideWireUserKeePassTitle "UserName"
			$guideWirePassword = QueryKeePass $guideWireUserKeePassGroup $guideWireUserKeePassTitle "Password"
		}
		else {
			$guideWireUser = $webDeployUser
			$guideWirePassword = $webDeployPassword
		}
		$msdeployArgs += "-setParam:name=`"GW User Id`",value=`"$guideWireUser`""
		$msdeployArgs += "-setParam:name=`"GW Password`",value=`"$guideWirePassword`""
	}
	
	InvokeMsDeploy $msdeployArgs
	if ($lastexitcode -ne 0) {
		throw ("Error deploying $($fileNoExt)!")
	}
	
	if ($hasGwUserId -eq $true) {
		$siteNumber = GetSiteNumber $serverName $siteName
		$appPath = $applicationPath.Replace($siteName, "")
		EncryptWebConfigFile $serverName $siteNumber $appPath "applicationSettings/Saic.Common.GuidewireIntegration.Properties.Settings"
	}
}

function StopNServiceBusService {
	Param (
		[parameter(Mandatory=$true, Position=0, HelpMessage="The name of the computer that the service is on.")]
		[string]$computerName,
		[parameter(Mandatory=$true, Position=1, HelpMessage="The name of the windows service")]
		[string]$serviceName,
		[parameter(Mandatory=$true, Position=2, HelpMessage="The root path where the service will be installed.")]
		[string]$rootPath,
		[parameter(Position=3, HelpMessage="The name of the computer that the service is on.")]
		[Boolean]$remove = $false
	)
	
	StopService $computerName $serviceName $false
	
	if ($remove -eq $true) 
	{
		$sb = {param($serviceName,$hostPath) 
			[string[]]$uninstallArgs = @(
				"/uninstall",
				"/serviceName:`"$serviceName`""	
			)
			if (Test-Path -Path '$hostPath') { & '$hostPath' $uninstallArgs | Out-Host } 
		}
        $nServiceBusHostPath = "$rootPath\bin\NServiceBus.Host.exe"
		Invoke-Command -ComputerName "$computerName" -ScriptBlock $sb -ArgumentList @($serviceName, $nServiceBusHostPath)
	}
}
