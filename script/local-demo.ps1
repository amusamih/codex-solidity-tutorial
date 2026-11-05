[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8545
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$rpcUrl = "http://127.0.0.1:$Port"
$weiPerETH = [bigint]1000000000000000000
$withdrawWei = [bigint]400000000000000000

function Invoke-LocalRpc([string]$Method, [object[]]$RpcParams) {
    $body = @{ jsonrpc = '2.0'; id = 1; method = $Method; params = $RpcParams } |
        ConvertTo-Json -Depth 8 -Compress
    $response = Invoke-RestMethod -Uri $rpcUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5
    if ($response.error) { throw ($response.error | ConvertTo-Json -Compress) }
    return $response.result
}

function Convert-HexToInteger([string]$Value) {
    # Prefix zero so BigInteger does not interpret the top hex bit as a sign.
    return [bigint]::Parse(('0' + $Value.Substring(2)), [Globalization.NumberStyles]::AllowHexSpecifier)
}

function Format-ETH([string]$Wei) {
    return ([decimal]$Wei / [decimal]$weiPerETH).ToString('0.000000000', [Globalization.CultureInfo]::InvariantCulture)
}

function Read-Balances([string]$Stage) {
    return [PSCustomObject]@{
        stage = $Stage
        walletWei = (Convert-HexToInteger (Invoke-LocalRpc 'eth_getBalance' @($depositor, 'latest'))).ToString()
        recordedWei = (Convert-HexToInteger (Invoke-LocalRpc 'eth_call' @(@{ to = $vault; data = $balanceData }, 'latest'))).ToString()
        vaultWei = (Convert-HexToInteger (Invoke-LocalRpc 'eth_getBalance' @($vault, 'latest'))).ToString()
        totalOwedWei = (Convert-HexToInteger (Invoke-LocalRpc 'eth_call' @(@{ to = $vault; data = $totalData }, 'latest'))).ToString()
    }
}

function Assert-Accounting($Snapshot, [bigint]$Expected) {
    if ([bigint]$Snapshot.recordedWei -ne $Expected -or
        [bigint]$Snapshot.vaultWei -ne $Expected -or
        [bigint]$Snapshot.totalOwedWei -ne $Expected) {
        throw "Unexpected accounting at stage '$($Snapshot.stage)'."
    }
}

function Assert-Receipt($Receipt, [string]$Signature, [bigint]$Amount) {
    if ((Convert-HexToInteger $Receipt.status) -ne 1) { throw 'Transaction reverted.' }
    $topic = & cast keccak $Signature
    if ($LASTEXITCODE -ne 0) { throw 'Could not encode event signature.' }
    $events = @($Receipt.logs | Where-Object { $_.address -ieq $vault -and $_.topics[0] -ieq $topic })
    $actorTopic = '0x' + $depositor.Substring(2).PadLeft(64, '0')
    if ($events.Count -ne 1 -or $events[0].topics[1] -ine $actorTopic -or
        (Convert-HexToInteger $events[0].data) -ne $Amount) {
        throw "Unexpected $Signature event."
    }
}

Push-Location -LiteralPath $projectRoot
try {
    foreach ($tool in @('forge', 'cast', 'anvil')) {
        Get-Command $tool -CommandType Application -ErrorAction Stop | Out-Null
    }

    $runName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $runDir = Join-Path $projectRoot ".logs\local-demo\$runName"
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $startedAnvilPid = $null

    $client = $null
    try { $client = Invoke-LocalRpc 'web3_clientVersion' @() } catch { }
    if ($null -eq $client) {
        if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
            throw "Port $Port is occupied by a service that did not answer JSON-RPC. Choose -Port <free-port>."
        }
        $anvilProcess = Start-Process -FilePath (Get-Command anvil).Source -ArgumentList @(
            '--host', '127.0.0.1', '--port', "$Port", '--chain-id', '31337', '--silent'
        ) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runDir 'anvil.stdout.log') `
            -RedirectStandardError (Join-Path $runDir 'anvil.stderr.log')
        $startedAnvilPid = $anvilProcess.Id
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            if ($anvilProcess.HasExited) { throw "Anvil exited. See $runDir\anvil.stderr.log" }
            try { $client = Invoke-LocalRpc 'web3_clientVersion' @() } catch { }
            if ($client) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $client) {
            Stop-Process -Id $startedAnvilPid -ErrorAction SilentlyContinue
            throw 'Anvil did not become ready.'
        }
        Write-Host "Started local Anvil (PID $startedAnvilPid)."
    } else {
        Write-Host 'Reusing local Anvil without resetting it.'
    }

    if ($client -notlike 'anvil/*') { throw "Expected Anvil, received '$client'." }
    if ((Convert-HexToInteger (Invoke-LocalRpc 'eth_chainId' @())) -ne 31337) {
        throw 'Expected local chain ID 31337.'
    }
    $accounts = @(Invoke-LocalRpc 'eth_accounts' @())
    if ($accounts.Count -lt 2) { throw 'Anvil must expose at least two unlocked test accounts.' }
    $deployer = $accounts[0]
    $depositor = $accounts[1]
    $initialWallet = Convert-HexToInteger (Invoke-LocalRpc 'eth_getBalance' @($depositor, 'latest'))
    if ($initialWallet -lt (2 * $weiPerETH)) { throw 'Depositor needs at least 2 test ETH, including gas headroom.' }

    # --unlocked asks Anvil to sign eth_sendTransaction with its local test key.
    # A new CREATE transaction on every run gives us a fresh vault on this chain.
    $deployOutput = & forge create src/ETHVault.sol:ETHVault --rpc-url $rpcUrl --unlocked --from $deployer --broadcast --json
    if ($LASTEXITCODE -ne 0) { throw 'Vault deployment failed.' }
    $deployOutput | Set-Content -LiteralPath (Join-Path $runDir 'deployment.json') -Encoding utf8
    $deployment = $deployOutput | ConvertFrom-Json
    $vault = $deployment.deployedTo
    $receipt = Invoke-LocalRpc 'eth_getTransactionReceipt' @($deployment.transactionHash)
    if ((Convert-HexToInteger $receipt.status) -ne 1 -or $receipt.contractAddress -ine $vault) {
        throw 'Deployment receipt is not a successful vault creation.'
    }
    if ((Invoke-LocalRpc 'eth_getCode' @($vault, 'latest')) -eq '0x') { throw 'Vault has no deployed code.' }

    $balanceData = & cast calldata 'balances(address)' $depositor
    if ($LASTEXITCODE -ne 0) { throw 'Could not encode balance getter.' }
    $totalData = & cast calldata 'totalDeposits()'
    if ($LASTEXITCODE -ne 0) { throw 'Could not encode total getter.' }
    $before = Read-Balances 'Before deposit'
    Assert-Accounting $before 0

    $depositOutput = & cast send $vault 'deposit()' --value 1ether --rpc-url $rpcUrl --unlocked --from $depositor --json
    if ($LASTEXITCODE -ne 0) { throw 'Deposit transaction failed.' }
    $depositOutput | Set-Content -LiteralPath (Join-Path $runDir 'deposit-receipt.json') -Encoding utf8
    $depositReceipt = $depositOutput | ConvertFrom-Json
    Assert-Receipt $depositReceipt 'Deposited(address,uint256)' $weiPerETH
    $afterDeposit = Read-Balances 'Deposit 1 ETH'
    Assert-Accounting $afterDeposit $weiPerETH
    $depositGas = (Convert-HexToInteger $depositReceipt.gasUsed) * (Convert-HexToInteger $depositReceipt.effectiveGasPrice)
    if ([bigint]$afterDeposit.walletWei -ne ([bigint]$before.walletWei - $weiPerETH - $depositGas)) {
        throw 'Deposit wallet movement does not match value plus gas.'
    }

    $withdrawOutput = & cast send $vault 'withdraw(uint256)' $withdrawWei.ToString() --rpc-url $rpcUrl --unlocked --from $depositor --json
    if ($LASTEXITCODE -ne 0) { throw 'Withdrawal transaction failed.' }
    $withdrawOutput | Set-Content -LiteralPath (Join-Path $runDir 'withdrawal-receipt.json') -Encoding utf8
    $withdrawReceipt = $withdrawOutput | ConvertFrom-Json
    Assert-Receipt $withdrawReceipt 'Withdrawn(address,uint256)' $withdrawWei
    $afterWithdrawal = Read-Balances 'Withdraw 0.4 ETH'
    Assert-Accounting $afterWithdrawal ($weiPerETH - $withdrawWei)
    $withdrawGas = (Convert-HexToInteger $withdrawReceipt.gasUsed) * (Convert-HexToInteger $withdrawReceipt.effectiveGasPrice)
    if ([bigint]$afterWithdrawal.walletWei -ne ([bigint]$afterDeposit.walletWei + $withdrawWei - $withdrawGas)) {
        throw 'Withdrawal wallet movement does not match payment minus gas.'
    }

    $snapshots = @($before, $afterDeposit, $afterWithdrawal)
    [PSCustomObject]@{
        rpc = $rpcUrl; chainId = 31337; vault = $vault; deployer = $deployer; depositor = $depositor
        startedAnvilPid = $startedAnvilPid; snapshots = $snapshots
        depositGasWei = $depositGas.ToString(); withdrawalGasWei = $withdrawGas.ToString()
        deploymentTransaction = $deployment.transactionHash
        depositTransaction = $depositReceipt.transactionHash; withdrawalTransaction = $withdrawReceipt.transactionHash
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'demo.json') -Encoding utf8

    Write-Host "`nRPC:       $rpcUrl (chain 31337)"
    Write-Host "New vault: $vault"
    Write-Host "Depositor: $depositor"
    Write-Host 'Signing:   Anvil signs for its unlocked local test accounts (--unlocked); no private key is supplied.'
    Write-Host "`nBalances in ETH (rounded to 9 decimals; wallet includes gas):"
    $snapshots | ForEach-Object {
        [PSCustomObject]@{
            Stage = $_.stage
            Wallet = Format-ETH $_.walletWei
            Recorded = Format-ETH $_.recordedWei
            Vault = Format-ETH $_.vaultWei
            TotalOwed = Format-ETH $_.totalOwedWei
        }
    } | Format-Table -AutoSize | Out-String -Width 160 | Write-Host
    Write-Host 'Verified receipts, events, accounting, and exact wallet movements including gas.'
    Write-Host "Receipts and exact wei balances: $runDir"
    Write-Host 'Anvil remains running. Each execution deploys a new vault; existing vaults are preserved.'
    if ($startedAnvilPid) { Write-Host "To stop this Anvil: Stop-Process -Id $startedAnvilPid" }
} finally {
    Pop-Location
}
