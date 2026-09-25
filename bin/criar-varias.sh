#!/bin/bash

# ============================================================
# criar-varias.sh - cria N VMs do projeto ubuntu-vm
#
# Pergunta a quantidade e chama o criar.sh passando a variavel do
# Terraform:
#
#     TF_VAR_quantidade=N  criar.sh ubuntu-vm
#
# Trava de seguranca: a conta do AWS Academy permite no maximo 9
# instancias por regiao (e 20+ instancias simultaneas DESATIVAM a
# conta e apagam tudo). Por isso o script so aceita 1..9 -- e esse
# limite conta as instancias que JA estao ligadas na regiao.
# ============================================================

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJETO="ubuntu-vm"
MAX=9

echo ""
echo "========================================"
echo " CRIAR VÁRIAS VMs ($PROJETO)"
echo "========================================"
echo ""
echo "Limite da conta: no máximo $MAX instâncias por região,"
echo "contando as que já estão ligadas."
echo ""

read -rp "Quantas VMs criar? [1-$MAX]: " QTD

if ! [[ "$QTD" =~ ^[0-9]+$ ]] || [ "$QTD" -lt 1 ] || [ "$QTD" -gt "$MAX" ]; then
    echo ""
    echo "❌ Quantidade inválida. Informe um número de 1 a $MAX."
    exit 1
fi

echo ""
echo ">> Criando $QTD VM(s) de $PROJETO..."
echo ""

TF_VAR_quantidade="$QTD" "$BIN_DIR/criar.sh" "$PROJETO"
