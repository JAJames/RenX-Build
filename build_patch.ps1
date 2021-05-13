Param(
    [string]$BuildType="Auto",
	[string]$SourceBranch="release",
    [string]$PatchName="Open Beta 5.1234", # TODO: make non-optional
    [int]$TargetRevision=0,
    [switch]$Jenkins
)

# Constants
$UdkUrl = "svn://svn.renegade-x.com/svn/main/UDK_Uncooked"
$RootDir = (Get-Location).ProviderPath
$UdkPath = "$RootDir\UDK_Uncooked"
$BuildPath = "$UdkPath\build"

### STAGE 1: Prepare Workspace
# Requires: UdkPath, UdkUrl, TargetRevision, RootDir, BuildPath

function PrepSVN {
    Param(
        [string]$UdkPath,
        [string]$UdkUrl,
        [int]$TargetRevision
    )

    if (![System.IO.Directory]::Exists("$UdkPath")) {
        Write-Host "Checking out UDK_Uncooked..."
        svn checkout $UdkUrl
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

# Checkout/update SVN to target revision
PrepSVN "$UdkPath" "$UdkUrl" "$TargetRevision"
. "$BuildPath\scripts\common.ps1"

# Prepare RootDir for build
PrepRootDir "$RootDir"

### STAGE 2: Build
# Requires: BuildPath, SourceBranch, BuildType, UdkPath

# Pull config data if type Auto
$BuildType = (GetBuildType "$BuildPath" "$SourceBranch" -BuildType "$BuildType")

# Build UDK
BuildUdk "$UdkPath" "$BuildType"

### STAGE 3: Make patch
# Requires: RootDir, UdkPath, BuildType, PatchName, SourceBranch

# Make patch data
$PatchDataName = (MakePatchData "$RootDir" "$UdkPath" "$BuildType" "$PatchName" "$SourceBranch" -DeleteBuild)
echo "PatchDataName: $PatchDataName"

### STAGE 4: Publish patch
# Requires: Env:SSHKey, Env:SSHUsername, RootDir, PatchDataName

# Publish patch data
if ($Jenkins) {
    PublishPatchData $Env:SSHKey $Env:SSHUsername "vcs.glitchware.com:/home/renx/patches/data/" "$RootDir\$PatchDataName"
    echo "Build complete. Run the `"Set Game Version`" Jenkins plan to point the appropriate branch to $PatchDataName"
}
