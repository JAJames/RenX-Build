function ForceDesktopSession {
    $LoggedInUser = $Env:USERNAME

    # Get list of users
    $UserSessions = $(quser | ForEach-Object -Process { $_ -replace '\s{2,}',',' } | ConvertFrom-CSV)
    ForEach ($UserSession in $UserSessions) {
        if ($UserSession.USERNAME -eq "$LoggedInUser" -or
            $UserSession.USERNAME -eq ">$LoggedInUser") {
            # Found our user; check if we're in a session or not
            if ($UserSession.STATE -eq "Disc" -or
                $UserSession.ID -eq "Disc") {
                # Our session state is disconnected; open up the console
                $username = $UserSession.USERNAME;
                Write-Host "$LoggedInUser is disconnected; opening console"
                tscon $UserSession.SESSIONNAME /dest:console
                sleep 10 # Give Windows some time to init the console session
            }
            break
        }
    }
}

function PrepRootDir {
    Param(
        [string]$RootDir
    )

    # Add this directory to windows defender
    Write-Host "Adding Windows Defender exclusion..."
    Add-MpPreference -ExclusionPath "$RootDir"
}

function PrepSVN {
    Param(
        [string]$UdkPath,
        [string]$UdkUrl,
        [int]$TargetRevision,
        [string]$SvnUsername="",
        [string]$SvnPassword=""
    )

    if (![System.IO.Directory]::Exists("$UdkPath")) {
        Write-Host "Checking out UDK_Uncooked..."
        if (![string]::IsNullOrWhiteSpace($SvnUsername) -and
            ![string]::IsNullOrWhiteSpace($SvnPassword)) {
            svn checkout --non-interactive --trust-server-cert --username $SvnUsername --password $SvnPassword $UdkUrl $UdkPath
        }
        else {
            svn checkout $UdkUrl $UdkPath
        }
    }

    # Revert any local changes
    svn revert --recursive $UdkPath

    # Update UDK to latest revision
    if ($TargetRevision -eq 0) {
        svn update $UdkPath
    }
    else {
        svn update -r $TargetRevision $UdkPath
    }
}

function GetSvnRevision {
    Param(
        [string]$SvnPath
    )

    return (svn info --show-item revision $SvnPath)
}

function GetVersionData {
    Param(
        [string]$VersionUrl
    )

    Invoke-WebRequest "$VersionUrl" | Select-Object -ExpandProperty Content | ConvertFrom-Json
}

function GetBranchConfig {
    Param(
        [string]$BuildPath,
        [string]$SourceBranch
    )

    $ConfigData = (Get-Content "$BuildPath\config.json" | ConvertFrom-Json)
    $ConfigBranchData = $ConfigData.branches.$SourceBranch
    return $ConfigBranchData
}

function GetTypeConfig {
    Param(
        [string]$BuildPath,
        [string]$BuildType
    )

    $ConfigData = (Get-Content "$BuildPath\config.json" | ConvertFrom-Json)
    $ConfigTypeData = $ConfigData.types.$BuildType
    return $ConfigTypeData
}

function GetNodeConfig {
    Param(
        [string]$BuildPath,
        [string]$NodeName
    )

    $ConfigData = (Get-Content "$BuildPath\config.json" | ConvertFrom-Json)
    if ([string]::IsNullOrEmpty($NodeName) -or
        !$ConfigData.nodes.$NodeName) {
        Write-Host "No config for $NodeName found; using default"
        $NodeName = "default"
    }

    $ConfigNodeData = $ConfigData.nodes.$NodeName
    return $ConfigNodeData
}

function GetBuildType {
    Param(
        [string]$BuildPath,
        [string]$SourceBranch,
        [string]$BuildType="Auto"
    )

    if ($BuildType -eq "Auto") {
        $BuildType = (GetBranchConfig "$BuildPath" "$SourceBranch").type
        if (!$BuildType) {
            Write-Host "ERROR: Config not found for branch '$SourceBranch'"
            exit 1;
        }
    }

    return $BuildType
}

function OmitCodePackage {
    Param(
        [string]$UdkPath,
        [string]$PackageName
    )

    $EngineFile = "$UdkPath\UDKGame\Config\DefaultEngineUDK.ini"
    $PackageRegex = "^\+ModEditPackages=${PackageName}`$"
    (Get-Content $EngineFile) -replace "$PackageRegex", "" | Set-Content $EngineFile
}

function OmitCodePackages {
    Param(
        [string]$UdkPath,
        [string[]]$PackageNames
    )

    foreach ($PackageName in $PackageNames) {
        OmitCodePackage "$UdkPath" "$PackageName"
    }
}

function CleanupSVN {
    Param(
        [string]$UdkPath
    )

    # Delete unversioned files created by previous runs (logs, generated INIs)
    $ChangedFilesList = (svn status --no-ignore $UdkPath)
    foreach ($ChangedFileEntry in $ChangedFilesList) {
        $ChangedFileName = $ChangedFileEntry.Substring(1).Trim()
        # Match unversioned (?) or ignored (I) files ending with: .ini, .log, .dmp
        if ($ChangedFileEntry -match "^(\?|I).+\.(ini|log|dmp)$") {
            Remove-Item -Path $ChangedFileName
        }
    }

    # Delete CookedPC from previous runs
    if ([System.IO.Directory]::Exists("$UdkPath\UDKGame\CookedPC\")) {
        Write-Host "Deleting CookedPC..."
        Remove-Item -Recurse -Force "$UdkPath\UDKGame\CookedPC\"
    }
}

function MakeChangelog {
    Param(
        [string]$UdkPath,
        [int]$OldRevision,
        [int]$NewRevision
    )

    svn log -v -r ${OldRevision}:${NewRevision} "$UdkPath" | Out-File changelog.txt
}

function BuildScripts {
    Param(
        [string]$UdkExePath
    )

    & "$UdkExePath" make -full -buildmachine -stripsource -auto -unattended -nopause
}

function BuildShaders {
    Param(
        [string]$UdkPath
    )

    # Calculate paths
    $MapsRootDir = "$UdkPath\UDKGame\Content\Maps"
    $UdkExePath = "$UdkPath\Binaries\Win64\UDK.exe"
    $RevisionFile = "$UdkPath\build\shaders_last_run.txt"

    # Build MapsDirs
    $MapsDirs = New-Object System.Collections.Generic.List[System.String]
    $MapsDirs += "$MapsRootDir\RenX"
    $MapsDirs += "$MapsRootDir\TiberianSun"

    # Get last revision this script ran for
    $LastRevision = 0
    if ([System.IO.File]::Exists($RevisionFile)) {
        $LastRevision = Get-Content $RevisionFile
    }
    $CurrentRevision = (GetSvnRevision $UdkPath)

    # Get list of modified files
    $Files = New-Object System.Collections.Generic.List[System.String]
    foreach ($MapsDir in $MapsDirs) {
        $ChangedFilesList = (svn diff "-r${LastRevision}:${CurrentRevision}" --summarize "$MapsDir")
        foreach ($ChangedFileEntry in $ChangedFilesList) {
            $ChangedFileName = $ChangedFileEntry.Substring(1).Trim()
            if ([System.IO.File]::Exists($ChangedFileName)) {
                $Files += $ChangedFileName
            }
        }
    }

    # Open each map to build shaders
    foreach ($File in $Files) {
        # Get package name from file
        $PackageName = [System.IO.Path]::GetFileNameWithoutExtension($File)

        # Open each level with exec script to build shaders
        # Note: not using 'server' for now, since it seems not to respect -EXEC, possibly because it's a "rendering" option
        Write-Host "Building shaders for: $PackageName"
        $Cmd = "server ${PackageName}?mutator=RenX_ExampleMutators.ShaderHelper?bIsLanMatch=true -auto -unattended -nopause"
        Start-Process -Wait -FilePath "$UdkExePath" -ArgumentList "$Cmd"
    }

    echo $CurrentRevision | Out-File $RevisionFile
}

function CookGame {
    Param(
        [string]$UdkPath,
        [string]$CookParams
    )
    $UdkExePath = "$UdkPath\Binaries\Win64\UDK.com"
    ForceDesktopSession

    & "$UdkExePath" CookPackages $CookParams
    $CookExitCode = $LASTEXITCODE

    # Check if cook failed (exit code != 0)
    if ($CookExitCode -ne 0) {
        Write-Host "ERROR: Cook failed with exit code $CookExitCode"
        exit 1
    }

    # Check if cook succeeded
    if (Get-ChildItem "$UdkPath\UDKGame\CookedPC\Process_*") {
        Write-Host "ERROR: Cook failed to complete (Process paths are still present). Exiting..."
        exit 1
    }
}

function StageCookedPC {
    Param(
        [string]$UdkPath,
        [string]$BuildType
    )

    $CookedPCPath = "$UdkPath\UDKGame\CookedPC"
    $TypedCookedPCPath = "$UdkPath\UDKGame\CookedPC_${BuildType}"

    if ([System.IO.Directory]::Exists($TypedCookedPCPath)) {
        Copy-Item -Path $TypedCookedPCPath -Destination $CookedPCPath -Recurse
    }
}

function UnstageCookedPC {
    Param(
        [string]$UdkPath,
        [string]$BuildType
    )

    $CookedPCPath = "$UdkPath\UDKGame\CookedPC"
    $TypedCookedPCPath = "$UdkPath\UDKGame\CookedPC_${BuildType}"

    if ([System.IO.Directory]::Exists($CookedPCPath)) {
        if ([System.IO.Directory]::Exists($TypedCookedPCPath)) {
            Remove-Item -Recurse -Force "$TypedCookedPCPath"
        }

        Rename-Item -Path $CookedPCPath -NewName $TypedCookedPCPath
    }
}

function BuildUdk {
    Param(
        [string]$UdkPath,
        [string]$BuildType
    )
    $UdkExePath = "$UdkPath\Binaries\Win64\UDK.com"
    $BuildPath = "$UdkPath\build"
    $TypeConfigData = (GetTypeConfig "$BuildPath" "$BuildType")

    # Omit private code packages where necessary
    OmitCodePackages "$UdkPath" $TypeConfigData.excluded_code

    # Cleanup SVN data from previous runs
    Write-Host "Cleaning up SVN from previous builds..."
    CleanupSVN "$UdkPath"

    # Move in working CookedPC
    Write-Host "Staging CookedPC for $BuildType build..."
    StageCookedPC "$UdkPath" "$BuildType"

    # Compile scripts
    Write-Host "Compiling scripts..."
    BuildScripts "$UdkExePath"

    # Build shaders for all changed levels
    Write-Host "Building shaders..."
    BuildShaders "$UdkPath"
    Write-Host "Shader build finished"

    # Cook packages
    if ($TypeConfigData.cook) {
        Write-Host "Cooking packages..."
        $CookParams = (GetNodeConfig "$BuildPath" $Env:NODE_NAME).cook_params
        CookGame "$UdkPath" "$CookParams"
    }
}

function GetIncludedFiles {
    Param(
        [string]$UdkPath,
        [string]$BuildType
    )
    $BuildPath = "$UdkPath\build"

    # Read inclusion expressions
    $IncludeExpressions = (Get-Content $BuildPath\expressions.include.txt)
    if ([System.IO.File]::Exists("$BuildPath\expressions.include.$BuildType.txt")) {
        $IncludeExpressions += (Get-Content "$BuildPath\expressions.include.$BuildType.txt")
    }

    # Read map list into inclusion expressions
    $IncludeLevels = (Get-Content $BuildPath\levels.include.txt)
    if ([System.IO.File]::Exists("$BuildPath\levels.include.$BuildType.txt")) {
        $IncludeLevels += (Get-Content "$BuildPath\levels.include.$BuildType.txt")
    }

    foreach ($LevelName in $IncludeLevels) {
        if ((![string]::IsNullOrWhiteSpace($LevelName)) -and # Ignore blank lines
            (!$LevelName.StartsWith("#"))) { # Ignore comments/headers
            $IncludeExpressions += "^PreviewVids\\$LevelName\..+$"
            $IncludeExpressions += "^UDKGame\\Config\\$LevelName.ini$"
            $IncludeExpressions += "^UDKGame\\Content\\Maps\\[A-Za-z]+\\$LevelName.udk$"
            $IncludeExpressions += "^UDKGame\\Movies\\LoadingScreen_$LevelName.bik$"
        }
    }

    # Checks if a file matches inclusion lists
    function MatchesInclude {
        param (
            [string]$FilePath
        )

        # Iterate over all expressions and check if FilePath matches ANY of them
        foreach ($Expression in $IncludeExpressions) {
            if ((![string]::IsNullOrWhiteSpace($Expression)) -and # Ignore blank lines
                (!$Expression.StartsWith("#")) -and # Ignore comments/headers
                ([System.IO.File]::Exists("$UdkPath\$FilePath")) -and # Ignore non-files
                ($FilePath -match $Expression)) { # Check if the path matches this expression
                return $true
            }
        }

        return $false
    }

    # Compile list of files to copy from SVN
    Write-Host "Scanning SVN for necessary files..."
    $Files = (Get-ChildItem -Recurse $UdkPath)
    $IncludedFiles = New-Object System.Collections.Generic.List[System.String]
    foreach ($File in $Files) {
        # Check if file matches inclusion list
        $Filename = $File.FullName.Substring($UdkPath.Length + 1)
        if (MatchesInclude $Filename) {
            $IncludedFiles += $Filename
        }
    }

    echo $IncludedFiles | Out-File included_files.txt
    return $IncludedFiles
}

function GenerateBuildData {
    Param(
        [string]$RootDir,
        [string]$UdkPath,
        [string]$BuildType,
        [string]$PatchName,
        [string]$VersionUrl
    )
    $CurrentRevision = (GetSvnRevision $UdkPath)

    Write-Host "Generating new build"
    $NewBuildPath = "$RootDir\Build${CurrentRevision}"
    $IncludedFiles = (GetIncludedFiles "$UdkPath" "$BuildType")
    $RetargetData = (GetTypeConfig "$UdkPath\build" "$BuildType").retargets

    # Copy included files over to new build
    Write-Host "Copying files from SVN..."
    foreach ($Filename in $IncludedFiles) {
        $SourceFilePath = "$UdkPath\$Filename"
        $TargetFilePath = "$NewBuildPath\$Filename"

        # If it's from Content, copy it to CookedPC instead (i.e: Maps); note: retarget strings moved to config.json
        foreach ($Retarget in $RetargetData) {
            if ($Filename -match $Retarget.source) {
                $TargetFilename = $Filename -replace $Retarget.source, $RetargetData.target
                $TargetFilePath = "$NewBuildPath\$TargetFilename"
                break
            }
        }

        # Create parent directories
        New-Item -ItemType File -Force "$TargetFilePath" | Out-Null
        Remove-Item $TargetFilePath

        # Copy file
        Write-Host "Copying $Filename..."
        Copy-Item -Force "$SourceFilePath" "$TargetFilePath"
    }

    # Update version in INI
    Write-Host "Updating version file..."
    $VersionFile = "$NewBuildPath\UDKGame\Config\DefaultRenegadeX.ini"
    $VersionStringRegex = '^GameVersion=".+"$'
    $VersionNumberRegex = '^GameVersionNumber=.+$'
    $VersionUrlRegex = '^MasterVersionURL=.+$'
    (Get-Content $VersionFile) -replace $VersionStringRegex, "GameVersion=`"${PatchName}`"" | Set-Content $VersionFile
    (Get-Content $VersionFile) -replace $VersionNumberRegex, "GameVersionNumber=$CurrentRevision" | Set-Content $VersionFile
    (Get-Content $VersionFile) -replace $VersionUrlRegex, "MasterVersionURL=$VersionUrl" | Set-Content $VersionFile
}

function PrepRxPatch {
    Param(
        [string]$RxPatchPath,
        [string]$RxPatchUrl
    )

    # Checkout RXPatch if it doesn't exist
    if (![System.IO.Directory]::Exists("$RxPatchPath")) {
        Write-Host "Checkout RXPatch..."
        svn checkout $RxPatchUrl
    }

    # Enter RXPatch
    svn update $RxPatchPath
}

function PullGameBuild {
    Param(
        [string]$BuildUrl,
        [string]$BuildPath,
        [string]$RxPatchExe
    )
    $PatchWorkPath = "${BuildPath}_patch_tmp"

    # Prep paths
    if (![System.IO.Directory]::Exists("$BuildPath")) {
        New-Item -ItemType "Directory" $BuildPath | Out-Null
    }

    # Pull old build
    & "$RxPatchExe" apply_web $BuildUrl $BuildPath $PatchWorkPath

    # Cleanup PatchWorkPath
    Remove-Item $PatchWorkPath -Recurse -Force
}

function GeneratePatchData {
    Param(
        [string]$PatchDataPath,
        [string]$OldBuildPath,
        [string]$NewBuildPath,
        [string]$RxPatchExe
    )

    $ArgsFilePath = (New-TemporaryFile).FullName

    # Write args file
    $ArgsJson = [ordered]@{
        OldPath = "$OldBuildPath"
        NewPath = "$NewBuildPath"
        PatchPath = "$PatchDataPath"
    }

    echo $ArgsJson | ConvertTo-Json | Out-File $ArgsFilePath

    # Cleanup any old patch data
    if ([System.IO.Directory]::Exists($PatchDataPath)) {
        Remove-Item -Recurse -Force $PatchDataPath
    }

    # Build new patch data
    & "$RxPatchExe" create $ArgsFilePath

    # Cleanup args file
    Remove-Item -Force $ArgsFilePath
}

function PublishPatchData {
    Param(
        [string]$SSHKey,
        [string]$SSHUsername,
        [string]$Destination,
        [string]$PatchDataPath
    )
    $CurrentUsername = [Environment]::UserName

    Write-Host "Setting permissions on SSH key..."
    Icacls $SSHKey /c /t /Inheritance:d # Remove Inheritance
    Icacls $SSHKey /c /t /Grant "${CurrentUsername}:F" # Set Ownership to Owner
    Icacls $SSHKey /c /t /Remove "Authenticated Users" BUILTIN\Administrators BUILTIN Everyone System Users # Remove All Users, except for Owner

    Write-Host "Pushing data to VCS..."
    scp -i "$SSHKey" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -r "$PatchDataPath" "$SSHUsername@$Destination"

    # TODO: Replace this with a build step in pipeline
    Write-Host "Triggering sync for mirrors..."
    ssh -i "$SSHKey" -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL "$SSHUsername@vcs.glitchware.com" "/home/renx/patches/updaterepos.sh"

    Write-Host "Patch data pushed to mirrors. Deleting local data..."
    Remove-Item -Recurse -Force $PatchDataPath
}

function MakePatchData {
    Param(
        [string]$RootDir,
        [string]$UdkPath,
        [string]$BuildType,
        [string]$PatchName,
        [string]$SourceBranch,
        [switch]$DeleteBuild
    )
    $BuildPath = "$UdkPath\build"
    $RxPatchPath = "$RootDir\RXPatch"
    $RxPatchUrl = "svn://svn.renegade-x.com/svn/main/RXPatch"
    $RxPatchExe = "$RxPatchPath\RXPatch.exe"
    $CurrentRevision = (GetSvnRevision $UdkPath)
    $NewBuildPath = "$RootDir\Build${CurrentRevision}"
    $TypeConfig = GetTypeConfig "$BuildPath" "$BuildType"
    $PatchPrefix = $TypeConfig.prefix
    $ProductKey = $TypeConfig.product
    $PatchDataName = "${PatchPrefix}${CurrentRevision}"
    $PatchDataPath = "$RootDir\$PatchDataName"
    $MirrorUrl = (GetNodeConfig "$BuildPath" $Env:NODE_NAME).pull_mirror

    # Get current version info
    Write-Host "Fetching version info..."
    $VersionUrl = "https://static.renegade-x.com/launcher_data/version/${SourceBranch}.json"
    $VersionData = (GetVersionData "$VersionUrl")
    $OldBuildNum = $VersionData.$ProductKey.version_number
    $OldBuildPatchPath = $VersionData.$ProductKey.patch_path
    $OldBuildUrl = "${MirrorUrl}${OldBuildPatchPath}"
    $OldBuildPath = "$RootDir\Build${OldBuildNum}"

    # Compose changelog
    MakeChangelog "$UdkPath" "$OldBuildNum" "$CurrentRevision"

    # Compose new build data
    GenerateBuildData "$RootDir" "$UdkPath" "$BuildType" "$PatchName" "$VersionUrl" | Write-Host
    UnstageCookedPC "$UdkPath" "$BuildType"

    # Prepare RXPatch for patching
    PrepRxPatch "$RxPatchPath" "$RxPatchUrl" | Write-Host

    # Pull old patch data
    Write-Host "Pulling previous build..."
    PullGameBuild "$OldBuildUrl" "$OldBuildPath" "$RxPatchExe" | Write-Host

    # Generate patch data
    Write-Host "Generating patch data"
    GeneratePatchData "$PatchDataPath" "$OldBuildPath" "$NewBuildPath" "$RxPatchExe" | Write-Host

    # Cleanup build files
    Remove-Item -Recurse -Force $OldBuildPath
    if ($DeleteBuild) {
        Remove-Item -Recurse -Force $NewBuildPath
    }

    # Verify instructions.json is generated, and report failure if it's not present
    if (![System.IO.File]::Exists("$PatchDataPath\instructions.json")) {
        Write-Host "Patch data failed to generate"
        Exit 1
    }

    Write-Host "Patch data generated successfully"
    return $PatchDataName
}
