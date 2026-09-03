#!/bin/bash

# Localiza o proprio diretorio (bin/) para achar a lib e os
# scripts irmaos, sem depender de copias no $HOME.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/ansible.sh <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

# O /tmp pode ter sido apagado pelo CloudShell: a lib reconstroi
# o venv em vez de mandar o aluno reiniciar o menu.
prepare_tmp_environment

ensure_ansible || exit 1

aws_require || exit 1

tf_ensure_init "$PROJECT" || exit 1

echo ""
echo "========================================"
echo " ANSIBLE"
echo "========================================"
echo "Projeto : $PROJECT"
echo ""

# ------------------------------------------------------------
# 1) ajustar.sh do projeto
#
# E o caminho canonico de configuracao: monta o inventario com
# os IPs reais das VMs e roda a sequencia de playbooks correta.
# Antes, esta opcao so procurava *.yml dentro da pasta do projeto
# -- e o ubuntu-vm nao tem nenhum, entao a opcao 5 do menu nunca
# funcionava justamente no projeto principal.
# ------------------------------------------------------------

AJUSTAR="$TF_DIR/ajustar.sh"

if [ -f "$AJUSTAR" ]; then

    echo ">> Executando ajustar.sh do projeto..."
    echo ""

    export FIAPLAB_INVENTORY="$INVENTORY_DIR/${PROJECT}.hosts"

    mkdir -p "$INVENTORY_DIR"

    bash "$AJUSTAR"

    RC=$?

    echo ""

    if [ "$RC" -eq 0 ]; then
        echo "✅ Configuração concluída."
    else
        echo "❌ Configuração terminou com erro."
    fi

    exit "$RC"
fi

# ------------------------------------------------------------
# 2) Playbooks proprios do projeto
#
# O inventario e montado a partir do state, apontando para as
# VMs. Antes usava-se $CONFIG_DIR/hosts, que e o inventario
# local do CloudShell: os playbooks rodariam contra o proprio
# CloudShell, e nao contra a VM do aluno.
# ------------------------------------------------------------

PLAYBOOKS=()

while IFS= read -r FILE; do
    PLAYBOOKS+=("$FILE")
done < <(
    find "$TF_DIR" \
        -maxdepth 1 \
        -type f \
        \( -name "*.yml" -o -name "*.yaml" \) \
        -print |
    sort
)

if [ "${#PLAYBOOKS[@]}" -eq 0 ]; then
    echo "❌ O projeto '$PROJECT' não possui ajustar.sh nem playbooks."
    echo ""
    echo "   $TF_DIR"
    echo ""
    exit 1
fi

if [ "${#PLAYBOOKS[@]}" -eq 1 ]; then

    PLAYBOOK="${PLAYBOOKS[0]}"

else

    echo "Playbooks disponíveis:"
    echo ""

    for i in "${!PLAYBOOKS[@]}"; do
        echo "$((i + 1))) $(basename "${PLAYBOOKS[$i]}")"
    done

    echo ""

    read -rp "Escolha o playbook: " NUMERO

    if ! [[ "$NUMERO" =~ ^[0-9]+$ ]]; then
        echo "❌ Número inválido."
        exit 1
    fi

    INDEX=$((NUMERO - 1))

    if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#PLAYBOOKS[@]}" ]; then
        echo "❌ Número inválido."
        exit 1
    fi

    PLAYBOOK="${PLAYBOOKS[$INDEX]}"
fi

if ! tf_write_inventory "$PROJECT"; then
    echo "❌ Nenhuma VM encontrada no state do projeto."
    echo ""
    echo "Use primeiro a opção:  1) Criar infraestrutura"
    echo ""
    exit 1
fi

KEY="$ENV_DIR/labsuser.pem"

if [ ! -f "$KEY" ]; then
    echo "❌ Chave SSH não encontrada: $KEY"
    exit 1
fi

echo "Playbook: $(basename "$PLAYBOOK")"
echo "Inventário:"
cat "$INVENTORY_FILE"
echo ""

ansible-playbook \
    -i "$INVENTORY_FILE" \
    -u ubuntu \
    --key-file "$KEY" \
    "$PLAYBOOK"

RC=$?

echo ""

if [ "$RC" -eq 0 ]; then
    echo "✅ Ansible executado."
else
    echo "❌ Ansible terminou com erro."
fi

exit "$RC"
