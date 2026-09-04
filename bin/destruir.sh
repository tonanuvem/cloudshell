#!/bin/bash

# Localiza o proprio diretorio (bin/) para achar a lib e os
# scripts irmaos, sem depender de copias no $HOME.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/destruir.sh <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
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
echo " DESTRUIR INFRAESTRUTURA"
echo "========================================"
echo "Projeto : $PROJECT"
echo "State   : s3://$BUCKET_NAME/$TFSTATE_KEY"
echo ""

if ! grep -Rqs 'backend[[:space:]]*"s3"' "$TF_DIR"/*.tf 2>/dev/null; then

    cat > "$TF_DIR/backend.tf" <<EOF
terraform {
  backend "s3" {}
}
EOF

fi

echo ">> Terraform init..."

tf_init "$PROJECT"

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform init terminou com erro."
    exit "$RC"
fi

echo ""
echo ">> Terraform destroy..."
echo ""

tf_run_unlock "$TF_DIR" destroy -auto-approve

RC=$?

echo ""

if [ "$RC" -eq 0 ]; then
    echo "✅ Infraestrutura destruída."
else
    echo "❌ Terraform terminou com erro."
fi

exit "$RC"
