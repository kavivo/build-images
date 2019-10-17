function PrintSummary($buildTarget, $AppVeyorUrl, $buildCloudId, $build_cloud_name, $imageName) {
    Write-host "`nNext steps:"  -ForegroundColor Cyan
    Write-host " - Optionally review build environment $build_cloud_name at $AppVeyorUrl/build-clouds/$buildCloudId" -ForegroundColor DarkGray
    Write-host " - To start building on $buildTarget select " -ForegroundColor DarkGray -NoNewline
    Write-host "$imageName " -NoNewline
    Write-host "build worker image " -ForegroundColor DarkGray -NoNewline 
    Write-host "and " -ForegroundColor DarkGray -NoNewline 
    Write-host "$build_cloud_name " -NoNewline
    Write-host "build cloud on AppVeyor project settings or in " -NoNewline -ForegroundColor DarkGray
    Write-host "appveyor.yml" -NoNewline
    Write-host ":"
    Write-host "`nbuild_cloud: $build_cloud_name" -ForegroundColor Gray
    Write-host "image: $imageName" -ForegroundColor Gray
    Write-Host "`n"
}
function CreateSlug($str) {
    return (($str.ToLower() -replace "[^a-z0-9-]", "-") -replace "-+", "-")
}

function CreateTempFolder {
    New-TemporaryFile | % {
        $parentFolder = Join-Path $(Split-Path $_ -Parent) "AppVeyorBYOC"
        if (-not (Test-Path $parentFolder)){
            mkdir $parentFolder
            if ($isMacOS -or $isLinux) {
                chmod 700 $parentFolder
            }
        }
        $tmpFolder = Join-Path $parentFolder $(Split-Path $_ -Leaf)
        rm $_ 
        mkdir $tmpFolder | out-null
        if ($isMacOS -or $isLinux) {
            chmod 700 $tmpFolder
        }
        (Resolve-Path $tmpFolder).Path
    }
}

function EnsureElevatedModeOnWindows() {
    if (-not $isLinux -and -not $isMacOS -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        throw "This command should be run in elevated mode to install AppVeyor Host Agent. Run PowerShell in elevated mode (Run as Administrator) and re-run the command."
    }
}

function GetHomeDir {
    if ($isMacOS -or $isLinux) {
        return $env:HOME
    } else {
        return $env:USERPROFILE
    }
}

function InstallAppVeyorHostAgent($appVeyorUrl, $hostAuthorizationToken) {

    $APPVEYOR_HOST_AGENT_MSI_URL = "https://www.appveyor.com/downloads/appveyor/appveyor-host-agent.msi"
    $APPVEYOR_HOST_AGENT_DEB_URL = "https://www.appveyor.com/downloads/appveyor/appveyor-host-agent.deb"    

    Write-Host "`nInstalling AppVeyor Host Agent" -ForegroundColor Cyan

    if ($isLinux) {

        # Linux
        # =======

        Write-Host "OS: Linux" -ForegroundColor Gray

        if (-not (Test-Path '/opt/appveyor/host-agent')) {

            $debPath = "/tmp/appveyor-host-agent.deb"

            Write-Host "Downloading appveyor-host-agent.deb..." -ForegroundColor Gray
            (New-Object Net.WebClient).DownloadFile($APPVEYOR_HOST_AGENT_DEB_URL, $debPath)

            Write-Host "Installing Host Agent..." -ForegroundColor Gray
            sudo bash -c "APPVEYOR_URL=$appVeyorUrl HOST_AUTH_TOKEN=$hostAuthorizationToken dpkg -i $debPath"

            Remove-Item $debPath

            $hostAgentPid = (pidof appveyor-host-agent)
            if ($hostAgentPid) {
                Write-Host "Host Agent has been installed"
            } else {
                Write-Host "Something went wrong and Host Agent was not installed" -ForegroundColor Red
                throw "Error installing Host Agent"
            }

        } else {
            Write-Host "Host Agent is already installed" -ForegroundColor DarkGray
            /opt/appveyor/host-agent/appveyor version
        }

    } elseif ($isMacOS) {

        # macOS
        # =======

        Write-Host "OS: macOS" -ForegroundColor Gray

        $hostAgentProcess = Get-Process "appveyor-host-a" -ErrorAction SilentlyContinue
        if (-not $hostAgentProcess) {
            # make sure Homebrew is installed and available in the path
            if (-not (Get-Command brew -ErrorAction Ignore)) {
                Write-Warning "This command depends on Homebrew package manager. Please install it from https://brew.sh and re-run the command."
                return
            }

            $backupErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = "Ignore"
            $brew_output = $(brew list appveyor-host-agent)
            $ErrorActionPreference = $backupErrorActionPreference
            if (-not $brew_output) {
                Write-Host "Installing Host Agent..." -ForegroundColor Gray
                bash -c "HOMEBREW_APPVEYOR_URL=$appVeyorUrl HOMEBREW_HOST_AUTH_TKN=$hostAuthorizationToken brew install appveyor/brew/appveyor-host-agent"
            } else{
                Write-Host "Host Agent already installed:" -ForegroundColor Gray
                brew list --versions appveyor-host-agent
            }

            Write-Host "Starting up Host Agent service..."
            brew services restart appveyor-host-agent

            $hostAgentProcess = Get-Process "appveyor-host-a" -ErrorAction SilentlyContinue
            if ($hostAgentProcess) {
                Write-Host "Host Agent has been installed"
            } else {
                Write-Host "Something went wrong and Host Agent was not installed" -ForegroundColor Red
                throw "Error installing Host Agent"
            }    
        } else {
            Write-Host "Host Agent is already installed" -ForegroundColor DarkGray
            brew list --versions appveyor-host-agent
        }

    } else {

        # Windows
        # =======

        Write-Host "OS: Windows" -ForegroundColor Gray

        $hostAgentService = Get-Service "Appveyor.HostAgent" -ErrorAction SilentlyContinue
        if (-not $hostAgentService) {

            Write-Host "Downloading appveyor-host-agent.msi..." -ForegroundColor Gray
            $msiPath = "$env:temp\appveyor-host-agent.msi"
            (New-Object Net.WebClient).DownloadFile($APPVEYOR_HOST_AGENT_MSI_URL, $msiPath)

            Write-Host "Installing Host Agent..." -ForegroundColor Gray
            cmd /c msiexec /i $msiPath /quiet APPVEYOR_URL="$appVeyorUrl" HOST_AUTHORIZATION_TOKEN="$hostAuthorizationToken"

            Remove-Item $msiPath
            $hostAgentService = Get-Service "Appveyor.HostAgent" -ErrorAction SilentlyContinue
            if ($hostAgentService) {
                Write-Host "Host Agent has been installed"
            } else {
                Write-Host "Something went wrong and Host Agent was not installed" -ForegroundColor Red
                throw "Error installing Host Agent"
            }                
        } else {
            Write-Host "Host Agent is already installed" -ForegroundColor DarkGray
        }
    }
}

function ValidateAppVeyorApiAccess($appVeyorUrl, $apiToken){
    Write-host "`nChecking AppVeyor API access..."  -ForegroundColor Cyan
    if ($apiToken -like "v2.*") {
        Write-Warning "Please select the API Key for specific account (not 'All Accounts') at '$appVeyorUrl/api-keys'"
        ExitScript
    }

    try {
        $response = Invoke-WebRequest -Uri $appVeyorUrl -UseBasicParsing -ErrorAction SilentlyContinue
        if ($response.StatusCode -ne 200) {
            Write-warning "AppVeyor URL '$appVeyorUrl' responded with code $($response.StatusCode)"
            ExitScript
        }
    }
    catch {
        Write-warning "Unable to connect to AppVeyor URL '$appVeyorUrl'. Error: $($error[0].Exception.Message)"
        ExitScript
    }

    $headers = @{
      "Authorization" = "Bearer $apiToken"
      "Content-type" = "application/json"
    }
    try {
        Invoke-RestMethod -Uri "$appVeyorUrl/api/projects" -Headers $headers -Method Get | Out-Null
    }
    catch {
        Write-warning "Unable to call AppVeyor REST API, please verify 'ApiToken' and ensure '-AppVeyorUrl' parameter is set if you are using on-premise AppVeyor Server."
        ExitScript
    }

    if ($appVeyorUrl -eq "https://ci.appveyor.com") {
          try {
            Invoke-RestMethod -Uri "$appVeyorUrl/api/build-clouds" -Headers $headers -Method Get | Out-Null
        }
        catch {
            Write-warning "Please contact support@appveyor.com and request enabling of 'BYOC' feature."
            ExitScript
        }
    }
    return $headers
}

function ValidateDependencies ($cloudType) {
    if ($cloudType -eq "Azure") {
        Write-host "`nChecking if Az PowerShell Module is installed..."  -ForegroundColor Cyan
        if (-not (Get-Module -Name *Az.* -ListAvailable)) {
            Write-Warning "Az PowerShell Module is not installed."
            $installAzPs = Read-Host "Enter 1 to install it or any other key to stop command execution and install it manually"
            if ($installAzPs -eq 1) {
                Install-Module -Name Az -Scope CurrentUser -AllowClobber
            }
            else {
                Write-Warning "Please install Az PowerShell Module with 'Install-Module -Name Az -Scope CurrentUser -AllowClobber' and re-run the command."
                ExitScript
            }
        }
    }

    if ($cloudType -eq "GCE") {
        Write-host "`nChecking if Google Cloud SDK is installed..."  -ForegroundColor Cyan
        if (-not (Get-Command gcloud -ErrorAction Ignore)) {
            Write-Warning "This command depends on Google Cloud SDK. Use 'choco install gcloudsdk' on Windows, for Linux follow https://cloud.google.com/sdk/docs/quickstart-linux, for Mac: https://cloud.google.com/sdk/docs/quickstart-macos"
            ExitScript
        }

        #TODO remove if GoogleCloud does not appear to be needed (if al canbe done with gcloud)
        if (-not (Get-Module -Name GoogleCloud -ListAvailable)) {
            Write-Warning "This command depends on Google Cloud PowerShell module. Please install them with the following command: 'Install-Module -Name GoogleCloud -Force; Import-Module -Name GoogleCloud"
            ExitScript
        }
        #Import module anyway, to be sure.
        Import-Module -Name GoogleCloud
    }

    if ($cloudType -eq "AWS") {
        Write-host "`nChecking if AWS Tools for PowerShell are installed..."  -ForegroundColor Cyan
        if (-not (Get-Module -Name *AWSPowerShell* -ListAvailable)) {
            Write-Warning "This command depends on AWS Tools for PowerShell. Please install them with the following command: 'Install-Module -Name AWSPowerShell -Force; Import-Module -Name AWSPowerShell'"
            ExitScript
        }
        if (-not (Get-Command Get-AWSCredentials -ErrorAction Ignore)) {
            Write-Warning "Unable to get 'Get-AWSCredentials' command. Please ensure latest 'AWSPowerShell' module is installed and imported"
            ExitScript
        }
    }
    
   if ($cloudType -eq "HyperV") {
        Write-host "`nChecking if Hyper-V tools are installed..."  -ForegroundColor Cyan
        Import-Module Hyper-V -ErrorAction Ignore
        if (-not (Get-Module Hyper-V -ErrorAction Ignore)) {
            Write-Warning "Hyper-V feature or its management tools are not installed. Please install Hyper-V feature with 'Install-WindowsFeature -Name Hyper-V -IncludeManagementTools' (for Windows Server) or 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All' (for Windows 10), restart computer if needed, and re-run the command."
            ExitScript
        }
    }
}

function GetPackerPath ([switch]$prerelease) {
    $packerVersion = if ($prerelease) {"1.4.4"} else {"1.4.3"}
    Write-host "`nChecking if Hashicorp Packer version $packerVersion is installed..."  -ForegroundColor Cyan
    if ((Get-Command packer -ErrorAction Ignore) -and (packer --version) -eq $packerVersion) {
        Write-Host "Packer version $packerVersion found" -ForegroundColor DarkGray
        return "packer"
    }
    else {
        $packerFolder = CreateTempFolder
        $zipPath = Join-Path $packerFolder "packer_$($packerVersion)_amd64.zip"
        Write-Host "Downloading Packer version $packerVersion to temporary folder..." -ForegroundColor DarkGray
        $currentSecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol
        $zipFile = if ($isLinux) {"packer_$($packerVersion)_linux_amd64.zip"} elseif ($isMacOS) {"packer_$($packerVersion)_darwin_amd64.zip"} else {"packer_$($packerVersion)_windows_amd64.zip"} 
        [System.Net.ServicePointManager]::SecurityProtocol = "Tls12"
        $URL = if ($prerelease) {"https://github.com/appveyor/build-images/releases/download/packer-1.4.4/packer_windows_amd64.zip"} else {"https://releases.hashicorp.com/packer/$packerVersion/$zipFile"}
        (New-Object Net.WebClient).DownloadFile($URL, $zipPath)
        [System.Net.ServicePointManager]::SecurityProtocol = $currentSecurityProtocol
        Expand-Archive -LiteralPath $zipPath -DestinationPath $packerFolder
        Remove-Item $zipPath -force -ErrorAction Ignore
        $packerPath = Join-Path $packerFolder "packer"
        if ($isMacOS -or $isLinux) {
            chmod 700 $packerPath
        }
        Write-Host "Using $packerPath" -ForegroundColor DarkGray
        return $packerPath
    }
}

function ParseImageFeaturesAndCustomScripts ($imageFeatures, $imageTemplate, $ImageCustomScript, $ImageCustomScriptAfterReboot, $imageOs) {
    $imageFeatures = $imageFeatures.Trim()
    if(($imageFeatures.Contains(' ') -and -not $imageFeatures.Contains(',')) -or $imageFeatures.Contains(';')) {
        Write-Warning "'ImageFeatures' should be comma-separate list or single value"
        ExitScript
    }

    $packer_file = Get-Content $imageTemplate | ConvertFrom-Json

    if ($imageFeatures -and $imageOs -eq "Windows") {
        $imageFeatures = ($imageFeatures.Split(',') | % { $_.Trim() })

        $before_reboot_script = @()
        $imageFeatures | % {
            $scriptName1 = "install_$_.ps1"
            $scriptName2 = "$_.ps1"
            if (Test-Path "$PSScriptRoot/scripts/Windows/$scriptName1") {
                $before_reboot_script += "{{ template_dir }}/scripts/Windows/$scriptName1"
                }
            elseif (Test-Path "$PSScriptRoot/scripts/Windows/$scriptName2") {
                $before_reboot_script += "{{ template_dir }}/scripts/Windows/$scriptName2"
                }
            else {
                Write-Warning "Unable to find $scriptName1 or $scriptName2 in $PSScriptRoot/scripts/Windows"
                ExitScript
            }
        }

        $after_reboot_scripts = @()
        $imageFeatures | % {
            $scriptName1 = "install_$($_)_after_reboot.ps1"
            $scriptName2 = "$($_)_after_reboot.ps1"
            if (Test-Path "$PSScriptRoot/scripts/Windows/$scriptName1") {
                $after_reboot_scripts += "{{ template_dir }}/scripts/Windows/$scriptName1"
                }
            elseif (Test-Path "$PSScriptRoot/scripts/Windows/$scriptName2") {
                $after_reboot_scripts += "{{ template_dir }}/scripts/Windows/$scriptName2"
                }
        }

        $before_reboot = @{
            'type' = 'powershell'
            'scripts' = $before_reboot_script
            'elevated_user' = '{{user `install_user`}}'
            'elevated_password' = '{{user `install_password`}}'
        }
        $packer_file.provisioners += $before_reboot

        if ($after_reboot_scripts.Count -gt 0) {
            $reboot = @{
                'type' = 'windows-restart'
                'restart_timeout' = '30m'
            }
            $packer_file.provisioners += $reboot

            $after_reboot = @{
                'type' = 'powershell'
                'scripts' = $after_reboot_scripts
                'elevated_user' = '{{user `install_user`}}'
                'elevated_password' = '{{user `install_password`}}'
            }
            $packer_file.provisioners +=$after_reboot
        }
    }

    if($ImageCustomScript) {
        $fileExtension =  if ($imageOs -eq "Windows") {"ps1"} elseif ($imageOs -eq "Linux") {"sh"}
        $provisionerShell =  if ($imageOs -eq "Windows") {"powershell"} elseif ($imageOs -eq "Linux") {"shell"}
        $ImageCustomScript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ImageCustomScript))
        $customScriptFile = Join-Path $(CreateTempFolder) "$(New-Guid).$fileExtension"
        $ImageCustomScript | Set-Content -Path $customScriptFile
        $custom_before_reboot_script =  @($customScriptFile)

        $custom_before_reboot = 
        if ($imageOs -eq "Windows") {
            @{
            'type' = $provisionerShell
            'scripts' = $custom_before_reboot_script
            'elevated_user' = '{{user `install_user`}}'
            'elevated_password' = '{{user `install_password`}}'
            }
        }
        elseif ($imageOs -eq "Linux") {
            @{
            'type' = $provisionerShell
            'scripts' = $custom_before_reboot_script
            }
        }

       $packer_file.provisioners += $custom_before_reboot
    }

    if($ImageCustomScriptAfterReboot -and $imageOs -eq "Windows") {
        $reboot = @{
            'type' = 'windows-restart'
            'restart_timeout' = '30m'
        }
        $packer_file.provisioners += $reboot

        $ImageCustomScriptAfterReboot = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ImageCustomScriptAfterReboot))
        $customScriptFileAfterReboot = Join-Path $(CreateTempFolder) "$(New-Guid).ps1"
        $ImageCustomScriptAfterReboot | Set-Content -Path $customScriptFileAfterReboot
        $custom_after_reboot_scripts = @($customScriptFileAfterReboot)
        $custom_after_reboot = @{
            'type' = 'powershell'
            'scripts' = $custom_after_reboot_scripts
            'elevated_user' = '{{user `install_user`}}'
            'elevated_password' = '{{user `install_password`}}'
        }
        $packer_file.provisioners += $custom_after_reboot
    }

    $imageTemplateCustom = Join-Path $(CreateTempFolder) $(Split-Path $ImageTemplate -Leaf)
    Copy-Item -Path "$PSScriptRoot\scripts" -Destination $(Split-Path $imageTemplateCustom -Parent) -recurse -Force
    Copy-Item -Path "$PSScriptRoot\hyper-v" -Destination $(Split-Path $imageTemplateCustom -Parent) -recurse -Force
    Copy-Item -Path "$PSScriptRoot\http" -Destination $(Split-Path $imageTemplateCustom -Parent) -recurse -Force
    $packer_file | ConvertTo-Json -Depth 20 | Set-Content -Path $imageTemplateCustom
    return $imageTemplateCustom
}

function SetBuildWorkerImage ($headers, $ImageName, $ImageOs) {
    Write-host "`nEnsure build worker image is available for AppVeyor projects" -ForegroundColor Cyan
    $images = Invoke-RestMethod -Uri "$AppVeyorUrl/api/build-worker-images" -Headers $headers -Method Get
    $image = $images | Where-Object ({$_.name -eq $ImageName})[0]
    if (-not $image) {
        $body = @{
            name = $imageName
            osType = $ImageOs
        }

        $jsonBody = $body | ConvertTo-Json
        Invoke-RestMethod -Uri "$AppVeyorUrl/api/build-worker-images" -Headers $headers -Body $jsonBody -Method Post | Out-Null
        Write-host "AppVeyor build worker image '$ImageName' has been created." -ForegroundColor DarkGray
    } else {
        Write-host "AppVeyor build worker image '$ImageName' already exists." -ForegroundColor DarkGray
    }
}

function CreatePassword {
    $upper = (65..90) | Get-Random | % {[char]$_}
    $lower = (97..122) | Get-Random | % {[char]$_}
    $symbol = @('!', '@', '#', '$', '%', '^', '*', '(', ')', '_', '+', '=')[(Get-Random -Maximum 12)]
    $base = (New-Guid).ToString().SubString(0, 17).Replace("-", "").ToCharArray()
    $bound1 = [int]($base.Length/3)
    $bound2 = [int]($base.Length/3)*2
    $bound3 = $base.Length - 1
    $base[(Get-Random -Minimum 0 -Maximum $bound1)] = $upper
    $base[(Get-Random -Minimum $bound1 -Maximum $bound2)] = $lower
    $base[(Get-Random -Minimum $bound2 -Maximum $bound3)] = $symbol
    return -join $base
}

function GetOrCreateServicePrincipal ($service_principal_name, $build_cloud_name, $headers) {
    $sp = Get-AzADServicePrincipal -DisplayName $service_principal_name
    $app = Get-AzADApplication -DisplayName $service_principal_name
    if (-not $sp -and $app) {
        Write-Warning "`nService principal '$($service_principal_name)' does not exist, but Azure AD application with the same name already exists." 
        "`nPlease either delete that Azure Ad Application or use another service principal name."
        ExitScript
    }
    if (-not $sp) {
        $sp = New-AzADServicePrincipal -DisplayName $service_principal_name -Role Contributor
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sp.Secret)
        $azure_client_secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        $azure_client_id = $sp.ApplicationId
    }
    else {
        $clouds = Invoke-RestMethod -Uri "$($AppVeyorUrl)/api/build-clouds" -Headers $headers -Method Get
        $cloud = $clouds | ? ({$_.name -eq $build_cloud_name})[0]
        if ($cloud) {
            $settings = Invoke-RestMethod -Uri "$($AppVeyorUrl)/api/build-clouds/$($cloud.buildCloudId)" -Headers $headers -Method Get
            $azure_client_id = $settings.settings.cloudSettings.azureAccount.clientId
            $azure_client_secret = $settings.settings.cloudSettings.azureAccount.clientSecret
            $service_principal_name = (Get-AzADServicePrincipal -ApplicationId $azure_client_id).DisplayName
        }
        else {
            $new_service_principal_name = "$service_principal_name-$((New-Guid).ToString().SubString(0, 8))"
            Write-Warning "Azure AD service principal and application with the name '$service_principal_name' already exist, creating '$new_service_principal_name'."
            Write-Warning "Consider deleting '$service_principal_name' service principal and application if they are not being used with any other service."
            GetOrCreateServicePrincipal $new_service_principal_name
            return
        }
    }
    Write-host "Using Azure AD service principal '$($service_principal_name)'" -ForegroundColor DarkGray
    return @{
        "azure_client_id" = $azure_client_id
        "azure_client_secret" = $azure_client_secret
    }
}

function GetImageTemplatePath ($imageTemplate) {
    if ($imageTemplate) {
        if (Test-Path "$PSScriptRoot/$ImageTemplate") {
            return "$PSScriptRoot/$ImageTemplate"
        }
        elseif (Test-Path "$ImageTemplate") {
            return $ImageTemplate
        }
        Write-Warning "`nUnable to find Packer image template '$ImageTemplate'."
        ExitScript
    }
    elseif ($ImageOs -eq "Windows") {
        return "$PSScriptRoot/minimal-windows-server.json"
    }
    elseif ($ImageOs -eq "Linux") {
        return "$PSScriptRoot/minimal-ubuntu.json"
    }
}

# FROM https://gallery.technet.microsoft.com/scriptcenter/New-ISOFile-function-a8deeffd
function New-IsoFile
{
  <#
   .Synopsis
    Creates a new .iso file
   .Description
    The New-IsoFile cmdlet creates a new .iso file containing content from chosen folders
   .Example
    New-IsoFile "c:\tools","c:Downloads\utils"
    This command creates a .iso file in $env:temp folder (default location) that contains c:\tools and c:\downloads\utils folders. The folders themselves are included at the root of the .iso image.
   .Example
    New-IsoFile -FromClipboard -Verbose
    Before running this command, select and copy (Ctrl-C) files/folders in Explorer first.
   .Example
    dir c:\WinPE | New-IsoFile -Path c:\temp\WinPE.iso -BootFile "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\efisys.bin" -Media DVDPLUSR -Title "WinPE"
    This command creates a bootable .iso file containing the content from c:\WinPE folder, but the folder itself isn't included. Boot file etfsboot.com can be found in Windows ADK. Refer to IMAPI_MEDIA_PHYSICAL_TYPE enumeration for possible media types: http://msdn.microsoft.com/en-us/library/windows/desktop/aa366217(v=vs.85).aspx
   .Notes
    NAME:  New-IsoFile
    AUTHOR: Chris Wu
    LASTEDIT: 03/23/2016 14:46:50
 #>

    [CmdletBinding(DefaultParameterSetName='Source')]Param(
    [parameter(Position=1,Mandatory=$true,ValueFromPipeline=$true, ParameterSetName='Source')]$Source,
    [parameter(Position=2)][string]$Path = "$env:temp\$((Get-Date).ToString('yyyyMMdd-HHmmss.ffff')).iso",
    [ValidateScript({Test-Path -LiteralPath $_ -PathType Leaf})][string]$BootFile = $null,
    [ValidateSet('CDR','CDRW','DVDRAM','DVDPLUSR','DVDPLUSRW','DVDPLUSR_DUALLAYER','DVDDASHR','DVDDASHRW','DVDDASHR_DUALLAYER','DISK','DVDPLUSRW_DUALLAYER','BDR','BDRE')][string] $Media = 'DVDPLUSRW_DUALLAYER',
    [string]$Title = (Get-Date).ToString("yyyyMMdd-HHmmss.ffff"),
    [switch]$Force,
    [parameter(ParameterSetName='Clipboard')][switch]$FromClipboard
  )

  Begin {
    ($cp = new-object System.CodeDom.Compiler.CompilerParameters).CompilerOptions = '/unsafe'
    if (!('ISOFile' -as [type])) {
      Add-Type -CompilerParameters $cp -TypeDefinition @'
public class ISOFile
{
  public unsafe static void Create(string Path, object Stream, int BlockSize, int TotalBlocks)
  {
    int bytes = 0;
    byte[] buf = new byte[BlockSize];
    var ptr = (System.IntPtr)(&bytes);
    var o = System.IO.File.OpenWrite(Path);
    var i = Stream as System.Runtime.InteropServices.ComTypes.IStream;

    if (o != null) {
      while (TotalBlocks-- > 0) {
        i.Read(buf, BlockSize, ptr); o.Write(buf, 0, bytes);
      }
      o.Flush(); o.Close();
    }
  }
}
'@
    }

    if ($BootFile) {
      if('BDR','BDRE' -contains $Media) { Write-Warning "Bootable image doesn't seem to work with media type $Media" }
      ($Stream = New-Object -ComObject ADODB.Stream -Property @{Type=1}).Open()  # adFileTypeBinary
      $Stream.LoadFromFile((Get-Item -LiteralPath $BootFile).Fullname)
      ($Boot = New-Object -ComObject IMAPI2FS.BootOptions).AssignBootImage($Stream)
    }

    $MediaType = @('UNKNOWN','CDROM','CDR','CDRW','DVDROM','DVDRAM','DVDPLUSR','DVDPLUSRW','DVDPLUSR_DUALLAYER','DVDDASHR','DVDDASHRW','DVDDASHR_DUALLAYER','DISK','DVDPLUSRW_DUALLAYER','HDDVDROM','HDDVDR','HDDVDRAM','BDROM','BDR','BDRE')

    Write-Verbose -Message "Selected media type is $Media with value $($MediaType.IndexOf($Media))"
    ($Image = New-Object -com IMAPI2FS.MsftFileSystemImage -Property @{VolumeName=$Title}).ChooseImageDefaultsForMediaType($MediaType.IndexOf($Media))

    if (!($Target = New-Item -Path $Path -ItemType File -Force:$Force -ErrorAction SilentlyContinue)) { Write-Error -Message "Cannot create file $Path. Use -Force parameter to overwrite if the target file already exists."; break }
  }

  Process {
    if($FromClipboard) {
      if($PSVersionTable.PSVersion.Major -lt 5) { Write-Error -Message 'The -FromClipboard parameter is only supported on PowerShell v5 or higher'; break }
      $Source = Get-Clipboard -Format FileDropList
    }

    foreach($item in $Source) {
      if($item -isnot [System.IO.FileInfo] -and $item -isnot [System.IO.DirectoryInfo]) {
        $item = Get-Item -LiteralPath $item
      }

      if($item) {
        Write-Verbose -Message "Adding item to the target image: $($item.FullName)"
        try { $Image.Root.AddTree($item.FullName, $true) } catch { Write-Error -Message ($_.Exception.Message.Trim() + ' Try a different media type.') }
      }
    }
  }

  End {
    if ($Boot) { $Image.BootImageOptions=$Boot }
    $Result = $Image.CreateResultImage()
    [ISOFile]::Create($Target.FullName,$Result.ImageStream,$Result.BlockSize,$Result.TotalBlocks)
    Write-Verbose -Message "Target image ($($Target.FullName)) has been created"
  }
}

#from https://d-fens.ch/2013/11/01/nobrainer-using-powershell-to-convert-an-ipv4-subnet-mask-length-into-a-subnet-mask-address/
function Convert-IpAddressToMaskLength([string] $dottedIpAddressString)
{
  $result = 0; 
  # ensure we have a valid IP address
  [IPAddress] $ip = $dottedIpAddressString;
  $octets = $ip.IPAddressToString.Split('.');
  foreach($octet in $octets)
  {
    while(0 -ne $octet) 
    {
      $octet = ($octet -shl 1) -band [byte]::MaxValue
      $result++; 
    }
  }
  return $result;
}

