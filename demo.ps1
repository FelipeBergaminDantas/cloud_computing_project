# demo.ps1 - demonstra o fluxo orientado a eventos + o fluxo agendado, sem intervencao manual.
# Unica acao "manual": a aplicacao publica os eventos PedidoCriado. Todo o resto e automatico.
. "$PSScriptRoot\scripts\common.ps1"
Push-Location $PSScriptRoot
try {

$inicio = (Get-Date).ToUniversalTime().AddSeconds(-5)
$inicioIso = $inicio.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Limpa as filas das equipes para mostrar apenas as mensagens desta demo
foreach ($q in $QueueNames) {
    Test-Aws sqs purge-queue --queue-url "$Endpoint/$Account/$q" | Out-Null
}

# ------------------------------------------------------------------ 1. Eventos
Write-Title "1) APLICACAO PUBLICA EVENTOS 'PedidoCriado' NO techcommerce-bus"
foreach ($arq in 'pedido-valido.json', 'pedido-invalido.json') {
    $r = Invoke-Aws events put-events --entries "file://events/$arq" --output json | ConvertFrom-Json
    $det = (Get-Content "events\$arq" -Raw | ConvertFrom-Json)[0].Detail | ConvertFrom-Json
    Write-Step ("{0,-22} pedido {1}  cliente={2}  valor={3}  itens={4}  (EventId {5})" -f `
        $arq, $det.pedidoId, $det.cliente, [string]$det.valor, @($det.itens).Count, $r.Entries[0].EventId)
}

# ------------------------------------------------------------------ 2. Aguarda processamento
Write-Title "2) EVENTBRIDGE ROTEIA -> LAMBDAS PROCESSAM (aguardando...)"
$prazo = (Get-Date).AddSeconds(120)
do {
    Start-Sleep -Seconds 3
    $itens = (Invoke-Aws dynamodb scan --table-name $TableName --output json | ConvertFrom-Json).Items |
        Where-Object { $_.atualizadoEm.S -ge $inicioIso }
    Write-Host "." -NoNewline
} while (@($itens).Count -lt 2 -and (Get-Date) -lt $prazo)
Write-Host ''
$processadoEm = (Get-Date).ToUniversalTime()

# ------------------------------------------------------------------ 3. DynamoDB
Write-Title "3) STATUS DOS PEDIDOS NO DYNAMODB (tabela $TableName)"
$todos = (Invoke-Aws dynamodb scan --table-name $TableName --output json | ConvertFrom-Json).Items
$todos | Sort-Object { $_.pedidoId.S } | ForEach-Object {
    [pscustomobject]@{
        pedidoId     = $_.pedidoId.S
        cliente      = $_.cliente.S
        valor        = $_.valor.N
        itens        = $_.qtdItens.N
        status       = $_.status.S
        motivo       = $_.motivo.S
        atualizadoEm = $_.atualizadoEm.S
    }
} | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Write-Host $_.Trim("`r`n") }

# ------------------------------------------------------------------ 4. SNS -> equipes
Write-Title "4) NOTIFICACOES RECEBIDAS PELAS EQUIPES (SNS -> filas SQS)"
foreach ($q in $QueueNames) {
    $msgs = (Invoke-Aws sqs receive-message --queue-url "$Endpoint/$Account/$q" `
        --max-number-of-messages 10 --wait-time-seconds 2 --output json | ConvertFrom-Json).Messages
    if (-not $msgs) { Write-Info "$q : (nenhuma mensagem)"; continue }
    foreach ($m in $msgs) {
        $b = $m.Body | ConvertFrom-Json
        Write-Step "$q <- $($b.assunto) | cliente=$($b.cliente) valor=$($b.valor)"
    }
}

# ------------------------------------------------------------------ 5. Relatorio agendado
Write-Title "5) RELATORIO DE VENDAS GERADO POR AGENDAMENTO - rate(1 minute)"
Write-Info "Ninguem chama a Lambda: a regra agendada do EventBridge dispara a cada minuto. Aguardando..."
$prazo = (Get-Date).AddSeconds(150)
$relatorio = $null
do {
    $objs = (Invoke-Aws s3api list-objects-v2 --bucket $BucketName --prefix relatorios/ --output json |
        ConvertFrom-Json).Contents
    # Apenas relatorio gerado DEPOIS que os pedidos desta demo foram gravados
    $relatorio = $objs | Where-Object { ([datetimeoffset]$_.LastModified).UtcDateTime -gt $processadoEm } |
        Sort-Object Key | Select-Object -Last 1
    if (-not $relatorio) { Start-Sleep -Seconds 5; Write-Host "." -NoNewline }
} while (-not $relatorio -and (Get-Date) -lt $prazo)
Write-Host ''
if ($relatorio) {
    Write-Step "s3://$BucketName/$($relatorio.Key)  ($($relatorio.Size) bytes)"
    Write-Host ''
    Invoke-Aws s3 cp "s3://$BucketName/$($relatorio.Key)" - | ForEach-Object { Write-Host "     $_" -ForegroundColor Yellow }
} else {
    Write-Host "  Nenhum relatorio novo ainda - rode novamente em instantes." -ForegroundColor Red
}

# ------------------------------------------------------------------ 6. Logs
Write-Title "6) LOGS DAS LAMBDAS (CloudWatch Logs)"
foreach ($fn in 'validarPedido', 'atualizarStatus', 'notificarEquipes', 'gerarRelatorioVendas') {
    Write-Host ''
    Write-Host "  --- /aws/lambda/$fn ---" -ForegroundColor Magenta
    $linhas = awslocal logs tail "/aws/lambda/$fn" --since $inicioIso --format short 2>$null |
        Where-Object { $_ -match "\[$fn\]" }
    if ($fn -eq 'gerarRelatorioVendas') { $linhas = $linhas | Select-Object -Last 4 }
    if ($linhas) { $linhas | ForEach-Object { Write-Host "     $_" } }
    else { Write-Info "(sem logs ainda)" }
}

Write-Title "FIM DA DEMO - tudo executado automaticamente por eventos e agendamento"

} finally { Pop-Location }
