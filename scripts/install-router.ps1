param(
    [Parameter(Mandatory = $true)]
    [string]$Router,

    [string]$User = "root",
    [int]$Port = 22,
    [switch]$InstallDeps,
    [switch]$Enable,
    [switch]$Start,
    [switch]$ResetConfig
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("homeproxy-dscp-stage-" + [System.Guid]::NewGuid().ToString("N"))
$archive = Join-Path ([System.IO.Path]::GetTempPath()) "homeproxy-dscp.tar.gz"
$remote = "/tmp/homeproxy-dscp.tar.gz"
$target = "$User@$Router"

function Require-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $name"
    }
}

Require-Command "tar"
Require-Command "ssh"

if (Test-Path $archive) {
    Remove-Item -LiteralPath $archive -Force
}

New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -Path (Join-Path $repo "root\*") -Destination $stage -Recurse -Force

$wwwView = Join-Path $stage "www\luci-static\resources\view\homeproxy-dscp"
New-Item -ItemType Directory -Force -Path $wwwView | Out-Null
Copy-Item -Path (Join-Path $repo "htdocs\luci-static\resources\view\homeproxy-dscp\client.js") -Destination $wwwView -Force

Push-Location $stage
try {
    tar -czf $archive .
}
finally {
    Pop-Location
}

$depsBlock = ""
if ($InstallDeps) {
    $depsBlock = @"
opkg update
for pkg in firewall4 ip-full jsonfilter kmod-nft-tproxy nftables sing-box ucode ucode-mod-fs ucode-mod-uci; do
  if ! opkg status "$pkg" 2>/dev/null | grep -q '^Status: .* installed'; then
    opkg install "$pkg"
  else
    echo "$pkg is already installed; skipping"
  fi
done
if ! opkg status luci-app-homeproxy 2>/dev/null | grep -q '^Status: .* installed'; then
  echo "WARNING: luci-app-homeproxy is not installed from this package feed."
  echo "Install HomeProxy separately first. On stock OpenWrt it is not part of the official feeds."
fi
"@
}

$enableBlock = ""
if ($Enable) {
    $enableBlock = "/etc/init.d/homeproxy-dscp enable"
}

$startBlock = ""
if ($Start) {
    $startBlock = "/etc/init.d/homeproxy-dscp restart"
}

$preserveConfigBlock = ""
if (-not $ResetConfig) {
    $preserveConfigBlock = @"
if [ -f /etc/config/homeproxy_dscp ]; then
  cp -a /etc/config/homeproxy_dscp /tmp/homeproxy_dscp.keep
fi
"@
}

$restoreConfigBlock = ""
if (-not $ResetConfig) {
    $restoreConfigBlock = @"
if [ -f /tmp/homeproxy_dscp.keep ]; then
  cp -a /tmp/homeproxy_dscp.keep /etc/config/homeproxy_dscp
  rm -f /tmp/homeproxy_dscp.keep
fi
"@
}

$remoteScript = @"
set -eu
archive="$remote"
: > "`$archive"
__ARCHIVE_OCTAL_WRITES__

$depsBlock
backup="/root/homeproxy-dscp-backup-`$(date +%Y%m%d-%H%M%S)"
mkdir -p "`$backup"
for p in \
  /etc/config/homeproxy_dscp \
  /etc/init.d/homeproxy-dscp \
  /usr/libexec/rpcd/homeproxy-dscp \
  /usr/share/homeproxy-dscp/generate.uc \
  /usr/share/luci/menu.d/luci-app-homeproxy-dscp.json \
  /usr/share/rpcd/acl.d/luci-app-homeproxy-dscp.json \
  /www/luci-static/resources/view/homeproxy-dscp/client.js
do
  if [ -e "`$p" ]; then
    mkdir -p "`$backup`$(dirname "`$p")"
    cp -a "`$p" "`$backup`$p"
  fi
done
$preserveConfigBlock
tar -xzf $remote -C /
$restoreConfigBlock
chmod +x /etc/init.d/homeproxy-dscp /usr/share/homeproxy-dscp/generate.uc /usr/libexec/rpcd/homeproxy-dscp
/etc/init.d/rpcd restart || true
/etc/init.d/uhttpd restart || true
sleep 1
if ! ubus -S list homeproxy-dscp >/dev/null 2>&1; then
  echo "WARNING: ubus object homeproxy-dscp is not visible yet."
  echo "If LuCI service buttons fail, run: /etc/init.d/rpcd restart && /etc/init.d/uhttpd restart"
  echo "Then check: ubus -S list homeproxy-dscp"
fi
$enableBlock
$startBlock
echo "Installed homeproxy-dscp. Backup: `$backup"
"@

$remoteScript = $remoteScript -replace "`r`n", "`n"
$archiveBytes = [System.IO.File]::ReadAllBytes($archive)
$archiveWriteLines = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $archiveBytes.Length; $i += 384) {
    $end = [Math]::Min($i + 384, $archiveBytes.Length)
    $escaped = New-Object System.Text.StringBuilder

    for ($j = $i; $j -lt $end; $j++) {
        [void]$escaped.Append('\')
        [void]$escaped.Append([Convert]::ToString($archiveBytes[$j], 8).PadLeft(3, '0'))
    }

    $archiveWriteLines.Add("printf '$($escaped.ToString())' >> ""`$archive""")
}
$remoteScript = $remoteScript.Replace('__ARCHIVE_OCTAL_WRITES__', ($archiveWriteLines -join "`n"))
$payloadFile = Join-Path ([System.IO.Path]::GetTempPath()) ("homeproxy-dscp-payload-" + [System.Guid]::NewGuid().ToString("N") + ".sh")
try {
    [System.IO.File]::WriteAllText($payloadFile, $remoteScript + "`n", [System.Text.Encoding]::ASCII)

    $sshCmd = 'ssh -p {0} {1} "ash -s" < "{2}"' -f $Port, $target, $payloadFile
    cmd.exe /d /c $sshCmd
    if ($LASTEXITCODE -ne 0) {
        throw "Remote installation failed on $target"
    }
}
finally {
    Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Done. LuCI: Services -> HomeProxy DSCP"
Write-Host "Default install is disabled unless -Enable was used."
