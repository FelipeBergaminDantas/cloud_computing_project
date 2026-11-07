# Configuracoes compartilhadas por deploy.ps1, demo.ps1 e destroy.ps1
# Se a porta 4566 estiver ocupada, altere LOCALSTACK_PORT (aqui e ao subir o compose).

# 'Continue' porque o PowerShell 5.1 trata stderr de executaveis como erro;
# o resultado dos comandos aws e conferido pelo $LASTEXITCODE.
$ErrorActionPreference = 'Continue'

$script:Port     = if ($env:LOCALSTACK_PORT) { $env:LOCALSTACK_PORT } else { '4566' }
$script:Endpoint = "http://localhost:$Port"
$script:Region   = 'us-east-1'
$script:Account  = '000000000000'   # conta padrao do LocalStack

# Credenciais ficticias exigidas pela AWS CLI (o LocalStack aceita qualquer valor)
$env:AWS_ACCESS_KEY_ID     = 'test'
$env:AWS_SECRET_ACCESS_KEY = 'test'
$env:AWS_DEFAULT_REGION    = $Region
$env:AWS_PAGER             = ''

# Nomes dos recursos
$script:BusName    = 'techcommerce-bus'
$script:TableName  = 'Pedidos'
$script:BucketName = 'techcommerce-relatorios'
$script:TopicName  = 'techcommerce-notificacoes'
$script:RoleName   = 'techcommerce-lambda-role'
$script:TopicArn   = "arn:aws:sns:${Region}:${Account}:${TopicName}"
$script:BusArn     = "arn:aws:events:${Region}:${Account}:event-bus/${BusName}"

# Equivalente ao "awslocal": AWS CLI apontando para o LocalStack
function awslocal {
    & aws --endpoint-url $script:Endpoint --region $script:Region @args
}

# Executa e falha (throw) se o comando der erro
function Invoke-Aws {
    $out = awslocal @args
    if ($LASTEXITCODE -ne 0) { throw "Falhou: awslocal $($args -join ' ')" }
    return $out
}

# Executa em silencio e devolve $true/$false (usado para checar se o recurso existe)
function Test-Aws {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    awslocal @args *> $null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $old
    return $ok
}

# Grava JSON em UTF-8 sem BOM (a AWS CLI nao aceita BOM) e devolve o caminho file://
function Write-JsonFile([string]$Path, [string]$Json) {
    $full = Join-Path (Get-Location) $Path
    New-Item -ItemType Directory -Force (Split-Path $full) | Out-Null
    [IO.File]::WriteAllText($full, $Json, (New-Object Text.UTF8Encoding($false)))
    return "file://$($Path -replace '\\','/')"
}

$script:QueueNames = @('techcommerce-logistica', 'techcommerce-atendimento')

function Write-Title([string]$Text) {
    $line = '=' * 70
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-Step([string]$Text) { Write-Host "  -> $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "     $Text" -ForegroundColor DarkGray }
