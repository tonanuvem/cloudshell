#!/bin/bash

# O init pode parar se houver erro.
# set -e

AWS_REGION="${AWS_REGION:-us-east-1}"

PASTA_ENV="$HOME/environment"
PASTA_CONFIG="$PASTA_ENV/config"
PASTA_CRED="$PASTA_ENV/credenciais"

TMP_APP_DIR="/tmp/fiap"
ANSIBLE_VENV="$TMP_APP_DIR/ansible_venv"

echo ""
echo "========================================"
echo "        FIAP LAB - INITIALIZATION"
echo "========================================"
echo ""

# ============================================================
# 1. CONFIG / TERRAFORM PROJECTS
# ============================================================

echo ">> Atualizando repositório de configuração..."

if [ ! -d "$PASTA_CONFIG/.git" ]; then
    rm -rf "$PASTA_CONFIG"
    git clone https://github.com/tonanuvem/config "$PASTA_CONFIG"
else
    (
        cd "$PASTA_CONFIG"
        git pull --ff-only || true
    )
fi

# ============================================================
# 2. SSH KEY
# ============================================================

echo ">> Configurando chave SSH..."

if [ -s "$PASTA_ENV/labsuser.pem" ]; then
    chmod 400 "$PASTA_ENV/labsuser.pem"

elif [ -f "$HOME/labsuser.pem" ]; then
    cp -f "$HOME/labsuser.pem" "$PASTA_ENV/labsuser.pem"
    chmod 400 "$PASTA_ENV/labsuser.pem"

else
    echo ""
    echo "ERRO: chave labsuser.pem não encontrada."
    echo ""
    exit 1
fi

# ============================================================
# 3. AWS CREDENTIALS
# ============================================================

echo ">> Configurando credenciais AWS..."

if [ -n "$AWS_CONTAINER_CREDENTIALS_FULL_URI" ] && \
   [ -n "$AWS_CONTAINER_AUTHORIZATION_TOKEN" ]; then

    CREDS=$(curl -s \
        -H "Authorization: $AWS_CONTAINER_AUTHORIZATION_TOKEN" \
        "$AWS_CONTAINER_CREDENTIALS_FULL_URI")

    KEY_ID=$(echo "$CREDS" | jq -r '.AccessKeyId // empty')
    SECRET_KEY=$(echo "$CREDS" | jq -r '.SecretAccessKey // empty')
    SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Token // empty')

    if [ -n "$KEY_ID" ]; then

        mkdir -p "$PASTA_CRED"

        cat > "$PASTA_CRED/credentials" <<EOF
[default]
aws_access_key_id = ${KEY_ID}
aws_secret_access_key = ${SECRET_KEY}
aws_session_token = ${SESSION_TOKEN}
EOF

        cat > "$PASTA_CRED/config" <<EOF
[default]
region = ${AWS_REGION}
output = json
EOF

        export AWS_SHARED_CREDENTIALS_FILE="$PASTA_CRED/credentials"
        export AWS_CONFIG_FILE="$PASTA_CRED/config"
    fi
fi

# ============================================================
# 4. TEMPORARY ENVIRONMENT
# ============================================================

echo ">> Preparando ambiente temporário..."

mkdir -p "$TMP_APP_DIR/tf_cache"
mkdir -p "$TMP_APP_DIR/tf_projects"
mkdir -p "$TMP_APP_DIR/ansible_venv"

export TF_PLUGIN_CACHE_DIR="$TMP_APP_DIR/tf_cache"
export PATH="$ANSIBLE_VENV/bin:$PATH"

cat > "$HOME/.terraformrc" <<EOF
plugin_cache_dir = "$TMP_APP_DIR/tf_cache"
disable_checkpoint = true
EOF

# ============================================================
# 5. AWS ACCOUNT
# ============================================================

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text)

BUCKET_NAME="tfstate-cloudshell-${ACCOUNT_ID}"
# DYNAMO_TABLE="terraform-locks" # nao uso mais

echo ""
echo "AWS Account : $ACCOUNT_ID"
echo "AWS Region  : $AWS_REGION"
echo "S3 Bucket   : $BUCKET_NAME"
# Histórico:
# echo "DynamoDB    : $DYNAMO_TABLE"
echo ""

# ============================================================
# 6. S3 BUCKET
# ============================================================

echo ">> Verificando bucket S3..."

if aws s3api head-bucket \
    --bucket "$BUCKET_NAME" \
    >/dev/null 2>&1; then

    echo "   Bucket já existe."

else

    echo "   Criando bucket..."

    if [ "$AWS_REGION" = "us-east-1" ]; then

        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$AWS_REGION"

    else

        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$AWS_REGION" \
            --create-bucket-configuration \
            LocationConstraint="$AWS_REGION"

    fi
fi

# ============================================================
# 7. DYNAMODB LOCK - DESCONTINUADO
# ============================================================

# Histórico:
# O Terraform utilizava anteriormente o DynamoDB para realizar
# o locking do state.
#
# A configuração foi substituída por:
#
#     use_lockfile = true
#
# no backend S3.
#
# Portanto, esta seção foi mantida apenas como histórico e
# não deve mais criar, verificar ou utilizar a tabela DynamoDB.
#
# DYNAMO_TABLE="terraform-locks"
#
# echo ">> Verificando tabela DynamoDB..."
#
# if aws dynamodb describe-table \
#     --table-name "$DYNAMO_TABLE" \
#     --region "$AWS_REGION" \
#     >/dev/null 2>&1; then
#
#     echo "   Tabela já existe."
#
# else
#
#     echo "   Criando tabela..."
#
#     aws dynamodb create-table \
#         --table-name "$DYNAMO_TABLE" \
#         --attribute-definitions \
#             AttributeName=LockID,AttributeType=S \
#         --key-schema \
#             AttributeName=LockID,KeyType=HASH \
#         --billing-mode PAY_PER_REQUEST \
#         --region "$AWS_REGION"
#
#     echo "   Aguardando tabela ficar disponível..."
#
#     aws dynamodb wait table-exists \
#         --table-name "$DYNAMO_TABLE" \
#         --region "$AWS_REGION"
# fi

# ============================================================
# 8. MAP TERRAFORM PROJECTS
# ============================================================

echo ">> Preparando diretórios Terraform..."

if [ -d "$PASTA_CONFIG" ]; then

    find "$PASTA_CONFIG" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -print0 |
    while IFS= read -r -d '' SUBDIR; do

        # Só considera diretório que possui arquivos .tf
        if ! find "$SUBDIR" \
            -maxdepth 1 \
            -type f \
            -name "*.tf" |
            grep -q .; then
            continue
        fi

        FOLDER_NAME=$(basename "$SUBDIR")
        TMP_TF_DATA="$TMP_APP_DIR/tf_projects/$FOLDER_NAME"

        mkdir -p "$TMP_TF_DATA"

        if [ -d "$SUBDIR/.terraform" ] && \
           [ ! -L "$SUBDIR/.terraform" ]; then

            rm -rf "$SUBDIR/.terraform"
        fi

        if [ ! -L "$SUBDIR/.terraform" ]; then
            ln -s "$TMP_TF_DATA" "$SUBDIR/.terraform"
        fi

    done
fi

# ============================================================
# 9. TERRAFORM
# ============================================================

echo ">> Verificando Terraform..."

if command -v terraform >/dev/null 2>&1; then

    echo "   Terraform já instalado:"
    terraform version | head -1

else

    echo "   Instalando Terraform 1.16.0..."

    cd /tmp

    rm -f terraform_1.16.0_linux_amd64.zip terraform

    curl -fsSL \
        -o terraform_1.16.0_linux_amd64.zip \
        https://releases.hashicorp.com/terraform/1.16.0/terraform_1.16.0_linux_amd64.zip

    unzip -o terraform_1.16.0_linux_amd64.zip

    sudo install terraform /usr/local/bin/terraform

    rm -f terraform terraform_1.16.0_linux_amd64.zip
fi

# ============================================================
# 10. ANSIBLE
# ============================================================

echo ">> Verificando Ansible..."

export ANSIBLE_PYTHON_INTERPRETER=auto_silent
export ANSIBLE_DEPRECATION_WARNINGS=false
export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false

if [ -x "$ANSIBLE_VENV/bin/ansible" ] && \
   [ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then

    echo "   Ansible já instalado."

else

    echo "   Criando ambiente virtual do Ansible..."

    rm -rf "$ANSIBLE_VENV"

    python3 -m venv "$ANSIBLE_VENV"

    "$ANSIBLE_VENV/bin/pip" install \
        --no-cache-dir \
        ansible
fi

# ============================================================
# 11. INVENTORY
# ============================================================

cat > "$PASTA_CONFIG/hosts" <<EOF
[nodes]
cloudshell ansible_connection=local
EOF

# ============================================================
# 12. GENERATE COMMANDS
# ============================================================

echo ""
echo "========================================"
echo "    CRIANDO FIAP LAB : MAQUINA VIRTUAL"
echo "========================================"
echo ""

bash "$HOME/cloudshell/comandos.sh"

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Erro ao criar os scripts do FIAP LAB."
    echo ""
    exit "$RC"
fi

bash "$HOME/criar.sh" ubuntu-vm

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Erro ao criar/configurar a infraestrutura ubuntu-vm."
    echo ""
    exit "$RC"
fi

# ============================================================
# 13. STATUS
# ============================================================

echo ""
echo "========================================"
echo "        AMBIENTE CONFIGURADO"
echo "========================================"
echo ""

df -h "$HOME"
echo ""
df -h /tmp
echo ""

bash "$HOME/ip" ubuntu-vm

echo ""
echo "========================================"
echo " Execute:"
echo ""
echo "   ~/fiaplab.sh"
echo ""
echo "========================================"
echo ""
