#!/bin/bash

# ============================================================
# FIAP LAB - DESTRUIR E LIMPAR AMBIENTE
#
# Destroi a infraestrutura de TODOS os projetos com Terraform,
# remove o bucket de state e limpa os arquivos locais.
#
# Nao usa "set -e": uma falha ao destruir um projeto nao deve
# impedir a limpeza dos demais.
#
# A tabela DynamoDB foi descontinuada (o lock passou a
# use_lockfile=true no backend S3), entao este script nao
# cria, verifica nem remove DynamoDB.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Usa a biblioteca comum para credenciais, account id e /tmp.
if [ -f "$SCRIPT_DIR/bin/fiaplab.lib.sh" ]; then
    source "$SCRIPT_DIR/bin/fiaplab.lib.sh"
elif [ -f "$HOME/.fiaplab.lib.sh" ]; then
    source "$HOME/.fiaplab.lib.sh"
else
    echo "❌ Biblioteca fiaplab.lib.sh não encontrada."
    exit 1
fi

echo "============================================================"
echo "    ⚠️  DESTRUIÇÃO E LIMPEZA DO AMBIENTE AWS"
echo "============================================================"
echo ""
echo "Este script irá:"
echo "  1. Executar 'terraform destroy' em TODOS os projetos com .tf"
echo "  2. Remover o bucket S3 de state"
echo "  3. Limpar credenciais, caches, links e comandos locais"
echo ""

read -rp "Tem certeza que deseja DESTRUIR toda a infraestrutura? (s/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo "❌ Operação cancelada pelo usuário."
    exit 0
fi

# ------------------------------------------------------------
# Credenciais e conta
# ------------------------------------------------------------

aws_require || {
    echo ""
    echo "⚠️ Sem credenciais válidas: a infraestrutura na AWS não"
    echo "   pode ser destruída agora. Seguindo apenas com a limpeza"
    echo "   dos arquivos locais."
    echo ""
    SEM_AWS=1
}

if [ -z "$SEM_AWS" ]; then
    get_account_id || SEM_AWS=1
fi

prepare_tmp_environment

# ============================================================
# 1. TERRAFORM DESTROY EM TODOS OS PROJETOS
# ============================================================

echo ""
echo "============================================================"
echo " 1. DESTRUINDO INFRAESTRUTURA"
echo "============================================================"

if [ -z "$SEM_AWS" ] && command -v terraform >/dev/null 2>&1 && [ -d "$CONFIG_DIR" ]; then

    for SUBDIR in "$CONFIG_DIR"/*; do

        [ -d "$SUBDIR" ] || continue

        find "$SUBDIR" -maxdepth 1 -type f -name "*.tf" |
            grep -q . || continue

        PROJECT=$(basename "$SUBDIR")

        echo ""
        echo "------------------------------------------------------------"
        echo " Projeto: $PROJECT"
        echo "------------------------------------------------------------"

        # Garante backend S3 para conseguir ler o state remoto.
        if ! grep -Rqs 'backend[[:space:]]*"s3"' "$SUBDIR"/*.tf 2>/dev/null; then
            cat > "$SUBDIR/backend.tf" <<EOF
terraform {
  backend "s3" {}
}
EOF
        fi

        if tf_init "$PROJECT" >/dev/null 2>&1; then

            echo "🔥 terraform destroy..."
            terraform -chdir="$SUBDIR" destroy -auto-approve ||
                echo "⚠️ Falha ou nada a destruir em $PROJECT. Prosseguindo..."

        else
            echo "ℹ️ Sem state ativo em $PROJECT. Pulando."
        fi

    done

else
    echo ""
    echo "ℹ️ Etapa de destroy ignorada (sem AWS ou sem Terraform)."
fi

# ============================================================
# 2. REMOVER BUCKET S3 DE STATE
# ============================================================

echo ""
echo "============================================================"
echo " 2. REMOVENDO BUCKET S3 DE STATE"
echo "============================================================"
echo ""

if [ -z "$SEM_AWS" ] && [ -n "$BUCKET_NAME" ]; then

    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "🔥 Removendo s3://$BUCKET_NAME ..."
        aws s3 rb "s3://$BUCKET_NAME" --force &&
            echo "✅ Bucket removido." ||
            echo "⚠️ Não foi possível remover o bucket."
    else
        echo "✅ Bucket '$BUCKET_NAME' não existe ou já foi removido."
    fi

else
    echo "ℹ️ Remoção do bucket ignorada (sem AWS)."
fi

# ============================================================
# 3. LIMPAR ARQUIVOS LOCAIS
# ============================================================

echo ""
echo "============================================================"
echo " 3. LIMPANDO ARQUIVOS LOCAIS"
echo "============================================================"
echo ""

# Links .terraform (apontam para o /tmp).
if [ -d "$CONFIG_DIR" ]; then
    for SUBDIR in "$CONFIG_DIR"/*; do
        [ -L "$SUBDIR/.terraform" ] && rm -f "$SUBDIR/.terraform"
        rm -f "$SUBDIR/backend.tf"
    done
fi

# Diretorio temporario.
[ -d "$TMP_APP_DIR" ] && rm -rf "$TMP_APP_DIR" &&
    echo "🗑️ $TMP_APP_DIR removido."

# Binario do Terraform (precisa de sudo).
if [ -f "/usr/local/bin/terraform" ]; then
    sudo rm -f /usr/local/bin/terraform &&
        echo "🗑️ Terraform removido."
fi

# Credenciais, inventario local e configs.
[ -d "$CRED_DIR" ] && rm -rf "$CRED_DIR" && echo "🗑️ $CRED_DIR removido."
[ -f "$CONFIG_DIR/hosts" ] && rm -f "$CONFIG_DIR/hosts" && echo "🗑️ hosts removido."
[ -f "$HOME/.terraformrc" ] && rm -f "$HOME/.terraformrc" && echo "🗑️ ~/.terraformrc removido."
[ -f "$HOME/.fiaplab" ] && rm -f "$HOME/.fiaplab" && echo "🗑️ ~/.fiaplab removido."

# Comandos instalados no $HOME.
for CMD in fiaplab.sh criar.sh destruir.sh status.sh ligar.sh \
           suspender.sh conectar.sh ansible.sh ip .fiaplab.lib.sh; do
    [ -f "$HOME/$CMD" ] && rm -f "$HOME/$CMD"
done
echo "🗑️ Comandos do FIAP LAB removidos do \$HOME."

echo ""
echo "============================================================"
echo "✨ AMBIENTE LIMPO."
echo "============================================================"
