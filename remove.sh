#!/bin/bash

# Encerra se houver erro crítico
set -e

AWS_REGION="${AWS_REGION:-us-east-1}"
PASTA_ENV="$HOME/environment"
PASTA_CONFIG="$PASTA_ENV/config"
PASTA_CRED="$PASTA_ENV/credenciais"
TMP_APP_DIR="/tmp/fiap"

export PATH="$TMP_APP_DIR/ansible_venv/bin:$PATH"
export TF_PLUGIN_CACHE_DIR="$TMP_APP_DIR/tf_cache"

echo "============================================================"
echo "    ⚠️  ATENÇÃO: DESTRUIÇÃO E LIMPEZA DE AMBIENTE AWS"
echo "============================================================"
echo ""
echo "Este script irá:"
echo "  1. Executar 'terraform destroy' em TODAS as subpastas com .tf"
echo "  2. Apagar o Bucket S3 (State) e Tabela DynamoDB (Locks)"
echo "  3. Desfazer os links simbólicos e limpar o /tmp"
echo "  4. Remover arquivos de credenciais e caches locais"
echo ""

read -p "Tem certeza que deseja DESTRUIR toda a infraestrutura? (s/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo "❌ Operação cancelada pelo usuário."
    exit 0
fi

echo ""
echo "============================================================"
echo " 1. EXECUTANDO TERRAFORM DESTROY NAS SUBPASTAS"
echo "============================================================"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
BUCKET_NAME="tfstate-cloudshell-${ACCOUNT_ID}"

if [ -d "$PASTA_CONFIG" ]; then
    find "$PASTA_CONFIG" -mindepth 1 -maxdepth 2 -type f -name "*.tf" -exec dirname {} \; | sort -u | while read -r SUBDIR; do
        FOLDER_NAME=$(basename "$SUBDIR")
        echo "------------------------------------------------------------"
        echo "🔍 Verificando módulo: $FOLDER_NAME"
        echo "------------------------------------------------------------"

        cd "$SUBDIR"

        # Tenta inicializar o Terraform de forma silenciosa para ler o backend no S3
        if command -v terraform >/dev/null 2>&1; then
            if terraform init -backend-config="bucket=${BUCKET_NAME}" -input=false >/dev/null 2>&1; then
                echo "🔥 Executando 'terraform destroy' em $FOLDER_NAME..."
                terraform destroy -auto-approve -backend-config="bucket=${BUCKET_NAME}" || {
                    echo "⚠️ Aviso: Falha ou nada para destruir em $FOLDER_NAME. Prosseguindo..."
                }
            else
                echo "ℹ️  Módulo $FOLDER_NAME não inicializado ou sem estado ativo. Pulando..."
            fi
        else
            echo "⚠️  Terraform não encontrado. Pulando execução do destroy."
        fi
        
        cd ~
        echo ""
    done
fi

echo "============================================================"
echo " 2. REMOVENDO RECURSOS DE BACKEND DA AWS (S3 + DYNAMODB)"
echo "============================================================"
echo ""

if [ -n "$ACCOUNT_ID" ]; then
    DYNAMO_TABLE="terraform-locks"

    # --- A. DESTRUIR BUCKET S3 ---
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "🔥 Bucket S3 '$BUCKET_NAME' encontrado. Esvaziando e removendo..."
        aws s3 rb "s3://$BUCKET_NAME" --force
        echo "✅ Bucket S3 removido com sucesso!"
    else
        echo "✅ Bucket S3 '$BUCKET_NAME' não existe ou já foi removido."
    fi

    echo ""

    # --- B. DESTRUIR TABELA DYNAMODB ---
    if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "🔥 Tabela DynamoDB '$DYNAMO_TABLE' encontrada. Excluindo..."
        aws dynamodb delete-table --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" >/dev/null

        echo "⏳ Aguardando confirmação de exclusão do DynamoDB..."
        aws dynamodb wait table-not-exists --table-name "$DYNAMO_TABLE" --region "$AWS_REGION"
        echo "✅ Tabela DynamoDB removida com sucesso!"
    else
        echo "✅ Tabela DynamoDB '$DYNAMO_TABLE' não existe ou já foi removida."
    fi
fi

echo ""
echo "============================================================"
echo " 3. DESFAZENDO LINKS SIMBÓLICOS DAS SUBPASTAS"
echo "============================================================"
echo ""

if [ -d "$PASTA_CONFIG" ]; then
    find "$PASTA_CONFIG" -mindepth 1 -maxdepth 2 -type f -name "*.tf" -exec dirname {} \; | sort -u | while read -r SUBDIR; do
        FOLDER_NAME=$(basename "$SUBDIR")
        
        if [ -L "$SUBDIR/.terraform" ]; then
            rm -f "$SUBDIR/.terraform"
            echo "🗑️ Link simbólico removido: $FOLDER_NAME/.terraform"
        fi
    done
fi

echo ""
echo "============================================================"
echo " 4. LIMPANDO ARQUIVOS LOCAIS, CACHES E FERRAMENTAS"
echo "============================================================"
echo ""

[ -d "$TMP_APP_DIR" ] && rm -rf "$TMP_APP_DIR" && echo "🗑️ Diretório temporário $TMP_APP_DIR limpo."
[ -f "/usr/local/bin/terraform" ] && sudo rm -f /usr/local/bin/terraform && echo "🗑️ Binário do Terraform removido."
[ -d "$PASTA_CRED" ] && rm -rf "$PASTA_CRED" && echo "🗑️ Pasta de credenciais $PASTA_CRED removida."
[ -f "$PASTA_CONFIG/hosts" ] && rm -f "$PASTA_CONFIG/hosts" && echo "🗑️ Arquivo hosts removido."
[ -f "$HOME/.terraformrc" ] && rm -f "$HOME/.terraformrc" && echo "🗑️ Arquivo ~/.terraformrc removido."

echo ""
echo "============================================================"
echo "✨ INFRAESTRUTURA E AMBIENTE LIMPOS COM SUCESSO!"
echo "============================================================"
