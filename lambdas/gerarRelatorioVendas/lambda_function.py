"""
gerarRelatorioVendas
Disparada por AGENDAMENTO (regra do EventBridge com schedule expression).
Le todos os pedidos do DynamoDB, gera um CSV e salva no bucket S3 de relatorios.
"""
import csv
import io
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3

tabela = boto3.resource("dynamodb").Table(os.environ.get("TABLE_NAME", "Pedidos"))
s3 = boto3.client("s3")
BUCKET = os.environ.get("BUCKET_NAME", "techcommerce-relatorios")


def ler_pedidos():
    """Scan paginado da tabela de pedidos."""
    resp = tabela.scan()
    itens = resp.get("Items", [])
    while "LastEvaluatedKey" in resp:
        resp = tabela.scan(ExclusiveStartKey=resp["LastEvaluatedKey"])
        itens.extend(resp.get("Items", []))
    return sorted(itens, key=lambda p: p["pedidoId"])


def lambda_handler(event, context):
    print("[gerarRelatorioVendas] Execucao agendada iniciada")
    pedidos = ler_pedidos()

    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(["pedidoId", "cliente", "valor", "qtdItens", "status", "atualizadoEm"])
    total_vendas = Decimal("0")
    for p in pedidos:
        writer.writerow([p["pedidoId"], p.get("cliente"), p.get("valor"),
                         p.get("qtdItens"), p.get("status"), p.get("atualizadoEm")])
        if p.get("status") == "VALIDADO":
            total_vendas += Decimal(str(p.get("valor", 0)))
    writer.writerow([])
    writer.writerow(["TOTAL VENDAS VALIDADAS", "", f"{total_vendas:.2f}", "", "", ""])

    agora = datetime.now(timezone.utc)
    chave = f"relatorios/vendas-{agora:%Y%m%d-%H%M%S}.csv"
    s3.put_object(Bucket=BUCKET, Key=chave, Body=buffer.getvalue().encode("utf-8"),
                  ContentType="text/csv")
    print(f"[gerarRelatorioVendas] {len(pedidos)} pedido(s), total validado R$ {total_vendas:.2f}"
          f" -> s3://{BUCKET}/{chave}")
    return {"arquivo": chave, "pedidos": len(pedidos)}
