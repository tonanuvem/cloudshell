#!/bin/bash

# Localiza o proprio diretorio (bin/) para achar a lib e os
# scripts irmaos, sem depender de copias no $HOME.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/status.sh <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

# Garante Terraform instalado, para o script funcionar rodado
# direto -- e nao so pelo menu.
prepare_tools_tf || exit 1

aws_require || exit 1

tf_ensure_init "$PROJECT" || exit 1

echo ""
echo "========================================"
echo " STATUS"
echo "========================================"
echo "Projeto: $PROJECT"
echo ""

STATE_JSON=$(terraform -chdir="$TF_DIR" show -json 2>/dev/null)

if [ -z "$STATE_JSON" ]; then
    echo "Terraform state: ainda não inicializado."
    echo "Execute a opção 1) Criar infraestrutura."
    exit 0
fi

INSTANCE_COUNT=$(echo "$STATE_JSON" |
    jq '[.. | objects | select(.type? == "aws_instance") | .instances[]?] | length' \
    2>/dev/null)

if [ -z "$INSTANCE_COUNT" ] || [ "$INSTANCE_COUNT" = "null" ]; then
    INSTANCE_COUNT=0
fi

echo "EC2 encontradas no state: $INSTANCE_COUNT"
echo ""

if [ "$INSTANCE_COUNT" -gt 0 ]; then

    echo "$STATE_JSON" |
        jq -r '
            .. |
            objects |
            select(.type? == "aws_instance") |
            .instances[]? |
            [
                .attributes.id,
                (.attributes.public_ip // "-"),
                (.attributes.instance_state // "-")
            ] |
            @tsv
        ' 2>/dev/null |
    while IFS=$'\t' read -r ID IP STATE; do

        echo "ID     : $ID"
        echo "IP     : $IP"
        echo "Estado : $STATE"
        echo ""

    done
fi

exit 0
