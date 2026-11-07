# destroy.ps1 - remove SOMENTE os recursos da TechCommerce criados pelo deploy.ps1 no LocalStack.
# Nao mexe em Docker. Para parar o LocalStack deste projeto: docker compose down
param([switch]$Force)
. "$PSScriptRoot\scripts\common.ps1"

if (-not $Force) {
    $r = Read-Host "Remover todos os recursos da TechCommerce do LocalStack? (s/N)"
    if ($r -notin 's', 'S') { Write-Host "Cancelado."; return }
}

Write-Title "DESTROY TechCommerce"

function Remove-Rule($Rule, $Bus, $TargetId) {
    Test-Aws events remove-targets --rule $Rule --event-bus-name $Bus --ids $TargetId | Out-Null
    if (Test-Aws events delete-rule --name $Rule --event-bus-name $Bus) { Write-Step "regra $Rule removida" }
}
Remove-Rule 'regra-pedido-criado'     $BusName  'validarPedido'
Remove-Rule 'regra-status-validado'   $BusName  'atualizarStatus'
Remove-Rule 'regra-status-rejeitado'  $BusName  'atualizarStatus'
Remove-Rule 'regra-notificar-equipes' $BusName  'notificarEquipes'
Remove-Rule 'regra-relatorio-vendas'  'default' 'gerarRelatorioVendas'

if (Test-Aws events delete-event-bus --name $BusName) { Write-Step "event bus $BusName removido" }

foreach ($fn in 'validarPedido', 'atualizarStatus', 'notificarEquipes', 'gerarRelatorioVendas') {
    if (Test-Aws lambda delete-function --function-name $fn) { Write-Step "lambda $fn removida" }
    Test-Aws logs delete-log-group --log-group-name "/aws/lambda/$fn" | Out-Null
}

if (Test-Aws dynamodb delete-table --table-name $TableName) { Write-Step "tabela $TableName removida" }

if (Test-Aws s3 rb "s3://$BucketName" --force) { Write-Step "bucket $BucketName removido" }

if (Test-Aws sns delete-topic --topic-arn $TopicArn) { Write-Step "topico $TopicName removido" }
foreach ($q in $QueueNames) {
    if (Test-Aws sqs delete-queue --queue-url "$Endpoint/$Account/$q") { Write-Step "fila $q removida" }
}

Test-Aws iam delete-role-policy --role-name $RoleName --policy-name techcommerce-lambda-policy | Out-Null
if (Test-Aws iam delete-role --role-name $RoleName) { Write-Step "role $RoleName removida" }

Remove-Item -Recurse -Force "$PSScriptRoot\.build" -ErrorAction SilentlyContinue
Write-Title "RECURSOS REMOVIDOS"
