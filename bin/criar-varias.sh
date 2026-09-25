#!/bin/bash

# ============================================================
# criar-varias.sh - cria N VMs do projeto ubuntu-vm
#
# Pergunta a quantidade e chama o criar.sh passando a variavel do
# Terraform:
#
#     TF_VAR_quantidade=N  criar.sh ubuntu-vm
#
# Antes de perguntar, conta as instancias JA ligadas na regiao e
# calcula quantas ainda cabem, respeitando o limite do AWS Academy:
# no maximo 9 instancias por regiao (e 20+ simultaneas DESATIVAM a
# conta e apagam tudo). O script nunca deixa passar de 9.
# ============================================================

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJETO="ubuntu-vm"
MAX=9
REGION="${AWS_REGION:-us-east-1}"

echo ""
echo "========================================"
echo " CRIAR VÁRIAS VMs ($PROJETO)"
echo "========================================"
echo ""

# Credenciais válidas (também exigidas pelo criar.sh depois).
aws_require || exit 1

# ------------------------------------------------------------
# Conta instancias em execucao na regiao
# ------------------------------------------------------------

RUN_TOTAL=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null)

RUN_PROJ=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${FIAPLAB_NAME_FILTER}" \
              "Name=instance-state-name,Values=running" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null)

[[ "$RUN_TOTAL" =~ ^[0-9]+$ ]] || RUN_TOTAL=0
[[ "$RUN_PROJ"  =~ ^[0-9]+$ ]] || RUN_PROJ=0

# "Outras" = instancias ligadas que NAO sao deste projeto (contam no
# limite, mas nao serao substituidas pelo apply).
OUTRAS=$((RUN_TOTAL - RUN_PROJ))
[ "$OUTRAS" -lt 0 ] && OUTRAS=0

DISPONIVEL=$((MAX - OUTRAS))
[ "$DISPONIVEL" -gt "$MAX" ] && DISPONIVEL="$MAX"

echo "Região: $REGION"
echo "Ligadas agora: $RUN_TOTAL  (ubuntu-vm: $RUN_PROJ | outras: $OUTRAS)"
echo "Limite: $MAX por região → você pode ter até $DISPONIVEL VM(s) do $PROJETO."
echo ""

if [ "$DISPONIVEL" -lt 1 ]; then
    echo "❌ Sem espaço: já há $OUTRAS instância(s) de outros recursos ligada(s)"
    echo "   na região (limite de $MAX). Suspenda ou destrua algo antes."
    exit 1
fi

# ------------------------------------------------------------
# Quantidade
# ------------------------------------------------------------

read -rp "Quantas VMs criar? [1-$DISPONIVEL]: " QTD

if ! [[ "$QTD" =~ ^[0-9]+$ ]] || [ "$QTD" -lt 1 ] || [ "$QTD" -gt "$DISPONIVEL" ]; then
    echo ""
    echo "❌ Quantidade inválida. Informe um número de 1 a $DISPONIVEL."
    exit 1
fi

# ------------------------------------------------------------
# Sufixo do nome (variavel ec2_name do Terraform)
#
# O nome fica: <prefixo>-<N>-<sufixo>  (ex.: fiaplab-1-homolog).
# O prefixo (fiaplab) e o numero sao mantidos: o numero garante
# nomes unicos com varias VMs e o prefixo faz o menu encontra-las
# (filtro fiaplab-*). Default do sufixo: "aluno".
# ------------------------------------------------------------

PREFIXO="${FIAPLAB_NAME_FILTER%-*}"
SUFIXO="aluno"

echo ""
read -rp "Definir um sufixo de nome customizado? (s/N): " RESP_SUF

if [[ "$RESP_SUF" =~ ^[Ss]$ ]]; then
    read -rp "Sufixo (letras/números/hífen; ex.: homolog, turma1): " S
    if [[ "$S" =~ ^[A-Za-z0-9-]{1,20}$ ]]; then
        SUFIXO="$S"
    else
        echo ""
        echo "❌ Sufixo inválido (use letras, números ou hífen; até 20 caracteres)."
        exit 1
    fi
fi

echo ""
echo "Nomes: ${PREFIXO}-1-${SUFIXO} … ${PREFIXO}-${QTD}-${SUFIXO}"
echo ""
read -rp "Confirma criar $QTD VM(s)? (s/N): " CONFIRMA
[[ "$CONFIRMA" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

echo ""
echo ">> Criando $QTD VM(s) (${PREFIXO}-N-${SUFIXO})..."
echo ""

TF_VAR_quantidade="$QTD" TF_VAR_ec2_name="$SUFIXO" "$BIN_DIR/criar.sh" "$PROJETO"
