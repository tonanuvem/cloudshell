#!/bin/bash

# ============================================================
# refazer-vm.sh - refaz UMA VM de um lote
#
# O Refazer do menu age no lote inteiro: destroi e recria todas as
# VMs daquele state. Quando so uma VM quebrou (apt pela metade,
# disco cheio, aluno apagou algo), isso derruba a turma toda.
#
# Aqui o trabalho e cirurgico, e quem faz e o proprio Terraform:
#
#     terraform apply -replace='aws_instance.web[2]'
#
# O -replace marca SO aquela instancia para ser recriada; VPC,
# subnet, security group e as outras VMs do lote nao sao tocados.
# Nao e destroy + apply: o plano continua sendo um apply normal,
# entao o state nunca fica sem a instancia.
#
# Depois do apply a VM nova sobe limpa e com OUTRO IP publico, logo
# precisa da configuracao de novo. O script reaplica o ajustar.sh do
# projeto limitado a essa VM (FIAPLAB_LIMIT), em vez de reconfigurar
# o lote inteiro.
#
# A quantidade e o nome do lote sao lidos do state e repassados como
# TF_VAR_quantidade / TF_VAR_ec2_name: sem isso o apply usaria os
# defaults do projeto e, alem de recriar a VM, mudaria o tamanho do
# lote ou o nome das VMs.
#
# Uso:  refazer-vm.sh [projeto]      (default: ubuntu-vm)
# ============================================================

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJETO="${1:-ubuntu-vm}"
TF_DIR="$CONFIG_DIR/$PROJETO"

echo ""
echo "========================================"
echo " REFAZER UMA VM ($PROJETO)"
echo "========================================"

if [ ! -d "$TF_DIR" ]; then
    echo ""
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

# Terraform (apply) e Ansible (reconfigurar a VM nova).
prepare_tools || exit 1

aws_require || exit 1

if ! get_account_id; then
    echo "❌ Não foi possível identificar a conta AWS."
    exit 1
fi

# ------------------------------------------------------------
# 1. Lote (com um lote so, nao pergunta)
# ------------------------------------------------------------

tf_pick_batch "$PROJETO" || exit 0
LOTE="$TF_PICK_BATCH"

if [ -n "$LOTE" ]; then
    export TF_VAR_ec2_name="$LOTE"
else
    unset TF_VAR_ec2_name
fi

echo ""
echo ">> Lendo o state do lote ${LOTE:-(padrão)}..."

if ! tf_init "$PROJETO" "$LOTE" >/dev/null 2>&1; then
    echo ""
    echo "❌ Terraform init falhou; repetindo sem silenciar:"
    echo ""
    tf_init "$PROJETO" "$LOTE" || exit 1
fi

# Tamanho atual do lote: o apply tem de manter o lote do mesmo
# tamanho, so trocando a instancia escolhida.
QTD="$(tf_instance_ids "$PROJETO" | grep -v '^[[:space:]]*$' | wc -l)"

if [ "$QTD" -lt 1 ]; then
    echo ""
    echo "❌ O state do lote ${LOTE:-(padrão)} não tem nenhuma instância."
    exit 1
fi

export TF_VAR_quantidade="$QTD"

# ------------------------------------------------------------
# 2. VM dentro do lote
# ------------------------------------------------------------

tf_pick_instance "$PROJETO" || exit 0

ALVO="$TF_PICK_ADDRESS"
NOME="$TF_PICK_NAME"
IP_ANTIGO="$TF_PICK_IP"

echo ""
echo "----------------------------------------"
echo " Projeto : $PROJETO"
echo " Lote    : ${LOTE:-(padrão)}  (${QTD} VM(s))"
echo " VM      : $NOME"
echo " IP atual: $IP_ANTIGO"
echo " Recurso : $ALVO"
echo "----------------------------------------"
echo ""
echo "Esta VM será DESTRUÍDA e recriada do zero (disco novo,"
echo "IP público novo). As outras $((QTD - 1)) VM(s) do lote, a VPC e o"
echo "security group não são tocados."
echo ""
echo "Tudo que estiver só dentro desta VM será perdido."
echo ""

read -rp "Confirma refazer '$NOME'? (s/N): " CONFIRMA
[[ "$CONFIRMA" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# ------------------------------------------------------------
# 3. apply -replace
# ------------------------------------------------------------

echo ""
echo ">> Terraform apply -replace='$ALVO'..."
echo ""

tf_run_unlock "$TF_DIR" apply -replace="$ALVO" -auto-approve -input=false

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform terminou com erro; a VM pode não ter sido recriada."
    echo ""
    tf_init "$PROJETO" "" >/dev/null 2>&1
    exit "$RC"
fi

echo ""
echo "✅ VM recriada na AWS."

# A VM nova reaproveita nomes/IPs do pool do lab: chave antiga no
# known_hosts faria o ssh/scp do ajustar.sh abortar.
reset_known_hosts

# ------------------------------------------------------------
# 4. IP novo
# ------------------------------------------------------------

IP_NOVO="$(
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$NOME" \
                  "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].PublicIpAddress' \
        --output text 2>/dev/null | tr '\t' '\n' | grep -vE '^(None)?$' | head -1
)"

if [ -z "$IP_NOVO" ]; then
    echo ""
    echo "⚠️ Não consegui descobrir o IP novo de $NOME."
    echo "   Rode  ./ip  em alguns segundos e depois reaplique a"
    echo "   configuração com:  ajustar-varias.sh $PROJETO"
    tf_init "$PROJETO" "" >/dev/null 2>&1
    exit 1
fi

echo "   IP novo: $IP_NOVO  (era $IP_ANTIGO)"
echo ""

echo ">> Aguardando a VM aceitar SSH..."
wait_for_ssh "$IP_NOVO" || echo "   ⚠️ não respondeu a tempo; tentando configurar mesmo assim."
echo ""

# ------------------------------------------------------------
# 5. Reaplica a configuracao SO nesta VM
#
# FIAPLAB_LIMIT chega ao ajustar.sh do projeto, que o repassa como
# "--limit" do ansible-playbook. O inventario e montado com os IPs
# atuais do state (ja com o IP novo), e o hostname do inventario e
# a tag Name -- por isso o limite e o nome da VM.
# ------------------------------------------------------------

AJUSTAR="$TF_DIR/ajustar.sh"

if [ -f "$AJUSTAR" ]; then

    echo "========================================"
    echo " CONFIGURANDO $NOME"
    echo "========================================"
    echo ""

    export FIAPLAB_INVENTORY="$INVENTORY_DIR/${PROJETO}${LOTE:+-$LOTE}.hosts"
    export FIAPLAB_LIMIT="$NOME"

    mkdir -p "$INVENTORY_DIR"

    ( cd "$TF_DIR" && bash "$AJUSTAR" )
    RC=$?

    unset FIAPLAB_LIMIT

else

    echo "ℹ️ Nenhum ajustar.sh no projeto; aplicando os playbooks da pasta."
    echo ""

    KEY="$ENV_DIR/labsuser.pem"

    if [ ! -f "$KEY" ]; then
        echo "❌ Chave SSH não encontrada: $KEY"
        tf_init "$PROJETO" "" >/dev/null 2>&1
        exit 1
    fi

    INV="$INVENTORY_DIR/${PROJETO}${LOTE:+-$LOTE}-${NOME}.hosts"
    mkdir -p "$INVENTORY_DIR"
    printf '[nodes]\n%s ansible_ssh_host=%s\n' "$NOME" "$IP_NOVO" > "$INV"

    RC=0

    while IFS= read -r PB; do
        echo ">> ansible-playbook $(basename "$PB")"
        echo ""
        ansible-playbook -i "$INV" -u ubuntu --key-file "$KEY" "$PB" || RC=1
        echo ""
    done < <(
        find "$TF_DIR" -maxdepth 1 -type f \
            \( -name "*.yml" -o -name "*.yaml" \) -print | sort
    )
fi

# O .terraform da pasta do projeto e compartilhado: deixa-lo apontando
# para o lote refeito faria ligar/suspender/conectar operarem nele.
tf_init "$PROJETO" "" >/dev/null 2>&1

echo ""
if [ "$RC" -eq 0 ]; then
    echo "========================================"
    echo " ✅ $NOME refeita e configurada."
    echo "========================================"
    echo ""
    echo "   Code-server: http://${IP_NOVO}:${CODE_SERVER_PORT}"
    echo "   senha: ${CODE_SERVER_PASSWORD}"
else
    echo "========================================"
    echo " ⚠️ $NOME foi recriada, mas a configuração teve erro."
    echo "========================================"
    echo ""
    echo "   A VM existe e responde SSH. Para tentar a configuração"
    echo "   de novo:  ajustar-varias.sh $PROJETO"
fi
echo ""

exit "$RC"
