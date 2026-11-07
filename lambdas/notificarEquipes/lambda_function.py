"""
notificarEquipes
Disparada pelo evento "PedidoValidado".
Publica no topico SNS uma mensagem para as equipes de logistica e atendimento.
"""
import json
import os

import boto3

sns = boto3.client("sns")
TOPIC_ARN = os.environ["TOPIC_ARN"]


def lambda_handler(event, context):
    pedido = event.get("detail", {})
    pedido_id = pedido.get("pedidoId")

    mensagem = {
        "assunto": f"Novo pedido {pedido_id} pronto para separacao",
        "pedidoId": pedido_id,
        "cliente": pedido.get("cliente"),
        "valor": pedido.get("valor"),
        "itens": pedido.get("itens"),
        "equipes": ["logistica", "atendimento"],
    }
    resp = sns.publish(
        TopicArn=TOPIC_ARN,
        Subject=f"Pedido {pedido_id} validado",
        Message=json.dumps(mensagem, ensure_ascii=False),
    )
    print(f"[notificarEquipes] Pedido {pedido_id}: logistica e atendimento notificadas "
          f"via SNS (MessageId {resp['MessageId']})")
    return {"pedidoId": pedido_id, "messageId": resp["MessageId"]}
