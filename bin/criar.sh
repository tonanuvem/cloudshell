#!/bin/bash

# Localiza o proprio diretorio (bin/) para achar a lib e os
# scripts irmaos, sem depender de copias no $HOME.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/criar.sh <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

if ! find "$TF_DIR" -maxdepth 1 -type f -name "*.tf" | grep -q .; then
    echo "❌ O diretório não possui arquivos Terraform:"
    echo "   $TF_DIR"
    exit 1
fi

# Credencial renovada agora, nao no boot do init.sh.
aws_require || exit 1

if ! get_account_id; then
    echo "❌ Não foi possível identificar a conta AWS."
    exit 1
fi

TFSTATE_KEY="${PROJECT}/terraform.tfstate"

echo ""
echo "========================================"
echo " CRIAR INFRAESTRUTURA"
echo "========================================"
echo "Projeto : $PROJECT"
echo "Diretório: $TF_DIR"
echo "State   : s3://$BUCKET_NAME/$TFSTATE_KEY"
echo ""

# ------------------------------------------------------------
# Backend
# ------------------------------------------------------------

if ! grep -Rqs 'backend[[:space:]]*"s3"' "$TF_DIR"/*.tf 2>/dev/null; then

    echo ">> Configurando backend S3..."

    cat > "$TF_DIR/backend.tf" <<EOF
terraform {
  backend "s3" {}
}
EOF

fi

# ------------------------------------------------------------
# Terraform init
# ------------------------------------------------------------

echo ">> Terraform init..."

tf_init "$PROJECT"

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform init terminou com erro."
    exit "$RC"
fi

# ------------------------------------------------------------
# Terraform apply
# ------------------------------------------------------------

echo ""
echo ">> Terraform apply..."
echo ""

terraform -chdir="$TF_DIR" apply -auto-approve

RC=$?

echo ""

if [ "$RC" -ne 0 ]; then
    echo "❌ Terraform terminou com erro."
    echo ""
    exit "$RC"
fi

echo "✅ Infraestrutura criada/atualizada."
echo ""

# ------------------------------------------------------------
# Configuração Ansible
# ------------------------------------------------------------

AJUSTAR_SCRIPT="$TF_DIR/ajustar.sh"

echo "========================================"
echo " CONFIGURAÇÃO ANSIBLE"
echo "========================================"
echo ""

if [ -f "$AJUSTAR_SCRIPT" ]; then

    echo ">> Executando ajustar.sh..."
    echo ""
    echo "   $AJUSTAR_SCRIPT"
    echo ""

    # Mantem o inventario fora do clone do repositorio config.
    export FIAPLAB_INVENTORY="$INVENTORY_DIR/${PROJECT}.hosts"

    mkdir -p "$INVENTORY_DIR"

    bash "$AJUSTAR_SCRIPT"

    RC=$?

    if [ "$RC" -ne 0 ]; then
        echo ""
        echo "❌ Configuração Ansible terminou com erro."
        echo ""
        exit "$RC"
    fi

    echo ""
    echo "✅ Configuração Ansible concluída."

else

    echo "ℹ️ Nenhum ajustar.sh encontrado."
    echo ""
    echo "   O projeto não possui configuração Ansible automática."
    echo ""

fi

