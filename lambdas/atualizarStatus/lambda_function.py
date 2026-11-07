"""
atualizarStatus
Disparada pelos eventos "PedidoValidado" e "PedidoRejeitado".
Grava (ou atualiza) o pedido e seu status na tabela DynamoDB "Pedidos".
"""
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3

tabela = boto3.resource("dynamodb").Table(os.environ.get("TABLE_NAME", "Pedidos"))


def lambda_handler(event, context):
    pedido = event.get("detail", {})
    pedido_id = str(pedido.get("pedidoId") or "SEM-ID")
    status = "VALIDADO" if event.get("detail-type") == "PedidoValidado" else "REJEITADO"

    try:
        valor = Decimal(str(pedido.get("valor", 0)))
    except Exception:
        valor = Decimal("0")

    item = {
        "pedidoId": pedido_id,
        "cliente": pedido.get("cliente") or "-",
        "valor": valor,
        "qtdItens": len(pedido.get("itens") or []),
        "status": status,
        "motivo": pedido.get("motivo", ""),
        "atualizadoEm": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    tabela.put_item(Item=item)
    print(f"[atualizarStatus] Pedido {pedido_id} gravado no DynamoDB com status {status}")
    return {"pedidoId": pedido_id, "status": status}
