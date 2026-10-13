\# OCItunnelScript



\*\*Connect to a private OCI instance through OCI Bastion with one command.\*\*



`OCItunnelScript.ps1` automates the manual parts of the \[OCI Bastion](https://docs.oracle.com/en-us/iaas/Content/Bastion/home.htm) workflow: it creates a port-forwarding session, waits for it to become `ACTIVE`, reads the bastion username, and starts the `ssh -L` tunnel. You get a local port that forwards to your instance's private IP.



> Independent community project. Not an official Oracle tool and not affiliated with Oracle.

>

> \*\*Status:\*\* early release, still being tested against live Bastions. Please report anything that doesn't behave as described.



\## Features



\- One command from nothing to a working tunnel, with the `ssh` command printed for you

\- Works for any TCP port (SSH, RDP, databases, web UIs), not just SSH

\- Binds to `127.0.0.1` only, with strict SSH host-key checking by default

\- `-Wait` mode: Ctrl+C stops the tunnel and deletes the session

\- A failed setup never leaves a session behind

\- OCI CLI profile and region support



\## Requirements



\- Windows with PowerShell 5.1 or later

\- \[OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm), authenticated (`oci setup config`)

\- OpenSSH client (`ssh.exe` on `PATH`)

\- An SSH key pair that is \*\*not passphrase-protected\*\* (or is loaded in `ssh-agent`); the tunnel runs non-interactively

\- An existing OCI Bastion that allows your public IP in its client CIDR allow list, can reach the target on the target port, and IAM permissions to manage Bastion sessions



\## Quick start



```powershell

.\\OCItunnelScript.ps1 `

&#x20;   -BastionOcid "ocid1.bastion.oc1.iad.<your-bastion-id>" `

&#x20;   -TargetIp    "10.0.0.10" `

&#x20;   -Region      "us-ashburn-1" `

&#x20;   -KeyPath     "$HOME\\.ssh\\oci-bastion" `

&#x20;   -AcceptNewHostKeys

```



The script waits up to about three minutes for the session to become `ACTIVE`, then prints a command to run in another terminal:



```powershell

ssh -o StrictHostKeyChecking=accept-new -o HostKeyAlias=oci-10.0.0.10 -i "C:\\Users\\you\\.ssh\\oci-bastion" -p 54321 opc@127.0.0.1

```



`-PublicKeyPath` defaults to `<KeyPath>.pub`.



\## Modes



\*\*Background (default).\*\* Starts the tunnel in a hidden process and exits. The session stays alive until its TTL expires. The script prints the PID, the command to stop the tunnel, the exact command to delete the session, and the path of the SSH stderr log.



\*\*Foreground (`-Wait`).\*\* Keeps the script running. Press Ctrl+C to stop the tunnel and delete the session.



```powershell

.\\OCItunnelScript.ps1 -BastionOcid "ocid1.bastion..." -TargetIp 10.0.0.10 `

&#x20;   -Region us-ashburn-1 -OciProfile production -KeyPath "$HOME\\.ssh\\oci-bastion" -Wait

```



\*\*Other ports.\*\* For a target port other than 22 the script reports the local endpoint instead of an `ssh` command. For example, forward RDP to a Windows instance, then point your RDP client at `127.0.0.1:13389`:



```powershell

.\\OCItunnelScript.ps1 -BastionOcid "ocid1.bastion..." -TargetIp 10.0.0.20 `

&#x20;   -TargetPort 3389 -LocalPort 13389 -Region us-ashburn-1 -KeyPath "$HOME\\.ssh\\oci-bastion"

```



\## Parameters



| Parameter | Required | Default | Description |

|---|---|---|---|

| `-BastionOcid` | Yes | | OCID of the Bastion. |

| `-TargetIp` | Yes | | Private IPv4 address of the target. |

| `-Region` | Yes | | OCI region, e.g. `us-ashburn-1`. Also determines the bastion SSH host. |

| `-KeyPath` | Yes | | Private key used to authenticate to the Bastion. |

| `-PublicKeyPath` | No | `<KeyPath>.pub` | Public key registered with the session. |

| `-OciProfile` | No | CLI default | OCI CLI profile. |

| `-TargetPort` | No | `22` | Port on the target. |

| `-LocalPort` | No | `54321` | Local loopback port (1024-65535). |

| `-RemoteUser` | No | `opc` | OS user on the target, used in the printed command. |

| `-SessionTtl` | No | `10800` | Session lifetime in seconds (1800-10800). |

| `-AcceptNewHostKeys` | No | off | Trust unknown host keys on first use (`accept-new`). |

| `-Wait` | No | off | Stay in the foreground and clean up on exit. |



\## Host keys



By default the script uses `StrictHostKeyChecking=yes`, so the \*\*first connection to a host key you have never seen is rejected\*\*, for both the bastion hop and your target.



\- \*\*Bastion hop:\*\* there is no readily available out-of-band fingerprint to check, so `-AcceptNewHostKeys` (trust on first use) is the practical choice. Changed keys are still rejected afterwards.

\- \*\*Target:\*\* the printed command stores the target's key under the alias `oci-<target-ip>`, so different targets that reuse the same local port don't trigger "host key changed" warnings. It also means an earlier connection to the target under another name doesn't count as trusted. To enroll the key securely:

&#x20; 1. Start the tunnel.

&#x20; 2. Connect once with an interactive prompt:

```powershell

&#x20;    ssh -o StrictHostKeyChecking=ask -o HostKeyAlias=oci-<target-ip> -i "<key>" -p <LocalPort> <user>@127.0.0.1

```

&#x20; 3. ssh shows the host key fingerprint and asks for confirmation. Before answering `yes`, compare it with the fingerprint taken on the instance itself, for example `ssh-keygen -lf /etc/ssh/ssh\_host\_ed25519\_key.pub` (use the same key type ssh shows), run through the OCI Console connection or another trusted channel.

&#x20; 4. After that, the strict-mode command the script prints works as-is.

\- Don't append a second `StrictHostKeyChecking` option to a printed command. ssh uses the first value it sees. Re-run the script with `-AcceptNewHostKeys` instead.



\## SSH keys



\- The key you pass authenticates the \*\*bastion hop\*\*. Your target instance checks you separately: the public key must also be in `authorized\_keys` for `-RemoteUser`. The same key pair works for both. Use `ubuntu`, `ec2-user`, etc. for non-Oracle-Linux images.

\- Windows OpenSSH rejects private keys with loose permissions (`UNPROTECTED PRIVATE KEY FILE`). Fix with:



```powershell

&#x20; $key = "$HOME\\.ssh\\oci-bastion"

&#x20; icacls $key /inheritance:r

&#x20; icacls $key /grant:r "$($env:USERNAME):(R)"

```



\## Troubleshooting



SSH errors during startup are shown in the script output. The ssh stderr log is `%TEMP%\\OCItunnel-<LocalPort>-<PID>.log`; it is deleted on cleanup and kept only for background tunnels.



| Symptom | Likely cause and fix |

|---|---|

| `Host key verification failed` | Host key not trusted yet. Re-run with `-AcceptNewHostKeys`. |

| `Local port ... is already in use` | Another tunnel or service holds the port. Use `-LocalPort`. |

| Session ends in `FAILED` or is still `CREATING` after \~3 minutes | Check the Bastion's CIDR allow list, network path to the target, and IAM permissions. The script prints OCI's failure details. |

| SSH exits immediately | Key permissions, a passphrase-protected key without `ssh-agent`, or `-KeyPath` and `-PublicKeyPath` not being a matching pair. |

| `Permission denied (publickey)` on the target | The tunnel works, but the instance doesn't accept your key for that user. Check `-RemoteUser` and `authorized\_keys`. |



\## Notes and limitations



\- Windows only (`Get-NetTCPConnection`, `ssh.exe`).

\- Run the script directly (`.\\OCItunnelScript.ps1 ...`). Don't dot-source it: the script ends with `exit`, which would close your shell.

\- Every run creates a new session; sessions are bound to the key they were created with, so none are reused.

\- Port-forwarding sessions only (not managed SSH sessions).

\- The bastion SSH host is `host.bastion.<region>.oci.oraclecloud.com`. For other OCI realms (for example government), edit the `$bastionHost` line at the top of the script.

\- Never commit private keys. Suggested `.gitignore`: `\*.key`, `\*.pem`, `id\_\*` (keep `\*.pub` if you want), `\*.log`.



\## License



Add a `LICENSE` file (MIT is a common default) and reference it here.

