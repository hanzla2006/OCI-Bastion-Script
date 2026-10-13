<#
.SYNOPSIS
    Opens a local tunnel to a private OCI instance through OCI Bastion.
.DESCRIPTION
    Creates a port-forwarding Bastion session, waits for it to become ACTIVE, and
    forwards 127.0.0.1:LocalPort to TargetIp:TargetPort over SSH.
    Default: the tunnel runs in the background; the session expires on its TTL.
    -Wait: stays in the foreground; Ctrl+C stops the tunnel and deletes the session.
    Windows only. Needs an authenticated OCI CLI and the OpenSSH client.
    Unofficial community tool, not affiliated with Oracle.
.EXAMPLE
    .\OCItunnelScript.ps1 -BastionOcid ocid1.bastion.oc1.iad.xxxx -TargetIp 10.0.0.10 `
        -Region us-ashburn-1 -KeyPath "$HOME\.ssh\oci-bastion" -Wait
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^ocid1\.bastion\.')][string]$BastionOcid,
    [Parameter(Mandatory)][ValidateScript({ ($_ -as [ipaddress]) -and $_ -match '^\d+(\.\d+){3}$' })][string]$TargetIp,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Region,
    [Parameter(Mandatory)][string]$KeyPath,
    [string]$PublicKeyPath,
    [string]$OciProfile,
    [ValidateRange(1, 65535)][int]$TargetPort = 22,
    [ValidateRange(1024, 65535)][int]$LocalPort = 54321,
    [ValidatePattern('^[\w.-]+$')][string]$RemoteUser = 'opc',
    [ValidateRange(1800, 10800)][int]$SessionTtl = 10800,
    [switch]$AcceptNewHostKeys,
    [switch]$Wait
)

$ErrorActionPreference = 'Stop'
if (-not $PublicKeyPath) { $PublicKeyPath = "$KeyPath.pub" }
$cliOpts = @('--region', $Region)
if ($OciProfile) { $cliOpts += '--profile', $OciProfile }
$bastionHost = "host.bastion.$Region.oci.oraclecloud.com"
$policy = if ($AcceptNewHostKeys) { 'accept-new' } else { 'yes' }
$log = Join-Path $env:TEMP "OCItunnel-$LocalPort-$PID.log"
$id = $null; $ssh = $null; $keep = $false; $code = 0

function Invoke-Oci {
    $ErrorActionPreference = 'Continue'  # native stderr must not abort the script
    $errFile = New-TemporaryFile         # stderr goes to a file so it never mixes into the JSON
    try {
        $out = & oci @args @cliOpts 2> $errFile
        if ($LASTEXITCODE) { throw "OCI CLI failed ($LASTEXITCODE):`n$(Get-Content $errFile -Raw)" }
        $out -join "`n"
    }
    finally { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
}

function Test-Listening {
    [bool](Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)
}

try {
    foreach ($c in 'oci', 'ssh.exe') {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "$c was not found in PATH." }
    }
    $KeyPath = (Resolve-Path -LiteralPath $KeyPath).Path
    $PublicKeyPath = (Resolve-Path -LiteralPath $PublicKeyPath).Path
    if (Test-Listening) { throw "Local port $LocalPort is already in use. Pick another with -LocalPort." }

    Write-Host '[*] Creating Bastion session...'
    $id = (Invoke-Oci bastion session create-port-forwarding --bastion-id $BastionOcid `
            --target-private-ip $TargetIp --target-port $TargetPort `
            --ssh-public-key-file $PublicKeyPath --session-ttl $SessionTtl --output json |
        ConvertFrom-Json).data.id
    if (-not $id) { throw 'OCI did not return a session ID.' }

    Write-Host "[*] Waiting for session $id to become ACTIVE..."
    for ($i = 0; $i -lt 90; $i++) {
        $s = (Invoke-Oci bastion session get --session-id $id --output json | ConvertFrom-Json).data
        if ($s.'lifecycle-state' -ne 'CREATING') { break }
        Start-Sleep 2
    }
    if ($s.'lifecycle-state' -ne 'ACTIVE') {
        throw "Session is $($s.'lifecycle-state'): $($s.'lifecycle-state-details')"
    }

    $sshArgs = @(
        '-i', "`"$KeyPath`"", '-N',
        '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=60',
        '-o', "StrictHostKeyChecking=$policy", '-o', 'BatchMode=yes',
        '-L', "127.0.0.1:${LocalPort}:${TargetIp}:${TargetPort}",
        "$($s.'bastion-user-name')@$bastionHost"
    )
    $mode = if ($Wait) { @{ NoNewWindow = $true } } else { @{ WindowStyle = 'Hidden' } }
    Write-Host "[*] Starting tunnel 127.0.0.1:$LocalPort -> ${TargetIp}:$TargetPort..."
    $ssh = Start-Process ssh.exe -ArgumentList $sshArgs -PassThru -RedirectStandardError $log @mode

    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Listening)) {
        if ($ssh.HasExited -or (Get-Date) -gt $deadline) {
            $err = Get-Content $log -Raw -ErrorAction SilentlyContinue
            $hint = if ($err -match 'Host key verification failed') { "`nRe-run with -AcceptNewHostKeys to trust the Bastion host key on first use." }
            throw "SSH could not start the tunnel.`n$err$hint"
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Host "[+] Forwarding listener ready on 127.0.0.1:$LocalPort (session $id)." -ForegroundColor Green

    if ($TargetPort -eq 22) {
        Write-Host "`nConnect from another terminal:"
        Write-Host "  ssh -o StrictHostKeyChecking=$policy -o HostKeyAlias=oci-$TargetIp -i `"$KeyPath`" -p $LocalPort $RemoteUser@127.0.0.1"
        if ($policy -eq 'yes') {
            Write-Host "  (strict mode: enroll the target key under alias 'oci-$TargetIp' first, or re-run with -AcceptNewHostKeys)"
        }
    }

    if ($Wait) {
        Write-Host "`nPress Ctrl+C to stop the tunnel and delete the session."
        while (-not $ssh.HasExited) { Start-Sleep 1 }
        Write-Host "[*] SSH exited with code $($ssh.ExitCode)."
    }
    else {
        $keep = $true
        Write-Host "`nRunning in the background (PID $($ssh.Id)). To clean up later:"
        Write-Host "  Stop-Process -Id $($ssh.Id)"
        Write-Host "  oci bastion session delete --session-id $id --force $($cliOpts -join ' ')"
        Write-Host "SSH stderr log: $log"
    }
}
catch {
    Write-Host "`n[!] $($_.Exception.Message)" -ForegroundColor Red
    $code = 1
}
finally {
    if (-not $keep) {
        if ($ssh) {
            Stop-Process -Id $ssh.Id -Force -ErrorAction SilentlyContinue
            $null = $ssh.WaitForExit(3000)
        }
        if ($id) {
            try {
                $null = Invoke-Oci bastion session delete --session-id $id --force
                Write-Host '[+] Session deletion requested.'
            }
            catch { Write-Warning "Could not delete session $id. Delete it manually or let it expire." }
        }
        Remove-Item $log -Force -ErrorAction SilentlyContinue
    }
}
exit $code