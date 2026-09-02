#!/bin/bash

# Encerra o script caso algum comando falhe
set -e

# Região padrão para os recursos do Backend no S3 / DynamoDB
AWS_REGION="${AWS_REGION:-us-east-1}"

# Diretório base do projeto
PASTA_ENV="$HOME/environment"
PASTA_CONFIG="$PASTA_ENV/config"
PASTA_CRED="$PASTA_ENV/credenciais"

# ------------------------------------------------------------
# CLONAR CONFIG
# ------------------------------------------------------------
if [ ! -d "$PASTA_CONFIG/.git" ]; then
    echo ""
    echo "📦 Clonando repositório tonanuvem/config..."
    rm -rf "$PASTA_CONFIG"
    git clone https://github.com/tonanuvem/config "$PASTA_CONFIG"
else
    echo ""
    echo "📦 Repositório config já existe."
    echo "🔄 Atualizando repositório..."
    (cd "$PASTA_CONFIG" && git pull --ff-only || true)
fi

# ------------------------------------------------------------
# GERAR CREDENCIAIS DA AWS
# ------------------------------------------------------------
echo "============================================================"
echo "    GERANDO ARQUIVO DE CREDENCIAIS DA AWS"
echo "============================================================"
echo ""

if [ -n "$AWS_CONTAINER_CREDENTIALS_FULL_URI" ] && [ -n "$AWS_CONTAINER_AUTHORIZATION_TOKEN" ]; then
    CREDS=$(curl -s -H "Authorization: $AWS_CONTAINER_AUTHORIZATION_TOKEN" "$AWS_CONTAINER_CREDENTIALS_FULL_URI")
    
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
region = us-east-1
output = json
EOF

        # Exporta variáveis para forçar ferramentas (como Ansible) a usarem estes arquivos
        export AWS_SHARED_CREDENTIALS_FILE="$PASTA_CRED/credentials"
        export AWS_CONFIG_FILE="$PASTA_CRED/config"

        echo "✅ Arquivos em $PASTA_CRED gerados com sucesso!"
    else
        echo "⚠️ Não foi possível extrair os campos do JSON de credenciais."
    fi
else
    echo "⚠️ Variáveis de ambiente do CloudShell não encontradas."
fi

echo ""
echo "============================================================"
echo "    INICIALIZANDO AMBIENTE NO AWS CLOUDSHELL"
echo "============================================================"
echo ""

# ------------------------------------------------------------
# 1. ESTRUTURA NO /tmp E CACHE DO TERRAFORM
# ------------------------------------------------------------
TMP_APP_DIR="/tmp/fiap"
mkdir -p "$TMP_APP_DIR/tf_cache"
mkdir -p "$TMP_APP_DIR/tf_projects"
mkdir -p "$TMP_APP_DIR/ansible_venv"

export TF_PLUGIN_CACHE_DIR="$TMP_APP_DIR/tf_cache"
export PATH="$TMP_APP_DIR/ansible_venv/bin:$PATH"

# Configuração global do Terraform para direcionar o cache de plugins ao /tmp
cat > ~/.terraformrc <<EOF
plugin_cache_dir = "$TMP_APP_DIR/tf_cache"
disable_checkpoint = true
EOF

# ------------------------------------------------------------
# 2. VERIFICAÇÃO E CRIAÇÃO DO BACKEND S3 + DYNAMODB
# ------------------------------------------------------------
echo "============================================================"
echo "    VERIFICANDO RECURSOS DE BACKEND (S3 + DYNAMODB)"
echo "============================================================"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="tfstate-cloudshell-${ACCOUNT_ID}"
DYNAMO_TABLE="terraform-locks"

echo "📋 Account ID: $ACCOUNT_ID"
echo "📦 Bucket S3:  $BUCKET_NAME"
echo "🔒 DynamoDB:   $DYNAMO_TABLE"
echo ""

# --- A. VERIFICA / CRIA BUCKET S3 ---
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "✅ Bucket S3 '$BUCKET_NAME' já existe."
else
    echo "⬇️ Bucket S3 não encontrado. Criando '$BUCKET_NAME'..."
    
    if [ "$AWS_REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi

    # Habilita Versionamento
    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled

    # Bloqueia Acesso Público
    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    echo "✅ Bucket S3 criado e configurado com sucesso!"
fi

# --- B. VERIFICA / CRIA TABELA DYNAMODB ---
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "✅ Tabela DynamoDB '$DYNAMO_TABLE' já existe."
else
    echo "⬇️ Tabela DynamoDB não encontrada. Criando '$DYNAMO_TABLE'..."
    
    aws dynamodb create-table \
        --table-name "$DYNAMO_TABLE" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$AWS_REGION"

    echo "⏳ Aguardando a tabela DynamoDB ficar ativa..."
    aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$AWS_REGION"
    
    echo "✅ Tabela DynamoDB criada com sucesso!"
fi

echo ""

# ------------------------------------------------------------
# 3. MAPEAMENTO DINÂMICO DAS SUBPASTAS PARA O /tmp
# ------------------------------------------------------------
if [ -d "$PASTA_CONFIG" ]; then
    echo "============================================================"
    echo "    MAPEANDO PASTAS .TERRAFORM DAS SUBPASTAS PARA O /tmp"
    echo "============================================================"
    echo ""

    find "$PASTA_CONFIG" -mindepth 1 -maxdepth 2 -type f -name "*.tf" -exec dirname {} \; | sort -u | while read -r SUBDIR; do
        FOLDER_NAME=$(basename "$SUBDIR")
        TMP_TF_DATA="$TMP_APP_DIR/tf_projects/$FOLDER_NAME"
        
        mkdir -p "$TMP_TF_DATA"
        
        # Se for um diretório real em vez de um link simbólico, remove para economizar espaço na home
        if [ -d "$SUBDIR/.terraform" ] && [ ! -L "$SUBDIR/.terraform" ]; then
            rm -rf "$SUBDIR/.terraform"
        fi
        
        # Cria o link simbólico apontando para o /tmp
        if [ ! -L "$SUBDIR/.terraform" ]; then
            ln -s "$TMP_TF_DATA" "$SUBDIR/.terraform"
            echo "🔗 Link criado: $FOLDER_NAME/.terraform -> $TMP_TF_DATA"
        else
            echo "✅ $FOLDER_NAME/.terraform já mapeado."
        fi
    done
    echo ""
fi

# ------------------------------------------------------------
# 4. TERRAFORM
# ------------------------------------------------------------
echo "============================================================"
echo "    CONFIGURANDO TERRAFORM"
echo "============================================================"
echo ""

if command -v terraform >/dev/null 2>&1; then
    echo "✅ Terraform já está instalado."
    terraform --version
else
    echo "⬇️ Terraform não encontrado. Instalando Terraform 1.16.0..."
    
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"

    curl -fsSL \
      "https://releases.hashicorp.com/terraform/1.16.0/terraform_1.16.0_linux_amd64.zip" \
      -o terraform.zip

    unzip -q terraform.zip
    sudo install -m 0755 terraform /usr/local/bin/terraform

    cd ~
    rm -rf "$TMP_DIR"

    echo "✅ Terraform instalado com sucesso."
    terraform --version
fi

echo ""

# ------------------------------------------------------------
# 5. ANSIBLE (VENV NO /tmp)
# ------------------------------------------------------------
echo "============================================================"
echo "    CONFIGURANDO ANSIBLE"
echo "============================================================"
echo ""

export ANSIBLE_PYTHON_INTERPRETER=auto_silent
export ANSIBLE_DEPRECATION_WARNINGS=false
export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false

if command -v ansible >/dev/null 2>&1; then
    echo "✅ Ansible já está pronto no venv."
    ansible --version
else
    echo "⬇️ Criando ambiente virtual no /tmp e instalando Ansible..."
    
    python3 -m venv "$TMP_APP_DIR/ansible_venv"
    "$TMP_APP_DIR/ansible_venv/bin/pip" install --no-cache-dir ansible

    echo "✅ Ansible instalado em ambiente isolado no /tmp."
    ansible --version
fi

echo ""

# ------------------------------------------------------------
# 6. INVENTÁRIO DO ANSIBLE
# ------------------------------------------------------------
if [ -d "$PASTA_CONFIG" ]; then
    echo "============================================================"
    echo "    CONFIGURANDO INVENTÁRIO ANSIBLE"
    echo "============================================================"
    echo ""

    cat > "$PASTA_CONFIG/hosts" <<EOF
[nodes]
cloudshell ansible_connection=local
EOF

    echo "✅ Inventário criado em $PASTA_CONFIG/hosts"
    echo ""
fi

# ------------------------------------------------------------
# 7. VERIFICAÇÃO DE ESPAÇO EM DISCO
# ------------------------------------------------------------
echo "============================================================"
echo "    VERIFICANDO DISCO DO CLOUDSHELL"
echo "============================================================"
echo ""

echo "--- Armazenamento Persistente (/home) ---"
df -h "$HOME"

echo ""
echo "--- Armazenamento Temporário (/tmp - 10GB) ---"
df -h /tmp

echo ""
echo "============================================================"
echo "🚀 PRONTO PARA USO!"
echo "============================================================"
