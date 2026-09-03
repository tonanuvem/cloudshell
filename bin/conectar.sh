#!/bin/bash

source "$HOME/.fiaplab.lib.sh"

PROJECT="$1"
NODENUM="${2:-1}"

if [ -z "$PROJECT" ]; then
    echo "Uso:"
    echo "  ~/conectar.sh <projeto> <numero>"
    echo ""
    echo "Exemplo:"
    echo "  ~/conectar.sh cluster 3"
    exit 1
fi

if ! [[ "$NODENUM" =~ ^[0-9]+$ ]] || [ "$NODENUM" -lt 1 ]; then
    echo "❌ Número da VM inválido."
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

KEY="$ENV_DIR/labsuser.pem"
CREDENTIALS="$CRED_DIR/credentials"

if [ ! -f "$KEY" ]; then
    echo "❌ Chave SSH não encontrada:"
    echo "   $KEY"
    exit 1
fi

# Regenera o arquivo de credenciais imediatamente antes do scp,
# para a VM nao receber um token ja vencido.
aws_require || exit 1

tf_ensure_init "$PROJECT" || exit 1

if [ ! -f "$CREDENTIALS" ]; then
    echo "❌ Credenciais AWS não encontradas:"
    echo "   $CREDENTIALS"
    exit 1
fi

echo ""
echo "Conectando ao projeto: $PROJECT"
echo ""
echo "Atualizando IP..."
echo ""

terraform -chdir="$TF_DIR" apply -refresh-only -auto-approve -input=false

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform refresh terminou com erro."
    exit "$RC"
fi

mapfile -t IPS < <(tf_public_ips "$PROJECT" | grep -v '^[[:space:]]*$')

INDEX=$((NODENUM - 1))
IP="${IPS[$INDEX]}"

if [ -z "$IP" ] || [ "$IP" = "null" ]; then

    echo ""
    echo "❌ Não foi possível obter o IP da VM $NODENUM."
    echo ""

    if [ "${#IPS[@]}" -gt 0 ]; then
        echo "IPs encontrados:"
        printf '%s\n' "${IPS[@]}"
    fi

    exit 1
fi

echo ""
echo "Conectando... IP = $IP"
echo ""

ssh \
    -o LogLevel=error \
    -o StrictHostKeyChecking=no \
    -i "$KEY" \
    ubuntu@"$IP" \
    "mkdir -p /home/ubuntu/.aws"

RC=$?

if [ "$RC" -ne 0 ]; then
    echo "❌ Não foi possível conectar à VM."
    exit "$RC"
fi

scp \
    -q \
    -o LogLevel=error \
    -o StrictHostKeyChecking=no \
    -i "$KEY" \
    "$CREDENTIALS" \
    ubuntu@"$IP":/home/ubuntu/.aws/credentials

RC=$?

if [ "$RC" -ne 0 ]; then
    echo "❌ Erro ao copiar credenciais."
    exit "$RC"
fi

if [ -f "$CRED_DIR/config" ]; then
    scp -q -o LogLevel=error -o StrictHostKeyChecking=no -i "$KEY" \
        "$CRED_DIR/config" \
        ubuntu@"$IP":/home/ubuntu/.aws/config
fi

ssh \
    -o LogLevel=error \
    -o StrictHostKeyChecking=no \
    -i "$KEY" \
    ubuntu@"$IP" \
    "chmod 600 /home/ubuntu/.aws/credentials"

ssh \
    -o LogLevel=error \
    -o StrictHostKeyChecking=no \
    -i "$KEY" \
    ubuntu@"$IP"
