param(
    [string]$Router,
    [string]$User = "root",
    [int]$Port = 22,
    [string]$DefaultTarget = "routing:EU_NODE",
    [int]$DefaultDscp = 46
)

$ErrorActionPreference = "Stop"
$Script:Prefix = "HP-DSCP-"

function Initialize-Manager {
    if (-not $Router) {
        Write-Host "HomeProxy DSCP App Manager" -ForegroundColor Cyan
        Write-Host "==========================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Enter router IP to let the manager update HomeProxy DSCP rules."
        Write-Host "Leave it empty for Windows-only mode."
        Write-Host ""

        $value = Read-Host "Router IP"
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $Script:Router = $value.Trim()
        }
    }

    if ($Router -and (-not $DefaultTarget -or $DefaultTarget -eq "routing:EU_NODE")) {
        Write-Host ""
        Write-Host "Default target is used when adding new apps."
        Write-Host "Examples: routing:EU_NODE, routing:RU_NODE, routing:FL_NODE"
        $value = Read-Host "Default target [$DefaultTarget]"
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $Script:DefaultTarget = $value.Trim()
        }
    }
}

function Write-Header {
    Clear-Host
    Write-Host "HomeProxy DSCP App Manager" -ForegroundColor Cyan
    Write-Host "==========================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Router:        $(if ($Router) { $Router } else { 'not configured' })"
    Write-Host "Default DSCP:  $DefaultDscp"
    Write-Host "Default node:  $DefaultTarget"
    Write-Host ""
}

function Pause-Menu {
    Write-Host ""
    Read-Host "Press Enter to continue" | Out-Null
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        throw "Run PowerShell as Administrator. Windows QoS policies require admin rights."
    }
}

function Read-Default {
    param(
        [string]$Prompt,
        [string]$Default
    )

    if ($Default) {
        $value = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $Default
        }
        return $value.Trim()
    }

    do {
        $value = Read-Host $Prompt
    } while ([string]::IsNullOrWhiteSpace($value))

    return $value.Trim()
}

function Get-PrimaryIPv4 {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1

    if (-not $route) {
        return $null
    }

    $addr = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notlike "169.254.*" -and
            $_.IPAddress -ne "127.0.0.1"
        } |
        Select-Object -First 1

    if ($addr) {
        return $addr.IPAddress
    }

    return $null
}

function Escape-SingleQuotedShell {
    param([string]$Value)
    $replacement = "'" + '"' + "'" + '"' + "'"
    return $Value.Replace("'", $replacement)
}

function Get-DscpPolicies {
    Get-NetQosPolicy -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$Script:Prefix*" } |
        Sort-Object Name
}

function Format-PolicyTable {
    $policies = @(Get-DscpPolicies)

    if (-not $policies.Count) {
        Write-Host "No HomeProxy DSCP policies found." -ForegroundColor Yellow
        return
    }

    $policies | Select-Object `
        @{n = "Name"; e = { $_.Name.Substring($Script:Prefix.Length) } },
        @{n = "DSCP"; e = { $_.DSCPValue } },
        @{n = "AppPath"; e = { $_.AppPathName } } |
        Format-Table -AutoSize
}

function Select-Policy {
    $policies = @(Get-DscpPolicies)

    if (-not $policies.Count) {
        Write-Host "No HomeProxy DSCP policies found." -ForegroundColor Yellow
        return $null
    }

    for ($i = 0; $i -lt $policies.Count; $i++) {
        Write-Host ("[{0}] {1}" -f ($i + 1), $policies[$i].Name.Substring($Script:Prefix.Length))
        Write-Host ("    {0}" -f $policies[$i].AppPathName)
    }

    $choice = Read-Host "Select policy number"
    if ($choice -notmatch '^\d+$') {
        return $null
    }

    $index = [int]$choice - 1
    if ($index -lt 0 -or $index -ge $policies.Count) {
        return $null
    }

    return $policies[$index]
}

function Ensure-QosPolicy {
    param(
        [string]$RuleName,
        [string]$AppPath,
        [int]$Dscp
    )

    Require-Admin

    $policyName = "$Script:Prefix$RuleName"
    $existing = Get-NetQosPolicy -Name $policyName -ErrorAction SilentlyContinue

    if ($existing) {
        Remove-NetQosPolicy -Name $policyName -Confirm:$false
    }

    New-NetQosPolicy `
        -Name $policyName `
        -AppPathNameMatchCondition $AppPath `
        -IPProtocolMatchCondition Both `
        -DSCPAction $Dscp `
        -NetworkProfile All | Out-Null

    Write-Host "Windows QoS policy saved: $policyName" -ForegroundColor Green
}

function Invoke-RouterRuleUpdate {
    param(
        [string]$RuleName,
        [string]$WindowsIp,
        [int]$Dscp,
        [string]$Protocols,
        [string]$Target,
        [switch]$EnableAddon,
        [switch]$RestartService
    )

    if (-not $Router) {
        Write-Host ""
        Write-Host "Router is not configured. Enter these values in LuCI:" -ForegroundColor Yellow
        Write-Host "  Enable: yes"
        Write-Host "  Name: $RuleName"
        Write-Host "  Windows source IPv4: $WindowsIp"
        Write-Host "  DSCP value: $Dscp"
        Write-Host "  Protocols: $Protocols"
        Write-Host "  Target HomeProxy routing node: $Target"
        return
    }

    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw "ssh command not found."
    }

    $label = Escape-SingleQuotedShell $RuleName
    $srcIp = Escape-SingleQuotedShell $WindowsIp
    $proto = Escape-SingleQuotedShell $Protocols
    $target = Escape-SingleQuotedShell $Target
    $enableLine = if ($EnableAddon) { "uci set homeproxy_dscp.main.enabled='1'" } else { ":" }
    $restartLine = if ($RestartService) { "/etc/init.d/homeproxy-dscp restart" } else { ":" }

    $remoteScript = @'
set -eu
uci -q get homeproxy_dscp.main >/dev/null || uci set homeproxy_dscp.main='settings'
__ENABLE_LINE__
section=""
for s in $(uci show homeproxy_dscp | sed -n "s/^\(homeproxy_dscp\.[^.]*\)=rule$/\1/p"); do
  current=$(uci -q get "$s.label" || true)
  if [ "$current" = '__LABEL__' ]; then
    section="$s"
    break
  fi
done
if [ -z "$section" ]; then
  section=$(uci add homeproxy_dscp rule)
  section="homeproxy_dscp.$section"
fi
uci set "$section.enabled=1"
uci set "$section.label=__LABEL__"
uci set "$section.src_ip=__SRC_IP__"
uci set "$section.dscp=__DSCP__"
uci set "$section.proto=__PROTO__"
uci set "$section.target=__TARGET__"
uci commit homeproxy_dscp
__RESTART_LINE__
echo "Updated HomeProxy DSCP rule: __LABEL__"
'@

    $remoteScript = $remoteScript.Replace('__ENABLE_LINE__', $enableLine)
    $remoteScript = $remoteScript.Replace('__RESTART_LINE__', $restartLine)
    $remoteScript = $remoteScript.Replace('__LABEL__', $label)
    $remoteScript = $remoteScript.Replace('__SRC_IP__', $srcIp)
    $remoteScript = $remoteScript.Replace('__DSCP__', [string]$Dscp)
    $remoteScript = $remoteScript.Replace('__PROTO__', $proto)
    $remoteScript = $remoteScript.Replace('__TARGET__', $target)

    $payloadFile = Join-Path ([IO.Path]::GetTempPath()) ("homeproxy-dscp-manager-" + [Guid]::NewGuid().ToString("N") + ".sh")
    [IO.File]::WriteAllText($payloadFile, ($remoteScript -replace "`r`n", "`n") + "`n", [Text.Encoding]::ASCII)

    try {
        $sshTarget = "$User@$Router"
        $sshCmd = 'ssh -p {0} {1} "ash -s" < "{2}"' -f $Port, $sshTarget, $payloadFile
        cmd.exe /d /c $sshCmd

        if ($LASTEXITCODE -ne 0) {
            throw "Router update failed."
        }
    }
    finally {
        Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue
    }
}

function Add-AppFlow {
    Write-Header
    Write-Host "Add or update application" -ForegroundColor Cyan
    Write-Host ""

    $appPath = Read-Default "Application .exe path" ""
    $appPath = (Resolve-Path -LiteralPath $appPath).Path

    $defaultName = [IO.Path]::GetFileNameWithoutExtension($appPath)
    $ruleName = Read-Default "Rule name" $defaultName
    $windowsIp = Read-Default "Windows IPv4" (Get-PrimaryIPv4)
    $dscp = [int](Read-Default "DSCP value" ([string]$DefaultDscp))
    $protocols = Read-Default "Protocols: both, tcp, udp" "both"
    $target = Read-Default "Router target" $DefaultTarget

    if ($protocols -notin @("both", "tcp", "udp")) {
        throw "Protocols must be one of: both, tcp, udp."
    }
    if ($dscp -lt 0 -or $dscp -gt 63) {
        throw "DSCP must be between 0 and 63."
    }

    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  App:       $appPath"
    Write-Host "  Rule:      $ruleName"
    Write-Host "  WindowsIP: $windowsIp"
    Write-Host "  DSCP:      $dscp"
    Write-Host "  Protocols: $protocols"
    Write-Host "  Target:    $target"
    Write-Host ""

    $confirm = Read-Default "Apply changes? y/n" "y"
    if ($confirm -notin @("y", "Y", "yes", "YES")) {
        Write-Host "Cancelled."
        return
    }

    Ensure-QosPolicy -RuleName $ruleName -AppPath $appPath -Dscp $dscp
    Invoke-RouterRuleUpdate `
        -RuleName $ruleName `
        -WindowsIp $windowsIp `
        -Dscp $dscp `
        -Protocols $protocols `
        -Target $target `
        -EnableAddon `
        -RestartService
}

function Remove-AppFlow {
    Write-Header
    Write-Host "Remove Windows QoS policy" -ForegroundColor Cyan
    Write-Host ""

    $policy = Select-Policy
    if (-not $policy) {
        return
    }

    $confirm = Read-Default "Remove $($policy.Name)? y/n" "n"
    if ($confirm -notin @("y", "Y", "yes", "YES")) {
        Write-Host "Cancelled."
        return
    }

    Require-Admin
    Remove-NetQosPolicy -Name $policy.Name -Confirm:$false
    Write-Host "Removed: $($policy.Name)" -ForegroundColor Green
    Write-Host "Router rule was not removed automatically. Disable or delete it in LuCI if needed." -ForegroundColor Yellow
}

function Test-DscpFlow {
    Write-Header
    Write-Host "Quick verification commands" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Windows QoS policies:"
    Get-DscpPolicies | Format-Table Name, DSCPValue, AppPathName -AutoSize
    Write-Host ""
    Write-Host "Router checks:"
    Write-Host "  nft list table inet homeproxy_dscp"
    Write-Host "  tcpdump -i br-lan -vv host $(Get-PrimaryIPv4)"
    Write-Host ""
    Write-Host "Look for DSCP EF / tos 0xb8 and increasing tcp/udp counters."
}

function Show-Menu {
    while ($true) {
        Write-Header
        Write-Host "[1] List DSCP applications"
        Write-Host "[2] Add or update application"
        Write-Host "[3] Remove Windows QoS policy"
        Write-Host "[4] Show verification commands"
        Write-Host "[5] Exit"
        Write-Host ""

        $choice = Read-Host "Choose"

        try {
            switch ($choice) {
                "1" {
                    Write-Header
                    Format-PolicyTable
                    Pause-Menu
                }
                "2" {
                    Add-AppFlow
                    Pause-Menu
                }
                "3" {
                    Remove-AppFlow
                    Pause-Menu
                }
                "4" {
                    Test-DscpFlow
                    Pause-Menu
                }
                "5" {
                    return
                }
                default {
                    Write-Host "Unknown option." -ForegroundColor Yellow
                    Pause-Menu
                }
            }
        }
        catch {
            Write-Host ""
            Write-Host $_.Exception.Message -ForegroundColor Red
            Pause-Menu
        }
    }
}

Initialize-Manager
Show-Menu
