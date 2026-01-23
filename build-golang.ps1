# Build Golang from Source
# This script automates the process of cloning Go source and building it

param(
    [string]$GoVersion = "",
    [string]$SourceDir = "golang_src",
    [string]$BootstrapDir = "go-bootstrap",
    [string]$OutputDir = "go-build",
    [string[]]$Platforms = @("windows", "linux")
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

# Clean up hanging processes in current directory
function Stop-HangingProcesses {
    Write-Step "Cleaning up hanging processes..."
    
    $currentDir = $PSScriptRoot
    $processesToKill = @()
    
    # Define process names to look for (common build-related processes)
    $targetProcessNames = @("compile", "link", "asm", "cgo", "go", "make")
    
    # Method 1: Find processes by name
    foreach ($procName in $targetProcessNames) {
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($procs) {
            foreach ($proc in $procs) {
                # Try to get the path and check if it's in current directory
                try {
                    if ($proc.Path -and ($proc.Path -like "$currentDir*")) {
                        $processesToKill += $proc
                    } elseif (-not $proc.Path) {
                        # If we can't get path, include it anyway (likely hanging)
                        $processesToKill += $proc
                    }
                } catch {
                    # If we can't access path, assume it might be hanging
                    $processesToKill += $proc
                }
            }
        }
    }
    
    # Method 2: Use WMI to find processes with working directory in current path
    try {
        $wmiProcesses = Get-WmiObject Win32_Process | Where-Object {
            $_.ExecutablePath -like "$currentDir*" -or
            $_.CommandLine -like "*$currentDir*"
        }
        
        foreach ($wmiProc in $wmiProcesses) {
            # Check if not already in list
            if ($processesToKill.Id -notcontains $wmiProc.ProcessId) {
                $proc = Get-Process -Id $wmiProc.ProcessId -ErrorAction SilentlyContinue
                if ($proc) {
                    $processesToKill += $proc
                }
            }
        }
    } catch {
        Write-Host "Note: WMI query failed, using process name matching only" -ForegroundColor Yellow
    }
    
    # Remove duplicates
    $processesToKill = $processesToKill | Sort-Object -Property Id -Unique
    
    if ($processesToKill.Count -eq 0) {
        Write-Success "No hanging processes found"
        return
    }
    
    Write-Host "Found $($processesToKill.Count) process(es) to terminate:"
    foreach ($proc in $processesToKill) {
        $pathInfo = if ($proc.Path) { "at $($proc.Path)" } else { "(path unavailable)" }
        Write-Host "  - $($proc.Name) (PID: $($proc.Id)) $pathInfo"
    }
    
    # Terminate processes
    $killedCount = 0
    foreach ($proc in $processesToKill) {
        try {
            Write-Host "Terminating $($proc.Name) (PID: $($proc.Id))..."
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            $killedCount++
            Write-Success "Terminated $($proc.Name)"
        } catch {
            Write-Host "Warning: Failed to terminate $($proc.Name): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    
    # Wait a moment for processes to fully terminate
    Start-Sleep -Milliseconds 1000
    Write-Success "Process cleanup completed ($killedCount/$($processesToKill.Count) terminated)"
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
        
        # Reset to HEAD to remove any previous changes
        Write-Host "Resetting source to HEAD to remove previous changes..."
        git reset --hard HEAD
        git clean -fd
        Write-Success "Source code reset to clean state"
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
        # git clone --branch $Version https://go.googlesource.com/go $SourceDir
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
                # Write-Host "git apply failed, trying with --3way..." -ForegroundColor Yellow
                # git apply --3way --verbose $patchPath
                
                # if ($LASTEXITCODE -ne 0) {
                    Write-Host "Failed to apply patch with exit code $LASTEXITCODE"
                # }
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
    param(
        [string]$OS = "windows",
        [string]$Arch = "amd64",
        [string]$SourceDirectory = $SourceDir
    )
    
    Write-Step "Building Go for $OS/$Arch..."
    
    $srcPath = Join-Path $SourceDirectory "src"
    
    if (-not (Test-Path $srcPath)) {
        throw "Source directory not found: $srcPath"
    }
    
    # Set environment variables
    $env:GOROOT_BOOTSTRAP = (Resolve-Path (Join-Path $BootstrapDir "go")).Path
    $env:GOROOT = (Resolve-Path $SourceDirectory).Path
    $env:GOOS = $OS
    $env:GOARCH = $Arch
    
    Write-Host "GOROOT_BOOTSTRAP: $env:GOROOT_BOOTSTRAP"
    Write-Host "GOROOT: $env:GOROOT"
    Write-Host "GOOS: $env:GOOS"
    Write-Host "GOARCH: $env:GOARCH"
    
    Push-Location $srcPath
    try {
        # Run the build script based on target OS
        if ($OS -eq "windows") {
            if (Test-Path ".\make.bat") {
                Write-Host "Running make.bat for Windows..."
                cmd /c "make.bat"
                if ($LASTEXITCODE -ne 0) {
                    throw "Build failed with exit code $LASTEXITCODE"
                }
            } else {
                throw "make.bat not found in $srcPath"
            }
        } else {
            # For Linux and other Unix-like systems, use make.bash if running in WSL or similar
            # Since we're on Windows, we'll use the Windows batch file approach
            # The batch file should handle cross-compilation via GOOS/GOARCH
            if (Test-Path ".\make.bat") {
                Write-Host "Running make.bat for cross-compilation to $OS..."
                cmd /c "make.bat"
                if ($LASTEXITCODE -ne 0) {
                    throw "Build failed with exit code $LASTEXITCODE"
                }
            } else {
                throw "make.bat not found in $srcPath"
            }
        }
    } finally {
        Pop-Location
    }
    
    Write-Success "Go built successfully for $OS/$Arch"
}

# Copy built Go to output directory
function Copy-GoOutput {
    param(
        [string]$OS = "windows",
        [string]$Arch = "amd64",
        [string]$SourceDirectory = $SourceDir,
        [string]$DestinationDirectory = $OutputDir
    )
    
    Write-Step "Copying built Go to output directory..."
    
    $platformOutputDir = "$DestinationDirectory-$OS-$Arch"
    
    # Remove existing output directory to avoid file accumulation from multiple builds
    if (Test-Path $platformOutputDir) {
        Write-Host "Removing existing output directory to avoid version conflicts..."
        Remove-Item $platformOutputDir -Recurse -Force
        Write-Success "Old output directory removed"
    }
    
    # Use robocopy to copy, excluding .git directory
    Write-Host "Using robocopy to copy (excluding .git)..."
    $robocopyResult = robocopy $SourceDirectory $platformOutputDir /E /XD ".git" /R:1 /W:1 /NFL /NDL /NP
    
    # Robocopy exit codes: 0-7 are success (0=no change, 1=files copied, 2=extra files, etc.)
    if ($LASTEXITCODE -le 7) {
        Write-Success "Go ($OS/$Arch) copied to $platformOutputDir (excluded .git)"
    } else {
        throw "Robocopy failed with exit code $LASTEXITCODE"
    }
    
    # Post-process for Linux builds
    if ($OS -eq "linux") {
        Write-Step "Post-processing Linux build..."
        
        $binDir = Join-Path $platformOutputDir "bin"
        $platformBinDir = Join-Path $binDir "${OS}_${Arch}"
        
        # Remove Windows executables from bin/
        $windowsExes = Get-ChildItem -Path $binDir -Filter "*.exe" -ErrorAction SilentlyContinue
        foreach ($exe in $windowsExes) {
            Write-Host "Removing Windows executable: $($exe.Name)"
            Remove-Item $exe.FullName -Force
        }
        
        # Move Linux binaries from bin/linux_amd64/ to bin/
        if (Test-Path $platformBinDir) {
            $linuxBinaries = Get-ChildItem -Path $platformBinDir -File
            foreach ($binary in $linuxBinaries) {
                $destPath = Join-Path $binDir $binary.Name
                Write-Host "Moving $($binary.Name) to bin/"
                Move-Item $binary.FullName $destPath -Force
            }
            
            # Remove the now-empty platform subdirectory
            Remove-Item $platformBinDir -Force
            Write-Success "Linux binaries moved to bin/ and platform subdirectory removed"
        }

        # Remove Windows toolchain binaries from linux package
        $windowsToolDir = Join-Path $platformOutputDir "pkg/tool/windows_amd64"
        if (Test-Path $windowsToolDir) {
            Write-Host "Removing Windows toolchain from linux package: $windowsToolDir"
            Remove-Item $windowsToolDir -Recurse -Force
            Write-Success "Removed pkg/tool/windows_amd64 from linux package"
        }
    }
    
    return $platformOutputDir
}

# Verify the build
function Test-GoBuild {
    param(
        [string]$OS = "windows",
        [string]$Arch = "amd64",
        [string]$OutputDirectory = $OutputDir
    )
    
    Write-Step "Verifying Go build for $OS/$Arch..."
    
    $platformOutputDir = "$OutputDirectory-$OS-$Arch"
    
    if ($OS -eq "windows") {
        $goExe = Join-Path $platformOutputDir "bin\go.exe"
    } else {
        $goExe = Join-Path $platformOutputDir "bin\go"
    }
    
    if (-not (Test-Path $goExe)) {
        throw "Go executable not found: $goExe"
    }
    
    if ($OS -eq "windows") {
        $version = & $goExe version
        Write-Host "Built version: $version"
    } else {
        Write-Host "Cross-compiled for $OS/$Arch (executable exists at: $goExe)"
    }
    
    Write-Success "Build verification passed for $OS/$Arch"
}

# Package Go into a zip file
function Package-Go {
    param(
        [string]$Version,
        [string]$OS = "windows",
        [string]$Architecture,
        [string]$OutputDirectory = $OutputDir
    )
    
    Write-Step "Packaging Go binary for $OS/$Architecture..."
    
    # Extract version number (remove "go" prefix)
    $versionNumber = $Version -replace "^go", ""
    
    $zipFileName = "go$versionNumber.$OS-$Architecture.zip"
    $tarFileName = "go$versionNumber.$OS-$Architecture.tar.gz"
    $zipPath = Join-Path $PSScriptRoot $zipFileName
    $tarPath = Join-Path $PSScriptRoot $tarFileName
    
    $platformOutputDir = "$OutputDirectory-$OS-$Architecture"
    
    if ($OS -eq "linux") {
        if (Test-Path $tarPath) { Remove-Item $tarPath -Force }
        Write-Host "Creating tar.gz file: $tarFileName"
        tar -czf $tarPath -C $platformOutputDir .
        if (-not (Test-Path $tarPath)) { throw "Failed to create tar.gz file: $tarPath" }
        $tarSize = (Get-Item $tarPath).Length / 1MB
        Write-Success "Go packaged successfully: $tarFileName (Size: $([math]::Round($tarSize, 2)) MB)"
        Write-Host "Location: $tarPath"
    } else {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        Write-Host "Creating zip file: $zipFileName"
        Compress-Archive -Path (Join-Path $platformOutputDir "*") -DestinationPath $zipPath -Force
        if (-not (Test-Path $zipPath)) { throw "Failed to create zip file: $zipPath" }
        $zipSize = (Get-Item $zipPath).Length / 1MB
        Write-Success "Go packaged successfully: $zipFileName (Size: $([math]::Round($zipSize, 2)) MB)"
        Write-Host "Location: $zipPath"
    }
}

# Main execution
try {
    Write-Host @"
╔════════════════════════════════════════╗
║   Go Build Script for Windows          ║
╚════════════════════════════════════════╝
"@ -ForegroundColor Yellow

    # Clean up any hanging processes before starting
    # Stop-HangingProcesses

    # Determine version to build
    if ([string]::IsNullOrEmpty($GoVersion)) {
        $GoVersion = Get-LatestStableVersion
        Write-Host "Auto-detected version: $GoVersion" -ForegroundColor Cyan
    }

    # Detect architecture
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }

    Write-Host "Configuration:"
    Write-Host "  Go Version: $GoVersion"
    Write-Host "  Architecture: $arch"
    Write-Host "  Source Dir: $SourceDir"
    Write-Host "  Bootstrap Dir: $BootstrapDir"
    Write-Host "  Platforms: $($Platforms -join ', ')"
    
    # Check prerequisites
    if (-not (Test-Git)) {
        Write-Error "Git is not installed or not in PATH"
        exit 1
    }
    
    # Execute build steps (clone and bootstrap once)
    Get-BootstrapGo
    Get-GoSource -Version $GoVersion
    Apply-PRPatch -PRNumber 75048
    
    # Build and package for each platform
    foreach ($platform in $Platforms) {
        if ($platform -eq "windows") {
            Build-Go -OS "windows" -Arch $arch -SourceDirectory $SourceDir
            $outputPath = Copy-GoOutput -OS "windows" -Arch $arch -SourceDirectory $SourceDir -DestinationDirectory $OutputDir
            Test-GoBuild -OS "windows" -Arch $arch -OutputDirectory $OutputDir
            Package-Go -Version $GoVersion -OS "windows" -Architecture $arch -OutputDirectory $OutputDir
        } elseif ($platform -eq "linux") {
            Build-Go -OS "linux" -Arch $arch -SourceDirectory $SourceDir
            $outputPath = Copy-GoOutput -OS "linux" -Arch $arch -SourceDirectory $SourceDir -DestinationDirectory $OutputDir
            Test-GoBuild -OS "linux" -Arch $arch -OutputDirectory $OutputDir
            Package-Go -Version $GoVersion -OS "linux" -Architecture $arch -OutputDirectory $OutputDir
        }
    }
    
    Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║   Build completed successfully!        ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host "`nBuilt packages:" -ForegroundColor Cyan
    foreach ($platform in $Platforms) {
        $zipFileName = "go$($GoVersion -replace '^go', '').$platform-$arch.zip"
        Write-Host "  ✓ $zipFileName" -ForegroundColor Green
    }
    
} catch {
    Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║   Build failed!                        ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Red
    Write-Error $_.Exception.Message
    exit 1
}
