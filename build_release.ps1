###############################################################################
# Build Release — creates parallax-miner-vX.X.tar.gz for HiveOS
#
# Usage:  .\build_release.ps1 [-Version "1.0"]
#
# Upload the resulting .tar.gz to GitHub Releases, then use that URL
# as the Installation URL in the HiveOS flight sheet.
###############################################################################

param(
    [string]$Version = "1.0"
)

$ErrorActionPreference = "Stop"

$archiveName = "parallax-miner-v${Version}.tar.gz"
$stagingDir  = "parallax-miner"
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path

Push-Location $scriptDir

try {
    # Clean previous build
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
    if (Test-Path $archiveName) { Remove-Item $archiveName -Force }

    # Create staging directory
    New-Item -ItemType Directory -Path $stagingDir | Out-Null

    # Copy all miner files
    $files = @(
        "h-manifest.conf",
        "h-config.sh",
        "h-run.sh",
        "h-stats.sh",
        "h-install.sh",
        "xhash_stratum_proxy.py",
        "README.md"
    )

    foreach ($f in $files) {
        if (Test-Path $f) {
            # Convert line endings to LF (Linux) during copy
            $content = Get-Content $f -Raw
            $content = $content -replace "`r`n", "`n"
            [System.IO.File]::WriteAllText(
                (Join-Path (Resolve-Path $stagingDir) $f),
                $content,
                [System.Text.UTF8Encoding]::new($false)  # UTF-8 no BOM
            )
        } else {
            Write-Warning "Missing file: $f"
        }
    }

    # Create tar.gz using Windows built-in tar
    Write-Host ""
    Write-Host "Creating $archiveName ..." -ForegroundColor Cyan
    tar -czf $archiveName $stagingDir

    if ($LASTEXITCODE -ne 0) {
        throw "tar failed with exit code $LASTEXITCODE"
    }

    # Clean up staging
    Remove-Item $stagingDir -Recurse -Force

    $size = (Get-Item $archiveName).Length
    $sizeKB = [math]::Round($size / 1024, 1)

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Build complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Archive:  $archiveName" -ForegroundColor White
    Write-Host "  Size:     ${sizeKB} KB" -ForegroundColor White
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "    1. Create a GitHub repo (e.g., parallax-hiveos-miner)"
    Write-Host "    2. Push all files to the repo"
    Write-Host "    3. Create a Release (tag: v${Version})"
    Write-Host "    4. Attach $archiveName to the release"
    Write-Host "    5. Copy the .tar.gz download URL"
    Write-Host "    6. Paste it as Installation URL in HiveOS flight sheet"
    Write-Host ""

} finally {
    Pop-Location
}
