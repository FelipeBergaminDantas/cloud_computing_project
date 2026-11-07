"""
validarPedido
Disparada pela regra do EventBridge quando chega um evento "PedidoCriado".
Valida os dados do pedido e publica no barramento "PedidoValidado" ou "PedidoRejeitado".
"""
import json
import os

import boto3

# O LocalStack injeta AWS_ENDPOINT_URL, entao o boto3 fala com ele automaticamente
events = boto3.client("events")
BUS_NAME = os.environ.get("BUS_NAME", "techcommerce-bus")


def validar(pedido):
    """Retorna a lista de erros encontrados (lista vazia = pedido valido)."""
    erros = []
    if not pedido.get("pedidoId"):
        erros.append("pedidoId ausente")
    if not pedido.get("cliente"):
        erros.append("cliente ausente")
    try:
        if float(pedido.get("valor", 0)) <= 0:
            erros.append("valor deve ser maior que zero")
    except (TypeError, ValueError):
        erros.append("valor invalido")
    if not pedido.get("itens"):
        erros.append("pedido sem itens")
    return erros


def lambda_handler(event, context):
    pedido = event.get("detail", {})
    pedido_id = str(pedido.get("pedidoId", "?"))
    print(f"[validarPedido] Recebido evento PedidoCriado - pedido {pedido_id}")

    erros = validar(pedido)
    if erros:
        detail_type = "PedidoRejeitado"
        pedido["motivo"] = "; ".join(erros)
        print(f"[validarPedido] Pedido {pedido_id} REJEITADO: {pedido['motivo']}")
    else:
        detail_type = "PedidoValidado"
        print(f"[validarPedido] Pedido {pedido_id} VALIDADO")

    # Publica o resultado no barramento -> dispara as proximas Lambdas
    events.put_events(Entries=[{
        "Source": "techcommerce.pedidos",
        "DetailType": detail_type,
        "Detail": json.dumps(pedido),
        "EventBusName": BUS_NAME,
    }])
    print(f"[validarPedido] Evento {detail_type} publicado em {BUS_NAME}")
    return {"pedidoId": pedido_id, "resultado": detail_type}
