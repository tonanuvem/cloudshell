#!/bin/bash

# ============================================================
# FIAP LAB - COMANDOS
#
# Este script gera os comandos auxiliares em $HOME:
#
#   fiaplab.sh
#   criar.sh
#   ligar.sh
#   suspender.sh
#   conectar.sh
#   ansible.sh
#   status.sh
#   ip
#   destruir.sh
#
# Arquitetura:
#
#   S3
#      -> projetos que possuem Terraform State
#
#   $HOME/environment/config
#      -> projetos Terraform disponíveis localmente
#
# Tela inicial:
#      -> SOMENTE projetos existentes no S3
#
# Opção 1 - Criar infraestrutura:
#      -> mostra projetos locais
#      -> permite criar projeto novo
#
# Opção 8 - Trocar projeto:
#      -> SOMENTE projetos existentes no S3
#
# Não utiliza:
#      set -e
#      source comandos.sh
# ============================================================

HOME_DIR="$HOME"
ENV_DIR="$HOME/environment"
CONFIG_DIR="$ENV_DIR/config"
CRED_DIR="$ENV_DIR/credenciais"

mkdir -p "$CONFIG_DIR"

# ============================================================
# criar.sh
# ============================================================

cat > "$HOME_DIR/criar.sh" <<'EOF'
#!/bin/bash

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/criar.sh <projeto>"
    exit 1
fi

TF_DIR="$HOME/environment/config/$PROJECT"

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

AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -f "$HOME/environment/credenciais/credentials" ]; then
    export AWS_SHARED_CREDENTIALS_FILE="$HOME/environment/credenciais/credentials"
fi

if [ -f "$HOME/environment/credenciais/config" ]; then
    export AWS_CONFIG_FILE="$HOME/environment/credenciais/config"
fi

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text)

if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
    echo "❌ Não foi possível identificar a conta AWS."
    exit 1
fi

BUCKET_NAME="tfstate-cloudshell-${ACCOUNT_ID}"
DYNAMO_TABLE="terraform-locks"
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

    cat > "$TF_DIR/backend.tf" <<EOF2
terraform {
  backend "s3" {}
}
EOF2

fi

# ------------------------------------------------------------
# Terraform init
# ------------------------------------------------------------

echo ">> Terraform init..."

terraform -chdir="$TF_DIR" init -reconfigure \
    -backend-config="bucket=$BUCKET_NAME" \
    -backend-config="key=$TFSTATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="dynamodb_table=$DYNAMO_TABLE"

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

terraform -chdir="$TF_DIR" apply

RC=$?

echo ""

if [ "$RC" -eq 0 ]; then
    echo "✅ Infraestrutura criada/atualizada."
else
    echo "❌ Terraform terminou com erro."
fi

exit "$RC"
EOF

chmod +x "$HOME_DIR/criar.sh"


# ============================================================
# destruir.sh
# ============================================================

cat > "$HOME_DIR/destruir.sh" <<'EOF'
#!/bin/bash

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/destruir.sh <projeto>"
    exit 1
fi

TF_DIR="$HOME/environment/config/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -f "$HOME/environment/credenciais/credentials" ]; then
    export AWS_SHARED_CREDENTIALS_FILE="$HOME/environment/credenciais/credentials"
fi

if [ -f "$HOME/environment/credenciais/config" ]; then
    export AWS_CONFIG_FILE="$HOME/environment/credenciais/config"
fi

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text)

if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
    echo "❌ Não foi possível identificar a conta AWS."
    exit 1
fi

BUCKET_NAME="tfstate-cloudshell-${ACCOUNT_ID}"
DYNAMO_TABLE="terraform-locks"
TFSTATE_KEY="${PROJECT}/terraform.tfstate"

echo ""
echo "========================================"
echo " DESTRUIR INFRAESTRUTURA"
echo "========================================"
echo "Projeto : $PROJECT"
echo "State   : s3://$BUCKET_NAME/$TFSTATE_KEY"
echo ""

if ! grep -Rqs 'backend[[:space:]]*"s3"' "$TF_DIR"/*.tf 2>/dev/null; then

    cat > "$TF_DIR/backend.tf" <<EOF2
terraform {
  backend "s3" {}
}
EOF2

fi

echo ">> Terraform init..."

terraform -chdir="$TF_DIR" init -reconfigure \
    -backend-config="bucket=$BUCKET_NAME" \
    -backend-config="key=$TFSTATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="dynamodb_table=$DYNAMO_TABLE"

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform init terminou com erro."
    exit "$RC"
fi

echo ""
echo ">> Terraform destroy..."
echo ""

terraform -chdir="$TF_DIR" destroy

RC=$?

echo ""

if [ "$RC" -eq 0 ]; then
    echo "✅ Infraestrutura destruída."
else
    echo "❌ Terraform terminou com erro."
fi

exit "$RC"
EOF

chmod +x "$HOME_DIR/destruir.sh"


# ============================================================
# status.sh
# ============================================================

cat > "$HOME_DIR/status.sh" <<'EOF'
#!/bin/bash

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/status.sh <projeto>"
    exit 1
fi

TF_DIR="$HOME/environment/config/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

if [ -f "$HOME/environment/credenciais/credentials" ]; then
    export AWS_SHARED_CREDENTIALS_FILE="$HOME/environment/credenciais/credentials"
fi

if [ -f "$HOME/environment/credenciais/config" ]; then
    export AWS_CONFIG_FILE="$HOME/environment/credenciais/config"
fi

echo ""
echo "========================================"
echo " STATUS"
echo "========================================"
echo "Projeto: $PROJECT"
echo ""

STATE_JSON=$(terraform -chdir="$TF_DIR" show -json 2>/dev/null)

if [ -z "$STATE_JSON" ]; then
    echo "Terraform state: ainda não inicializado."
    echo "Execute a opção 1) Criar infraestrutura."
    exit 0
fi

INSTANCE_COUNT=$(echo "$STATE_JSON" |
    jq '[.. | objects | select(.type? == "aws_instance") | .instances[]?] | length' \
    2>/dev/null)

if [ -z "$INSTANCE_COUNT" ] || [ "$INSTANCE_COUNT" = "null" ]; then
    INSTANCE_COUNT=0
fi

echo "EC2 encontradas no state: $INSTANCE_COUNT"
echo ""

if [ "$INSTANCE_COUNT" -gt 0 ]; then

    echo "$STATE_JSON" |
        jq -r '
            .. |
            objects |
            select(.type? == "aws_instance") |
            .instances[]? |
            [
                .attributes.id,
                (.attributes.public_ip // "-"),
                (.attributes.instance_state // "-")
            ] |
            @tsv
        ' 2>/dev/null |
    while IFS=$'\t' read -r ID IP STATE; do

        echo "ID     : $ID"
        echo "IP     : $IP"
        echo "Estado : $STATE"
        echo ""

    done
fi

exit 0
EOF

chmod +x "$HOME_DIR/status.sh"


# ============================================================
# ip
# ============================================================

cat > "$HOME_DIR/ip" <<'EOF'
#!/bin/bash

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/ip <projeto>"
    exit 1
fi

TF_DIR="$HOME/environment/config/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

echo ""
echo "Atualizando state..."
echo ""

terraform -chdir="$TF_DIR" refresh

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform refresh terminou com erro."
    exit "$RC"
fi

echo ""
echo "IPs externos:"
echo ""

terraform -chdir="$TF_DIR" output -json 2>/dev/null |
    jq -r '
        .ip_externo.value? |
        if type == "string" then
            .
        else
            .. | strings
        end
    ' 2>/dev/null
EOF

chmod +x "$HOME_DIR/ip"


# ============================================================
# ligar.sh
# ============================================================

cat > "$HOME_DIR/ligar.sh" <<'EOF'
#!/bin/bash

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/ligar.sh <projeto>"
    exit 1
fi

TF_DIR="$HOME/environment/config/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -f "$HOME/environment/credenciais/credentials" ]; then
    export AWS_SHARED_CREDENTIALS_FILE="$HOME/environment/credenciais/credentials"
fi

if [ -f "$HOME/environment/credenciais/config" ]; then
    export AWS_CONFIG_FILE="$HOME/environment/credenciais/config"
fi

echo ""
echo "========================================"
echo " LIGAR VM(S)"
echo "========================================"
echo ""

terraform -chdir="$TF_DIR" refresh

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform refresh terminou com erro."
    exit "$RC"
fi

STATE_JSON=$(terraform -chdir="$TF_DIR" show -json)

RC=$?

if [ "$RC" -ne 0 ] || [ -z "$STATE_JSON" ]; then
    echo "❌ Não foi possível obter o Terraform state."
    exit 1
fi

IDS=($(echo "$STATE_JSON" |
    jq -r '
        .. |
        objects |
        select(.type? == "aws_instance") |
        .instances[]? |
        .attributes.id?
    '))

if [ "${#IDS[@]}" -eq 0 ]; then
    echo "❌ Nenhuma instância encontrada no Terraform."
    exit 1
fi

echo "Instâncias encontradas:"
echo ""

for i in "${!IDS[@]}"; do
    echo "$((i + 1))) ${IDS[$i]}"
done

echo ""

read -rp "Número da VM (ENTER = todas): " NUMERO

if [ -z "$NUMERO" ]; then

    echo ""
    echo ">> Ligando todas as VMs..."
    echo ""

    aws ec2 start-instances \
        --instance-ids "${IDS[@]}" \
        --region "$AWS_REGION"

    RC=$?

else

    if ! [[ "$NUMERO" =~ ^[0-9]+$ ]]; then
        echo "❌ Número inválido."
        exit 1
    fi

    INDEX=$((NUMERO - 1))

    if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#IDS[@]}" ]; then
        echo "❌ Número inválido."
        exit 1
    fi

    echo ""
    echo ">> Ligando ${IDS[$INDEX]}..."
    echo ""

    aws ec2 start-instances \
        --instance-ids "${IDS[$INDEX]}" \
        --region "$AWS_REGION"

    RC=$?
fi

echo ""

if [ "$RC" -eq 0 ]; then
    echo "✅ Comando enviado."
else
    echo "❌ Erro ao ligar instância(s)."
fi

exit "$RC"
EOF

chmod +x "$HOME_DIR/ligar.sh"


# ============================================================
# suspender.sh
# ============================================================

cat > "$HOME_DIR/suspender.sh" <<'EOF'
#!/bin/bash

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/suspender.sh <projeto>"
    exit 1
fi

TF_DIR="$HOME/environment/config/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -f "$HOME/environment/credenciais/credentials" ]; then
    export AWS_SHARED_CREDENTIALS_FILE="$HOME/environment/credenciais/credentials"
fi

if [ -f "$HOME/environment/credenciais/config" ]; then
    export AWS_CONFIG_FILE="$HOME/environment/credenciais/config"
fi

echo ""
echo "========================================"
echo " SUSPENDER VM(S)"
echo "========================================"
echo ""

terraform -chdir="$TF_DIR" refresh

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform refresh terminou com erro."
    exit "$RC"
fi

STATE_JSON=$(terraform -chdir="$TF_DIR" show -json)

RC=$?

if [ "$RC" -ne 0 ] || [ -z "$STATE_JSON" ]; then
    echo "❌ Não foi possível obter o Terraform state."
    exit 1
fi

IDS=($(echo "$STATE_JSON" |
    jq -r '
        .. |
        objects |
        select(.type? == "aws_instance") |
        .instances[]? |
        .attributes.id?
    '))

if [ "${#IDS[@]}" -eq 0 ]; then
    echo "❌ Nenhuma instância encontrada no Terraform."
    exit 1
fi

echo "Instâncias encontradas:"
echo ""

for i in "${!IDS[@]}"; do
    echo "$((i + 1))) ${IDS[$i]}"
done

echo ""

read -rp "Número da VM (ENTER = todas): " NUMERO

if [ -z "$NUMERO" ]; then

    echo ""
    echo ">> Suspendendo todas as VMs..."
    echo ""

    aws ec2 stop-instances \
        --instance-ids "${IDS[@]}" \
        --region "$AWS_REGION"

    RC=$?

else

    if ! [[ "$NUMERO" =~ ^[0-9]+$ ]]; then
        echo "❌ Número inválido."
        exit 1
    fi

    INDEX=$((NUMERO - 1))

    if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#IDS[@]}" ]; then
        echo "❌ Número inválido."
        exit 1
    fi

    echo ""
    echo ">> Suspendendo ${IDS[$INDEX]}..."
    echo ""

    aws ec2 stop-instances \
        --instance-ids "${IDS[$INDEX]}" \
        --region "$AWS_REGION"

    RC=$?
fi

echo ""

if [ "$RC" -eq 0 ]; then
    echo "✅ Comando enviado."
else
    echo "❌ Erro ao suspender instância(s)."
fi

exit "$RC"
EOF

chmod +x "$HOME_DIR/suspender.sh"


# ============================================================
# conectar.sh
# ============================================================

cat > "$HOME_DIR/conectar.sh" <<'EOF'
#!/bin/bash

PROJECT="$1"
NODENUM="${2:-1}"

if [ -z "$PROJECT" ]; then
    echo "Uso:"
    echo "  ~/conectar.sh <projeto> <numero>"
    echo ""
    echo "Exemplo:"
    echo "  ~/conectar.sh cluster 3"
    exit 1
fi

if ! [[ "$NODENUM" =~ ^[0-9]+$ ]] || [ "$NODENUM" -lt 1 ]; then
    echo "❌ Número da VM inválido."
    exit 1
fi

TF_DIR="$HOME/environment/config/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

KEY="$HOME/environment/labsuser.pem"
CREDENTIALS="$HOME/environment/credenciais/credentials"

if [ ! -f "$KEY" ]; then
    echo "❌ Chave SSH não encontrada:"
    echo "   $KEY"
    exit 1
fi

if [ ! -f "$CREDENTIALS" ]; then
    echo "❌ Credenciais AWS não encontradas:"
    echo "   $CREDENTIALS"
    exit 1
fi

echo ""
echo "Conectando ao projeto: $PROJECT"
echo ""
echo "Atualizando IP..."
echo ""

terraform -chdir="$TF_DIR" refresh

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform refresh terminou com erro."
    exit "$RC"
fi

IPS=(
    $(
        terraform -chdir="$TF_DIR" output -json 2>/dev/null |
        jq -r '
            .ip_externo.value? |
            if type == "string" then
                .
            else
                .. | strings
            end
        ' 2>/dev/null
    )
)

INDEX=$((NODENUM - 1))
IP="${IPS[$INDEX]}"

if [ -z "$IP" ] || [ "$IP" = "null" ]; then

    echo ""
    echo "❌ Não foi possível obter o IP da VM $NODENUM."
    echo ""

    if [ "${#IPS[@]}" -gt 0 ]; then
        echo "IPs encontrados:"
        printf '%s\n' "${IPS[@]}"
    fi

    exit 1
fi

echo ""
echo "Conectando... IP = $IP"
echo ""

ssh \
    -o LogLevel=error \
    -o StrictHostKeyChecking=no \
    -i "$KEY" \
    ubuntu@"$IP" \
    "mkdir -p /home/ubuntu/.aws"

RC=$?

if [ "$RC" -ne 0 ]; then
    echo "❌ Não foi possível conectar à VM."
    exit "$RC"
fi

scp \
    -q \
    -o LogLevel=error \
    -o StrictHostKeyChecking=no \
    -i "$KEY" \
    "$CREDENTIALS" \
    ubuntu@"$IP":/home/ubuntu/.aws/credentials

RC=$?

if [ "$RC" -ne 0 ]; then
    echo "❌ Erro ao copiar credenciais."
    exit "$RC"
fi

ssh \
    -o LogLevel=error \
    -o StrictHostKeyChecking=no \
    -i "$KEY" \
    ubuntu@"$IP" \
    "chmod 600 /home/ubuntu/.aws/credentials"

ssh \
    -o LogLevel=error \
    -o StrictHostKeyChecking=no \
    -i "$KEY" \
    ubuntu@"$IP"
EOF

chmod +x "$HOME_DIR/conectar.sh"


# ============================================================
# ansible.sh
# ============================================================

cat > "$HOME_DIR/ansible.sh" <<'EOF'
#!/bin/bash

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/ansible.sh <projeto>"
    exit 1
fi

TF_DIR="$HOME/environment/config/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

ANSIBLE_VENV="/tmp/fiap/ansible_venv"

if [ ! -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then
    echo "❌ Ansible não está disponível."
    echo ""
    echo "Execute:"
    echo "  ~/fiaplab.sh"
    echo ""
    echo "O ambiente será reconstruído automaticamente."
    exit 1
fi

export PATH="$ANSIBLE_VENV/bin:$PATH"
export ANSIBLE_PYTHON_INTERPRETER=auto_silent
export ANSIBLE_DEPRECATION_WARNINGS=false
export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false

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
    echo "❌ Nenhum playbook YAML encontrado em:"
    echo "   $TF_DIR"
    exit 1
fi

if [ "${#PLAYBOOKS[@]}" -eq 1 ]; then

    PLAYBOOK="${PLAYBOOKS[0]}"

else

    echo ""
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

echo ""
echo "========================================"
echo " ANSIBLE"
echo "========================================"
echo "Projeto : $PROJECT"
echo "Playbook: $(basename "$PLAYBOOK")"
echo ""

INVENTORY="$HOME/environment/config/hosts"

if [ ! -f "$INVENTORY" ]; then
    echo "❌ Inventory não encontrado:"
    echo "   $INVENTORY"
    exit 1
fi

ansible-playbook \
    -i "$INVENTORY" \
    "$PLAYBOOK"

RC=$?

echo ""

if [ "$RC" -eq 0 ]; then
    echo "✅ Ansible executado."
else
    echo "❌ Ansible terminou com erro."
fi

exit "$RC"
EOF

chmod +x "$HOME_DIR/ansible.sh"


# ============================================================
# fiaplab.sh
# ============================================================

cat > "$HOME_DIR/fiaplab.sh" <<'EOF'
#!/bin/bash

# ============================================================
# FIAP LAB - MENU PRINCIPAL
#
# REGRA DE PROJETOS:
#
# S3
#   -> fonte dos projetos que possuem Terraform State
#
# CONFIG LOCAL
#   -> fonte dos projetos Terraform disponíveis para criação
#
# TELA INICIAL:
#   -> somente projetos do S3
#
# SE S3 ESTIVER VAZIO:
#   -> nenhum projeto é selecionado
#   -> usuário entra no menu
#   -> opção 1 mostra projetos locais
#
# OPÇÃO 8:
#   -> somente projetos existentes no S3
#
# NÃO usa:
#   set -e
#   source comandos.sh
# ============================================================

ENV_DIR="$HOME/environment"
CONFIG_DIR="$ENV_DIR/config"
CRED_DIR="$ENV_DIR/credenciais"

TMP_APP_DIR="/tmp/fiap"
TF_CACHE="$TMP_APP_DIR/tf_cache"
TF_PROJECTS="$TMP_APP_DIR/tf_projects"
ANSIBLE_VENV="$TMP_APP_DIR/ansible_venv"

AWS_REGION="${AWS_REGION:-us-east-1}"

CURRENT_PROJECT=""
BUCKET_NAME=""

S3_PROJECTS=()
LOCAL_PROJECTS=()


# ============================================================
# PREPARAR AMBIENTE TEMPORÁRIO
# ============================================================

prepare_tmp_environment() {

    mkdir -p "$TF_CACHE"
    mkdir -p "$TF_PROJECTS"
    mkdir -p "$ANSIBLE_VENV"

    export TF_PLUGIN_CACHE_DIR="$TF_CACHE"

    case ":$PATH:" in
        *":$ANSIBLE_VENV/bin:"*)
            ;;
        *)
            export PATH="$ANSIBLE_VENV/bin:$PATH"
            ;;
    esac

    export ANSIBLE_PYTHON_INTERPRETER=auto_silent
    export ANSIBLE_DEPRECATION_WARNINGS=false
    export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false

    cat > "$HOME/.terraformrc" <<EOF2
plugin_cache_dir = "$TF_CACHE"
disable_checkpoint = true
EOF2

    if [ -f "$CRED_DIR/credentials" ]; then
        export AWS_SHARED_CREDENTIALS_FILE="$CRED_DIR/credentials"
    fi

    if [ -f "$CRED_DIR/config" ]; then
        export AWS_CONFIG_FILE="$CRED_DIR/config"
    fi
}


# ============================================================
# PREPARAR .TERRAFORM DOS PROJETOS
# ============================================================

prepare_terraform_projects() {

    if [ ! -d "$CONFIG_DIR" ]; then
        return 0
    fi

    for SUBDIR in "$CONFIG_DIR"/*; do

        [ -d "$SUBDIR" ] || continue

        if ! find "$SUBDIR" \
            -maxdepth 1 \
            -type f \
            -name "*.tf" |
            grep -q .; then
            continue
        fi

        PROJECT=$(basename "$SUBDIR")
        TMP_TF_DATA="$TF_PROJECTS/$PROJECT"

        mkdir -p "$TMP_TF_DATA"

        if [ -d "$SUBDIR/.terraform" ] && \
           [ ! -L "$SUBDIR/.terraform" ]; then

            rm -rf "$SUBDIR/.terraform"
        fi

        if [ ! -L "$SUBDIR/.terraform" ]; then
            ln -s "$TMP_TF_DATA" "$SUBDIR/.terraform"
        fi

    done
}


# ============================================================
# INSTALAR TERRAFORM SE NECESSÁRIO
# ============================================================

ensure_terraform() {

    if command -v terraform >/dev/null 2>&1; then
        return 0
    fi

    echo ""
    echo "⚠️ Terraform não encontrado."
    echo ">> Instalando Terraform 1.16.0..."
    echo ""

    cd /tmp || return 1

    rm -f terraform_1.16.0_linux_amd64.zip terraform

    curl -fsSL \
        -o terraform_1.16.0_linux_amd64.zip \
        https://releases.hashicorp.com/terraform/1.16.0/terraform_1.16.0_linux_amd64.zip

    if [ "$?" -ne 0 ]; then
        echo "❌ Erro ao baixar Terraform."
        return 1
    fi

    unzip -o terraform_1.16.0_linux_amd64.zip

    if [ "$?" -ne 0 ]; then
        echo "❌ Erro ao extrair Terraform."
        return 1
    fi

    sudo install terraform /usr/local/bin/terraform

    if [ "$?" -ne 0 ]; then
        echo "❌ Erro ao instalar Terraform."
        return 1
    fi

    rm -f terraform terraform_1.16.0_linux_amd64.zip

    echo ""
    echo "Terraform instalado:"
    terraform version | head -1
}


# ============================================================
# INSTALAR ANSIBLE SE NECESSÁRIO
# ============================================================

ensure_ansible() {

    if [ -x "$ANSIBLE_VENV/bin/ansible" ] && \
       [ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then
        return 0
    fi

    echo ""
    echo "⚠️ Ansible não encontrado."
    echo ">> Recriando ambiente virtual..."
    echo ""

    rm -rf "$ANSIBLE_VENV"

    python3 -m venv "$ANSIBLE_VENV"

    if [ "$?" -ne 0 ]; then
        echo "❌ Não foi possível criar o ambiente virtual."
        return 1
    fi

    "$ANSIBLE_VENV/bin/pip" install \
        --no-cache-dir \
        ansible

    if [ "$?" -ne 0 ]; then
        echo "❌ Não foi possível instalar o Ansible."
        return 1
    fi

    export PATH="$ANSIBLE_VENV/bin:$PATH"

    echo ""
    echo "Ansible instalado."
}


# ============================================================
# PREPARAR FERRAMENTAS
# ============================================================

prepare_tools() {

    prepare_tmp_environment

    ensure_terraform

    ensure_ansible

    prepare_tmp_environment

    prepare_terraform_projects
}


# ============================================================
# DESCOBRIR BUCKET
# ============================================================

get_bucket() {

    ACCOUNT_ID=$(aws sts get-caller-identity \
        --query Account \
        --output text 2>/dev/null)

    if [ -z "$ACCOUNT_ID" ] || \
       [ "$ACCOUNT_ID" = "None" ] || \
       [ "$ACCOUNT_ID" = "null" ]; then

        echo ""
        echo "❌ Não foi possível identificar a conta AWS."
        echo ""

        return 1
    fi

    BUCKET_NAME="tfstate-cloudshell-${ACCOUNT_ID}"

    return 0
}


# ============================================================
# LISTAR PROJETOS COM STATE NO S3
#
# Só considera prefixos que possuam:
#
#   <projeto>/terraform.tfstate
#
# Não transforma None/null em projeto.
# ============================================================

get_s3_projects() {

    S3_PROJECTS=()

    if [ -z "$BUCKET_NAME" ]; then
        return 0
    fi

    if ! aws s3api head-bucket \
        --bucket "$BUCKET_NAME" \
        >/dev/null 2>&1; then

        return 0
    fi

    S3_JSON=$(aws s3api list-objects-v2 \
        --bucket "$BUCKET_NAME" \
        --output json 2>/dev/null)

    if [ -z "$S3_JSON" ]; then
        return 0
    fi

    while IFS= read -r KEY; do

        [ -z "$KEY" ] && continue
        [ "$KEY" = "None" ] && continue
        [ "$KEY" = "null" ] && continue

        case "$KEY" in
            */terraform.tfstate)
                PROJECT="${KEY%/terraform.tfstate}"

                [ -z "$PROJECT" ] && continue
                [ "$PROJECT" = "None" ] && continue
                [ "$PROJECT" = "null" ] && continue

                S3_PROJECTS+=("$PROJECT")
                ;;
        esac

    done < <(
        echo "$S3_JSON" |
        jq -r '
            .Contents[]?.Key? // empty
        '
    )

    # Remove duplicados.
    if [ "${#S3_PROJECTS[@]}" -gt 0 ]; then

        mapfile -t S3_PROJECTS < <(
            printf '%s\n' "${S3_PROJECTS[@]}" |
            grep -v '^$' |
            sort -u
        )

    fi
}


# ============================================================
# LISTAR PROJETOS TERRAFORM LOCAIS
# ============================================================

get_local_projects() {

    LOCAL_PROJECTS=()

    if [ ! -d "$CONFIG_DIR" ]; then
        return 0
    fi

    for DIR in "$CONFIG_DIR"/*; do

        [ -d "$DIR" ] || continue

        if find "$DIR" \
            -maxdepth 1 \
            -type f \
            -name "*.tf" |
            grep -q .; then

            PROJECT=$(basename "$DIR")

            [ -z "$PROJECT" ] && continue
            [ "$PROJECT" = "None" ] && continue
            [ "$PROJECT" = "null" ] && continue

            LOCAL_PROJECTS+=("$PROJECT")
        fi

    done

    if [ "${#LOCAL_PROJECTS[@]}" -gt 0 ]; then

        mapfile -t LOCAL_PROJECTS < <(
            printf '%s\n' "${LOCAL_PROJECTS[@]}" |
            grep -v '^$' |
            sort -u
        )

    fi
}


# ============================================================
# TESTAR SE PROJETO POSSUI STATE
# ============================================================

project_has_state() {

    local PROJECT="$1"

    [ -z "$PROJECT" ] && return 1
    [ "$PROJECT" = "None" ] && return 1
    [ "$PROJECT" = "null" ] && return 1

    for P in "${S3_PROJECTS[@]}"; do

        if [ "$P" = "$PROJECT" ]; then
            return 0
        fi

    done

    return 1
}


# ============================================================
# TESTAR SE PROJETO LOCAL EXISTE
# ============================================================

project_exists_local() {

    local PROJECT="$1"

    [ -z "$PROJECT" ] && return 1
    [ "$PROJECT" = "None" ] && return 1
    [ "$PROJECT" = "null" ] && return 1

    if [ ! -d "$CONFIG_DIR/$PROJECT" ]; then
        return 1
    fi

    find "$CONFIG_DIR/$PROJECT" \
        -maxdepth 1 \
        -type f \
        -name "*.tf" |
        grep -q .
}


# ============================================================
# SELECIONAR PROJETO EXISTENTE NO S3
#
# Usado:
#   - inicialização quando existe state
#   - opção 8
#
# SOMENTE projetos do S3.
# ============================================================

select_s3_project() {

    get_s3_projects

    if [ "${#S3_PROJECTS[@]}" -eq 0 ]; then

        echo ""
        echo "⚠️ Nenhum projeto possui state no S3."
        echo ""

        return 1
    fi

    # --------------------------------------------------------
    # Um único projeto
    # --------------------------------------------------------

    if [ "${#S3_PROJECTS[@]}" -eq 1 ]; then

        PROJECT="${S3_PROJECTS[0]}"

        if ! project_exists_local "$PROJECT"; then

            echo ""
            echo "⚠️ O projeto '$PROJECT' existe no S3,"
            echo "mas não possui código Terraform local:"
            echo ""
            echo "   $CONFIG_DIR/$PROJECT"
            echo ""

            echo "O projeto não pode ser selecionado."
            echo ""

            return 1
        fi

        CURRENT_PROJECT="$PROJECT"

        echo ""
        echo "Projeto selecionado automaticamente:"
        echo "  $CURRENT_PROJECT"
        echo ""

        return 0
    fi

    # --------------------------------------------------------
    # Vários projetos
    # --------------------------------------------------------

    echo ""
    echo "========================================"
    echo " PROJETOS EXISTENTES NO S3"
    echo "========================================"
    echo ""

    VALID_PROJECTS=()

    for P in "${S3_PROJECTS[@]}"; do

        if project_exists_local "$P"; then

            VALID_PROJECTS+=("$P")

            echo "$(( ${#VALID_PROJECTS[@]} )) ) $P"

        else

            echo "     $P [SEM CÓDIGO LOCAL]"
        fi

    done

    if [ "${#VALID_PROJECTS[@]}" -eq 0 ]; then

        echo ""
        echo "❌ Nenhum projeto do S3 possui código Terraform local."
        echo ""
        echo "Verifique:"
        echo "   $CONFIG_DIR"
        echo ""

        return 1
    fi

    echo ""

    while true; do

        read -rp "Escolha o projeto: " NUMERO

        if [[ "$NUMERO" =~ ^[0-9]+$ ]]; then

            INDEX=$((NUMERO - 1))

            if [ "$INDEX" -ge 0 ] && \
               [ "$INDEX" -lt "${#VALID_PROJECTS[@]}" ]; then

                CURRENT_PROJECT="${VALID_PROJECTS[$INDEX]}"

                echo ""
                echo "Projeto selecionado: $CURRENT_PROJECT"
                echo ""

                return 0
            fi
        fi

        echo "❌ Opção inválida."
    done
}


# ============================================================
# SELECIONAR PROJETO PARA CRIAÇÃO
#
# Aqui podem aparecer:
#
#   projeto existente no S3
#   projeto novo local
#
# Portanto, é diferente da tela inicial.
# ============================================================

select_create_project() {

    get_s3_projects
    get_local_projects

    if [ "${#LOCAL_PROJECTS[@]}" -eq 0 ]; then

        echo ""
        echo "❌ Nenhum projeto Terraform local encontrado."
        echo ""
        echo "Verifique:"
        echo "   $CONFIG_DIR"
        echo ""

        return 1
    fi

    CREATE_PROJECTS=()

    for P in "${LOCAL_PROJECTS[@]}"; do
        CREATE_PROJECTS+=("$P")
    done

    # --------------------------------------------------------
    # Apenas um projeto local
    # --------------------------------------------------------

    if [ "${#CREATE_PROJECTS[@]}" -eq 1 ]; then

        CURRENT_PROJECT="${CREATE_PROJECTS[0]}"

        echo ""
        echo "Projeto encontrado:"
        echo "  $CURRENT_PROJECT"
        echo ""

        return 0
    fi

    # --------------------------------------------------------
    # Menu de criação
    # --------------------------------------------------------

    echo ""
    echo "========================================"
    echo " CRIAR INFRAESTRUTURA"
    echo "========================================"
    echo ""

    for i in "${!CREATE_PROJECTS[@]}"; do

        P="${CREATE_PROJECTS[$i]}"

        if project_has_state "$P"; then
            echo "$((i + 1))) $P [S3 STATE]"
        else
            echo "$((i + 1))) $P [NOVO]"
        fi

    done

    echo ""

    while true; do

        read -rp "Escolha o projeto: " NUMERO

        if [[ "$NUMERO" =~ ^[0-9]+$ ]]; then

            INDEX=$((NUMERO - 1))

            if [ "$INDEX" -ge 0 ] && \
               [ "$INDEX" -lt "${#CREATE_PROJECTS[@]}" ]; then

                CURRENT_PROJECT="${CREATE_PROJECTS[$INDEX]}"

                echo ""
                echo "Projeto selecionado: $CURRENT_PROJECT"
                echo ""

                return 0
            fi
        fi

        echo "❌ Opção inválida."
    done
}


# ============================================================
# STATUS RESUMIDO
# ============================================================

show_menu_status() {

    echo ""
    echo "========================================"
    echo " FIAP LAB"
    echo "========================================"

    if [ -n "$CURRENT_PROJECT" ]; then

        echo "Projeto atual : $CURRENT_PROJECT"
        echo "State         : S3"

    else

        echo "Projeto atual : nenhum"
        echo "State         : nenhum projeto selecionado"

    fi

    echo "========================================"
    echo ""
}


# ============================================================
# PAUSA
# ============================================================

pause_menu() {

    echo ""
    read -rp "Pressione ENTER para continuar..."
}


# ============================================================
# EXECUTAR OPERAÇÃO
# ============================================================

run_operation() {

    local SCRIPT="$1"

    if [ -z "$CURRENT_PROJECT" ]; then

        echo ""
        echo "❌ Nenhum projeto selecionado."
        echo ""

        return 1
    fi

    echo ""

    "$HOME/$SCRIPT" "$CURRENT_PROJECT"

    RC=$?

    echo ""

    if [ "$RC" -eq 0 ]; then

        echo "========================================"
        echo " Operação concluída."
        echo "========================================"

    else

        echo "========================================"
        echo " ⚠️ Operação terminou com erro."
        echo "========================================"

    fi

    return "$RC"
}


# ============================================================
# INICIALIZAÇÃO
# ============================================================

prepare_tools

if ! get_bucket; then

    pause_menu
    exit 1
fi

# ------------------------------------------------------------
# PRIMEIRO CARREGAMENTO
#
# Se houver state no S3:
#   seleciona somente entre eles.
#
# Se S3 estiver vazio:
#   não seleciona projeto.
#   opção 1 fará a seleção local.
# ------------------------------------------------------------

get_s3_projects

if [ "${#S3_PROJECTS[@]}" -gt 0 ]; then

    if ! select_s3_project; then

        echo ""
        echo "⚠️ Existem states no S3, mas nenhum projeto"
        echo "pode ser usado com o código local atual."
        echo ""

        pause_menu
        exit 1
    fi

else

    echo ""
    echo "========================================"
    echo " FIAP LAB"
    echo "========================================"
    echo ""
    echo "⚠️ Nenhum projeto possui infraestrutura"
    echo "registrada no S3."
    echo ""
    echo "Para criar uma nova infraestrutura,"
    echo "selecione a opção:"
    echo ""
    echo "  1) Criar infraestrutura"
    echo ""

    CURRENT_PROJECT=""
fi


# ============================================================
# MENU PRINCIPAL
# ============================================================

while true; do

    # --------------------------------------------------------
    # Recupera /tmp caso o CloudShell tenha limpado.
    # --------------------------------------------------------

    prepare_tools

    # --------------------------------------------------------
    # Atualiza lista do S3.
    # --------------------------------------------------------

    get_s3_projects

    show_menu_status

    echo "1) Criar infraestrutura"
    echo "2) Ligar VM(s)"
    echo "3) Suspender VM(s)"
    echo "4) Conectar via SSH"
    echo "5) Executar Ansible"
    echo "6) Mostrar IP"
    echo "7) Destruir infraestrutura"
    echo "8) Trocar projeto"
    echo "0) Sair"
    echo ""

    read -rp "Escolha uma opção: " OPCAO

    case "$OPCAO" in

        # ----------------------------------------------------
        # CRIAR
        # ----------------------------------------------------

        1)

            if select_create_project; then

                run_operation "criar.sh"

                # Depois do primeiro apply, o projeto deverá
                # aparecer no S3.
                get_s3_projects

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # LIGAR
        # ----------------------------------------------------

        2)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""
                echo "Use primeiro:"
                echo "  1) Criar infraestrutura"
                echo ""

            else

                run_operation "ligar.sh"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # SUSPENDER
        # ----------------------------------------------------

        3)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                run_operation "suspender.sh"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # SSH
        # ----------------------------------------------------

        4)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                echo ""
                read -rp "Número da VM: " NUMERO

                if ! [[ "$NUMERO" =~ ^[0-9]+$ ]] || \
                   [ "$NUMERO" -lt 1 ]; then

                    echo "❌ Número inválido."

                else

                    "$HOME/conectar.sh" \
                        "$CURRENT_PROJECT" \
                        "$NUMERO"

                fi

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # ANSIBLE
        # ----------------------------------------------------

        5)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                run_operation "ansible.sh"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # IP
        # ----------------------------------------------------

        6)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                run_operation "ip"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # DESTROY
        # ----------------------------------------------------

        7)

            if [ -z "$CURRENT_PROJECT" ]; then

                echo ""
                echo "❌ Nenhum projeto selecionado."
                echo ""

            else

                run_operation "destruir.sh"

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # TROCAR PROJETO
        #
        # SOMENTE S3.
        # ----------------------------------------------------

        8)

            if [ "${#S3_PROJECTS[@]}" -eq 0 ]; then

                echo ""
                echo "⚠️ Não existem projetos no S3."
                echo ""
                echo "Para criar o primeiro projeto:"
                echo "  1) Criar infraestrutura"
                echo ""

            else

                if select_s3_project; then
                    echo ""
                    echo "✅ Projeto alterado para:"
                    echo "   $CURRENT_PROJECT"
                fi

            fi

            pause_menu
            ;;


        # ----------------------------------------------------
        # SAIR
        # ----------------------------------------------------

        0)

            echo ""
            echo "Saindo..."
            exit 0
            ;;


        # ----------------------------------------------------
        # INVÁLIDO
        # ----------------------------------------------------

        *)

            echo ""
            echo "❌ Opção inválida."
            pause_menu
            ;;

    esac

done
EOF

chmod +x "$HOME_DIR/fiaplab.sh"


# ============================================================
# FINAL
# ============================================================

echo ""
echo "========================================" 
echo " SCRIPTS GERADOS" 
echo "========================================" 
echo ""
