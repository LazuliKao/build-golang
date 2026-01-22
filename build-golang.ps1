# Build Golang from Source
# This script automates the process of cloning Go source and building it

param(
    [string]$GoVersion = "",
    [string]$SourceDir = "golang_src",
    [string]$BootstrapDir = "go-bootstrap",
    [string]$OutputDir = "go-build"
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Error {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

# Check if Git is installed
function Test-Git {
    try {
        git --version | Out-Null
        return $true
    } catch {
        return $false
    }
}

# Get latest stable Go version
function Get-LatestStableVersion {
    Write-Host "Fetching latest stable Go version..."
    $versionContent = (Invoke-WebRequest -Uri "https://go.dev/VERSION?m=text" -UseBasicParsing).Content.Trim()
    # Extract just the version (e.g., "go1.21.5" from the first line)
    $latestVersion = $versionContent -split "`n" | Select-Object -First 1
    $latestVersion = $latestVersion.Trim()
    Write-Host "Latest stable version: $latestVersion"
    return $latestVersion
}

# Download and extract bootstrap Go
function Get-BootstrapGo {
    Write-Step "Downloading bootstrap Go runtime..."
    
    if (Test-Path $BootstrapDir) {
        Write-Success "Bootstrap Go already exists at $BootstrapDir"
        return
    }

    # Detect architecture
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $os = "windows"
    
    # Get latest stable version
    $latestVersion = Get-LatestStableVersion
    
    $downloadUrl = "https://go.dev/dl/$latestVersion.$os-$arch.zip"
    $zipPath = Join-Path $PSScriptRoot "go-bootstrap.zip"
    
    Write-Host "Downloading from: $downloadUrl"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    
    Write-Host "Extracting to: $BootstrapDir"
    Expand-Archive -Path $zipPath -DestinationPath $BootstrapDir -Force
    
    Remove-Item $zipPath -Force
    Write-Success "Bootstrap Go downloaded and extracted"
}

# Clone Go source repository
function Get-GoSource {
    param([string]$Version)
    
    Write-Step "Cloning Go source repository..."
    
    if (Test-Path $SourceDir) {
        Write-Host "Source directory exists, pulling latest changes..."
        Push-Location $SourceDir
        try {
            git fetch origin
            git checkout $Version
            if ($Version -ne "master") {
                git pull origin $Version
            }
        } finally {
            Pop-Location
        }
        Write-Success "Go source updated to $Version"
    } else {
        Write-Host "Cloning Go repository (version: $Version)..."
        git clone --depth 1 --branch $Version https://go.googlesource.com/go $SourceDir
        Write-Success "Go source cloned (version: $Version)"
    }
}

# Apply PR patch to Go source
function Apply-PRPatch {
    param([int]$PRNumber)
    
    Write-Step "Applying PR #$PRNumber patch..."
    
    $patchUrl = "https://github.com/golang/go/pull/$PRNumber.patch"
    $patchPath = Join-Path $PSScriptRoot "pr-$PRNumber.patch"
    
    try {
        Write-Host "Downloading patch from: $patchUrl"
        Invoke-WebRequest -Uri $patchUrl -OutFile $patchPath -UseBasicParsing
        
        Push-Location $SourceDir
        try {
            Write-Host "Applying patch to source..."
            # Use git apply to apply the patch
            git apply --verbose $patchPath
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "git apply failed, trying with --3way..." -ForegroundColor Yellow
                git apply --3way --verbose $patchPath
                
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to apply patch with exit code $LASTEXITCODE"
                }
            }
            
            Write-Success "PR #$PRNumber patch applied successfully"
        } finally {
            Pop-Location
        }
    } finally {
        # Clean up patch file
        if (Test-Path $patchPath) {
            Remove-Item $patchPath -Force
        }
    }
}

# Build Go from source
function Build-Go {
    Write-Step "Building Go from source..."
    
    $bootstrapGoRoot = Resolve-Path (Join-Path $BootstrapDir "go") | Select-Object -ExpandProperty Path
    $srcPath = Join-Path $SourceDir "src"
    
    if (-not (Test-Path $srcPath)) {
        throw "Source directory not found: $srcPath"
    }
    
    # Set environment variables
    $env:GOROOT_BOOTSTRAP = $bootstrapGoRoot
    $env:GOROOT = (Resolve-Path $SourceDir).Path
    
    Write-Host "GOROOT_BOOTSTRAP: $env:GOROOT_BOOTSTRAP"
    Write-Host "GOROOT: $env:GOROOT"
    
    Push-Location $srcPath
    try {
        # Run the build script
        if (Test-Path ".\make.bat") {
            Write-Host "Running make.bat..."
            cmd /c "make.bat"
            if ($LASTEXITCODE -ne 0) {
                throw "Build failed with exit code $LASTEXITCODE"
            }
        } else {
            throw "make.bat not found in $srcPath"
        }
    } finally {
        Pop-Location
    }
    
    Write-Success "Go built successfully"
}

# Copy built Go to output directory
function Copy-GoOutput {
    Write-Step "Copying built Go to output directory..."
    
    if (Test-Path $OutputDir) {
        Write-Host "Removing existing output directory..."
        Remove-Item $OutputDir -Recurse -Force
    }
    
    Copy-Item $SourceDir $OutputDir -Recurse -Force
    Write-Success "Go copied to $OutputDir"
}

# Verify the build
function Test-GoBuild {
    Write-Step "Verifying Go build..."
    
    $goExe = Join-Path $OutputDir "bin\go.exe"
    
    if (-not (Test-Path $goExe)) {
        throw "Go executable not found: $goExe"
    }
    
    $version = & $goExe version
    Write-Host "Built version: $version"
    Write-Success "Build verification passed"
}

# Main execution
try {
    Write-Host @"
╔════════════════════════════════════════╗
║   Go Build Script for Windows          ║
╚════════════════════════════════════════╝
"@ -ForegroundColor Yellow

    # Determine version to build
    if ([string]::IsNullOrEmpty($GoVersion)) {
        $GoVersion = Get-LatestStableVersion
        Write-Host "Auto-detected version: $GoVersion" -ForegroundColor Cyan
    }

    Write-Host "Configuration:"
    Write-Host "  Go Version: $GoVersion"
    Write-Host "  Source Dir: $SourceDir"
    Write-Host "  Bootstrap Dir: $BootstrapDir"
    Write-Host "  Output Dir: $OutputDir"
    
    # Check prerequisites
    if (-not (Test-Git)) {
        Write-Error "Git is not installed or not in PATH"
        exit 1
    }
    
    # Execute build steps
    Get-BootstrapGo
    Get-GoSource -Version $GoVersion
    Apply-PRPatch -PRNumber 75048
    Build-Go
    Copy-GoOutput
    Test-GoBuild
    
    Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║   Build completed successfully!        ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host "`nGo is available at: $(Resolve-Path $OutputDir)" -ForegroundColor Cyan
    Write-Host "Add to PATH: $(Join-Path (Resolve-Path $OutputDir) 'bin')" -ForegroundColor Cyan
    
} catch {
    Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║   Build failed!                        ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Red
    Write-Error $_.Exception.Message
    exit 1
}
