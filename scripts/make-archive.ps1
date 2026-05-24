param(
    [string]$Output = "homeproxy-dscp.tar.gz"
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("homeproxy-dscp-stage-" + [System.Guid]::NewGuid().ToString("N"))
$outPath = Join-Path $repo $Output

if (Test-Path $outPath) {
    Remove-Item -LiteralPath $outPath -Force
}

New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -Path (Join-Path $repo "root\*") -Destination $stage -Recurse -Force

$wwwView = Join-Path $stage "www\luci-static\resources\view\homeproxy-dscp"
New-Item -ItemType Directory -Force -Path $wwwView | Out-Null
Copy-Item -Path (Join-Path $repo "htdocs\luci-static\resources\view\homeproxy-dscp\client.js") -Destination $wwwView -Force

Push-Location $stage
try {
    tar -czf $outPath .
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host $outPath
