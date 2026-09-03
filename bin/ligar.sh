#!/bin/bash

source "$HOME/.fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/ligar.sh <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

aws_require || exit 1

tf_ensure_init "$PROJECT" || exit 1

echo ""
echo "========================================"
echo " LIGAR VM(S)"
echo "========================================"
echo ""

# Os IDs de instancia nao mudam: basta ler o state, sem a ida
# a AWS que o "terraform refresh" (deprecado) fazia aqui.
mapfile -t IDS < <(tf_instance_ids "$PROJECT" | grep -v '^[[:space:]]*$')

if [ "${#IDS[@]}" -eq 0 ]; then
    echo "❌ Nenhuma instância encontrada no Terraform."
    echo ""
    echo "Use primeiro a opção:  1) Criar infraestrutura"
    echo ""
    exit 1
fi

echo "Instâncias encontradas:"
echo ""

for i in "${!IDS[@]}"; do
    echo "$((i + 1))) ${IDS[$i]}"
done

echo ""

read -rp "Número da VM (ENTER = todas): " NUMERO

if [ -z "$NUMERO" ]; then

    echo ""
    echo ">> Ligando todas as VMs..."
    echo ""

    aws ec2 start-instances \
        --instance-ids "${IDS[@]}" \
        --region "$AWS_REGION"

    RC=$?

else

    if ! [[ "$NUMERO" =~ ^[0-9]+$ ]]; then
        echo "❌ Número inválido."
        exit 1
    fi

    INDEX=$((NUMERO - 1))

    if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#IDS[@]}" ]; then
        echo "❌ Número inválido."
        exit 1
    fi

    echo ""
    echo ">> Ligando ${IDS[$INDEX]}..."
    echo ""

    aws ec2 start-instances \
        --instance-ids "${IDS[$INDEX]}" \
        --region "$AWS_REGION"

    RC=$?
fi

echo ""

if [ "$RC" -eq 0 ]; then
    echo "✅ Comando enviado."
else
    echo "❌ Erro ao ligar instância(s)."
fi

exit "$RC"
