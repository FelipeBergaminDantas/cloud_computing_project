# deploy.ps1 - cria/atualiza toda a infraestrutura serverless da TechCommerce no LocalStack.
# Idempotente: pode ser executado varias vezes sem erro.
. "$PSScriptRoot\scripts\common.ps1"
Push-Location $PSScriptRoot
try {

Write-Title "DEPLOY TechCommerce - LocalStack em $Endpoint ($Region)"

# ---------------------------------------------------------------- 0. LocalStack no ar?
if (-not (Test-Aws sts get-caller-identity)) {
    throw "LocalStack nao responde em $Endpoint. Rode: docker compose up -d"
}

# ---------------------------------------------------------------- 1. Event bus
Write-Step "Event bus '$BusName'"
if (-not (Test-Aws events describe-event-bus --name $BusName)) {
    Invoke-Aws events create-event-bus --name $BusName | Out-Null
}

# ---------------------------------------------------------------- 2. DynamoDB
Write-Step "Tabela DynamoDB '$TableName' (chave pedidoId)"
if (-not (Test-Aws dynamodb describe-table --table-name $TableName)) {
    Invoke-Aws dynamodb create-table --table-name $TableName `
        --attribute-definitions 'AttributeName=pedidoId,AttributeType=S' `
        --key-schema 'AttributeName=pedidoId,KeyType=HASH' `
        --billing-mode PAY_PER_REQUEST | Out-Null
    Invoke-Aws dynamodb wait table-exists --table-name $TableName
}

# ---------------------------------------------------------------- 3. S3
Write-Step "Bucket S3 '$BucketName'"
if (-not (Test-Aws s3api head-bucket --bucket $BucketName)) {
    Invoke-Aws s3api create-bucket --bucket $BucketName | Out-Null
}

# ---------------------------------------------------------------- 4. SNS + filas das equipes
Write-Step "Topico SNS '$TopicName' + filas SQS das equipes (assinantes)"
Invoke-Aws sns create-topic --name $TopicName | Out-Null      # create-topic e idempotente
foreach ($q in $QueueNames) {
    Invoke-Aws sqs create-queue --queue-name $q | Out-Null
    $queueArn = "arn:aws:sqs:${Region}:${Account}:$q"
    Invoke-Aws sns subscribe --topic-arn $TopicArn --protocol sqs `
        --notification-endpoint $queueArn --attributes RawMessageDelivery=true | Out-Null
    Write-Info "fila $q assinando o topico"
}

# ---------------------------------------------------------------- 5. IAM Role
Write-Step "Role IAM '$RoleName'"
$trust = Write-JsonFile '.build\trust.json' @'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
'@
$policy = Write-JsonFile '.build\policy.json' @"
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"},
 {"Effect":"Allow","Action":["events:PutEvents"],"Resource":"$BusArn"},
 {"Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:Scan"],"Resource":"arn:aws:dynamodb:${Region}:${Account}:table/$TableName"},
 {"Effect":"Allow","Action":["sns:Publish"],"Resource":"$TopicArn"},
 {"Effect":"Allow","Action":["s3:PutObject"],"Resource":"arn:aws:s3:::$BucketName/*"}
]}
"@
if (-not (Test-Aws iam get-role --role-name $RoleName)) {
    Invoke-Aws iam create-role --role-name $RoleName --assume-role-policy-document $trust | Out-Null
}
Invoke-Aws iam put-role-policy --role-name $RoleName --policy-name techcommerce-lambda-policy `
    --policy-document $policy | Out-Null
$RoleArn = "arn:aws:iam::${Account}:role/$RoleName"

# ---------------------------------------------------------------- 6. Lambdas
$envVars = Write-JsonFile '.build\env.json' @"
{"Variables":{"BUS_NAME":"$BusName","TABLE_NAME":"$TableName","BUCKET_NAME":"$BucketName","TOPIC_ARN":"$TopicArn"}}
"@
$funcoes = 'validarPedido', 'atualizarStatus', 'notificarEquipes', 'gerarRelatorioVendas'
foreach ($fn in $funcoes) {
    Write-Step "Lambda '$fn' (Python 3.12)"
    $zip = ".build\$fn.zip"
    Compress-Archive -Path "lambdas\$fn\lambda_function.py" -DestinationPath $zip -Force
    $zipUri = "fileb://" + ($zip -replace '\\', '/')

    if (Test-Aws lambda get-function --function-name $fn) {
        Invoke-Aws lambda update-function-code --function-name $fn --zip-file $zipUri | Out-Null
        Invoke-Aws lambda wait function-updated-v2 --function-name $fn
        Invoke-Aws lambda update-function-configuration --function-name $fn `
            --environment $envVars --timeout 30 | Out-Null
        Write-Info "codigo atualizado"
    } else {
        Invoke-Aws lambda create-function --function-name $fn --runtime python3.12 `
            --handler lambda_function.lambda_handler --role $RoleArn --zip-file $zipUri `
            --timeout 30 --memory-size 128 --environment $envVars | Out-Null
        Write-Info "funcao criada"
    }
    Invoke-Aws lambda wait function-active-v2 --function-name $fn
}

# ---------------------------------------------------------------- 7. Regras do EventBridge
# Cria a regra, liga a Lambda como alvo e autoriza o EventBridge a invoca-la.
function Connect-Rule($RuleName, $Function, $Bus, $Pattern, $Schedule) {
    if ($Schedule) {
        # So (re)cria a regra se ela nao existir ou se a expressao mudou.
        $atual = awslocal events describe-rule --name $RuleName --event-bus-name $Bus `
            --query ScheduleExpression --output text 2>$null
        if ($LASTEXITCODE -eq 0 -and $atual -ne $Schedule) {
            Test-Aws events remove-targets --rule $RuleName --event-bus-name $Bus --ids $Function | Out-Null
            Invoke-Aws events delete-rule --name $RuleName --event-bus-name $Bus | Out-Null
            $atual = $null
        }
        if ($atual -ne $Schedule) {
            Invoke-Aws events put-rule --name $RuleName --event-bus-name $Bus `
                --schedule-expression $Schedule --state ENABLED | Out-Null
        }
    } else {
        $p = Write-JsonFile ".build\pattern-$RuleName.json" $Pattern
        Invoke-Aws events put-rule --name $RuleName --event-bus-name $Bus `
            --event-pattern $p --state ENABLED | Out-Null
    }
    $fnArn = "arn:aws:lambda:${Region}:${Account}:function:$Function"
    # So registra o alvo se ainda nao existir (no LocalStack, repetir put-targets
    # em regra agendada duplica os disparos)
    $alvos = awslocal events list-targets-by-rule --rule $RuleName --event-bus-name $Bus `
        --query "Targets[?Arn=='$fnArn'].Id" --output text 2>$null
    if (-not $alvos) {
        Invoke-Aws events put-targets --rule $RuleName --event-bus-name $Bus `
            --targets "Id=$Function,Arn=$fnArn" | Out-Null
    }

    $ruleArn = if ($Bus -eq 'default') { "arn:aws:events:${Region}:${Account}:rule/$RuleName" }
               else { "arn:aws:events:${Region}:${Account}:rule/$Bus/$RuleName" }
    $sid = "eventbridge-$RuleName"
    Test-Aws lambda remove-permission --function-name $Function --statement-id $sid | Out-Null
    Invoke-Aws lambda add-permission --function-name $Function --statement-id $sid `
        --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn $ruleArn | Out-Null
    Write-Info "$RuleName -> $Function"
}

Write-Step "Regras do EventBridge (eventos da aplicacao)"
Connect-Rule 'regra-pedido-criado'    'validarPedido'    $BusName '{"source":["techcommerce.pedidos"],"detail-type":["PedidoCriado"]}'
Connect-Rule 'regra-status-validado'  'atualizarStatus'  $BusName '{"source":["techcommerce.pedidos"],"detail-type":["PedidoValidado"]}'
Connect-Rule 'regra-status-rejeitado' 'atualizarStatus'  $BusName '{"source":["techcommerce.pedidos"],"detail-type":["PedidoRejeitado"]}'
Connect-Rule 'regra-notificar-equipes' 'notificarEquipes' $BusName '{"source":["techcommerce.pedidos"],"detail-type":["PedidoValidado"]}'

Write-Step "Regra AGENDADA do EventBridge (relatorio de vendas)"
# Regras agendadas ficam no barramento 'default' (exigencia da AWS).
# DEMO:      rate(1 minute)
# PRODUCAO:  cron(0 9 * * ? *)   -> todos os dias as 09:00 UTC
$Schedule = 'rate(1 minute)'
# $Schedule = 'cron(0 9 * * ? *)'
Connect-Rule 'regra-relatorio-vendas' 'gerarRelatorioVendas' 'default' $null $Schedule

Write-Title "DEPLOY CONCLUIDO"
Invoke-Aws events list-rules --event-bus-name $BusName --query "Rules[].[Name,State]" --output table
Invoke-Aws events list-rules --query "Rules[?Name=='regra-relatorio-vendas'].[Name,ScheduleExpression,State]" --output table
Invoke-Aws lambda list-functions --query "Functions[].[FunctionName,Runtime,Handler]" --output table

} finally { Pop-Location }
