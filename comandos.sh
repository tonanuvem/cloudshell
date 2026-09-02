#!/bin/bash

# ============================================================
# comandos.sh
# Cria os scripts auxiliares do FIAP Lab no HOME
# ============================================================

HOME_DIR="$HOME"
ENV_DIR="$HOME/environment"
TF_DIR="$ENV_DIR/config/ubuntu-vm"
SSH_KEY="$ENV_DIR/labsuser.pem"

TF_TMP_DIR="/tmp/fiap"
TF_PLUGIN_CACHE_DIR="$TF_TMP_DIR/tf_cache"
ANSIBLE_VENV="$TF_TMP_DIR/ansible_venv"

mkdir -p "$TF_TMP_DIR"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
mkdir -p "$TF_TMP_DIR/tf_projects"

# ============================================================
# criar.sh
# ============================================================

cat > "$HOME_DIR/criar.sh" <<'EOF'
#!/bin/bash

AWS_REGION="${AWS_REGION:-us-east-1}"

ENV_DIR="$HOME/environment"
TF_DIR="$ENV_DIR/config/ubuntu-vm"

TF_TMP_DIR="/tmp/fiap"
TF_PLUGIN_CACHE_DIR="$TF_TMP_DIR/tf_cache"

export TF_PLUGIN_CACHE_DIR

echo
echo "=============================================="
echo " FIAP LAB - CRIAR INFRAESTRUTURA"
echo "=============================================="
echo

if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ Terraform não encontrado."
    echo "Execute ~/fiaplab.sh novamente para instalar."
    exit 1
fi

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "$TF_DIR"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
    echo "❌ Não foi possível obter o Account ID da AWS."
    exit 1
fi

TFSTATE_BUCKET="tfstate-cloudshell-${ACCOUNT_ID}"
TFSTATE_TABLE="terraform-locks"
TFSTATE_KEY="ubuntu-vm/terraform.tfstate"

echo "AWS Account : $ACCOUNT_ID"
echo "AWS Region  : $AWS_REGION"
echo "S3 Bucket   : $TFSTATE_BUCKET"
echo "DynamoDB    : $TFSTATE_TABLE"
echo "State Key   : $TFSTATE_KEY"
echo

# ------------------------------------------------------------
# Backend
# ------------------------------------------------------------

if ! grep -Rqs 'backend[[:space:]]*"s3"' "$TF_DIR"/*.tf 2>/dev/null; then
    echo "Criando backend.tf..."

    cat > "$TF_DIR/backend.tf" <<'BACKEND'
terraform {
  backend "s3" {}
}
BACKEND
fi

# ------------------------------------------------------------
# Terraform Init
# ------------------------------------------------------------

echo
echo ">>> terraform init"
echo

terraform -chdir="$TF_DIR" init \
    -reconfigure \
    -backend-config="bucket=$TFSTATE_BUCKET" \
    -backend-config="key=$TFSTATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="dynamodb_table=$TFSTATE_TABLE"

if [ $? -ne 0 ]; then
    echo
    echo "❌ terraform init falhou."
    exit 1
fi

# ------------------------------------------------------------
# Validate
# ------------------------------------------------------------

echo
echo ">>> terraform validate"
echo

terraform -chdir="$TF_DIR" validate

if [ $? -ne 0 ]; then
    echo
    echo "❌ terraform validate falhou."
    exit 1
fi

# ------------------------------------------------------------
# Plan
# ------------------------------------------------------------

echo
echo ">>> terraform plan"
echo

terraform -chdir="$TF_DIR" plan

if [ $? -ne 0 ]; then
    echo
    echo "❌ terraform plan falhou."
    exit 1
fi

# ------------------------------------------------------------
# Apply
# ------------------------------------------------------------

echo
read -r -p "Deseja executar terraform apply? [s/N]: " CONFIRMA

if [[ "$CONFIRMA" =~ ^[Ss]$ ]]; then

    echo
    echo ">>> terraform apply"
    echo

    terraform -chdir="$TF_DIR" apply -auto-approve

    if [ $? -ne 0 ]; then
        echo
        echo "❌ terraform apply falhou."
        exit 1
    fi

    echo
    echo "✓ Infraestrutura criada/atualizada."

else

    echo
    echo "Operação cancelada."
fi

echo
echo "=============================================="
echo " STATUS"
echo "=============================================="

"$HOME/status.sh"
EOF


# ============================================================
# destruir.sh
# ============================================================

cat > "$HOME_DIR/destruir.sh" <<'EOF'
#!/bin/bash

AWS_REGION="${AWS_REGION:-us-east-1}"

ENV_DIR="$HOME/environment"
TF_DIR="$ENV_DIR/config/ubuntu-vm"

TF_TMP_DIR="/tmp/fiap"
TF_PLUGIN_CACHE_DIR="$TF_TMP_DIR/tf_cache"

export TF_PLUGIN_CACHE_DIR

echo
echo "=============================================="
echo " FIAP LAB - DESTRUIR INFRAESTRUTURA"
echo "=============================================="
echo

if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ Terraform não encontrado."
    exit 1
fi

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "$TF_DIR"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
    echo "❌ Não foi possível obter o Account ID da AWS."
    exit 1
fi

TFSTATE_BUCKET="tfstate-cloudshell-${ACCOUNT_ID}"
TFSTATE_TABLE="terraform-locks"
TFSTATE_KEY="ubuntu-vm/terraform.tfstate"

echo "AWS Account : $ACCOUNT_ID"
echo "AWS Region  : $AWS_REGION"
echo "S3 Bucket   : $TFSTATE_BUCKET"
echo "DynamoDB    : $TFSTATE_TABLE"
echo "State Key   : $TFSTATE_KEY"
echo

if ! grep -Rqs 'backend[[:space:]]*"s3"' "$TF_DIR"/*.tf 2>/dev/null; then

    cat > "$TF_DIR/backend.tf" <<'BACKEND'
terraform {
  backend "s3" {}
}
BACKEND

fi

echo
echo ">>> terraform init"
echo

terraform -chdir="$TF_DIR" init \
    -reconfigure \
    -backend-config="bucket=$TFSTATE_BUCKET" \
    -backend-config="key=$TFSTATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="dynamodb_table=$TFSTATE_TABLE"

if [ $? -ne 0 ]; then
    echo "❌ terraform init falhou."
    exit 1
fi

echo
echo "Recursos existentes no state:"
echo

terraform -chdir="$TF_DIR" state list

echo
read -r -p "ATENÇÃO: destruir toda a infraestrutura? [s/N]: " CONFIRMA

if [[ ! "$CONFIRMA" =~ ^[Ss]$ ]]; then
    echo
    echo "Operação cancelada."
    exit 0
fi

echo
echo ">>> terraform destroy"
echo

terraform -chdir="$TF_DIR" destroy -auto-approve

if [ $? -ne 0 ]; then
    echo
    echo "❌ terraform destroy falhou."
    exit 1
fi

echo
echo "✓ Infraestrutura destruída."
EOF


# ============================================================
# Função comum para descobrir instâncias Terraform
# ============================================================

cat > "$HOME_DIR/ligar.sh" <<'EOF'
#!/bin/bash

AWS_REGION="${AWS_REGION:-us-east-1}"

TF_DIR="$HOME/environment/config/ubuntu-vm"

export TF_PLUGIN_CACHE_DIR="/tmp/fiap/tf_cache"

echo
echo "=============================================="
echo " FIAP LAB - LIGAR VM(S)"
echo "=============================================="
echo

if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ Terraform não encontrado."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq não encontrado."
    exit 1
fi

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "$TF_DIR"
    exit 1
fi

mapfile -t INSTANCES < <(
    terraform -chdir="$TF_DIR" show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "❌ Nenhuma instância encontrada no Terraform state."
    exit 1
fi

for INSTANCE_ID in "${INSTANCES[@]}"; do

    STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)

    echo
    echo "Instância: $INSTANCE_ID"
    echo "Status   : $STATE"

    if [ "$STATE" = "stopped" ]; then

        echo "Ligando..."

        aws ec2 start-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION"

        if [ $? -ne 0 ]; then
            echo "❌ Falha ao ligar $INSTANCE_ID."
            continue
        fi

        echo "Aguardando instância ficar running..."

        aws ec2 wait instance-running \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION"

        if [ $? -eq 0 ]; then
            echo "✓ $INSTANCE_ID está running."
        else
            echo "❌ Timeout aguardando $INSTANCE_ID."
        fi

    elif [ "$STATE" = "running" ]; then

        echo "✓ Já está ligada."

    else

        echo "⚠ Estado atual: $STATE"

    fi

done

echo
echo "Operação concluída."
EOF


# ============================================================
# suspender.sh
# ============================================================

cat > "$HOME_DIR/suspender.sh" <<'EOF'
#!/bin/bash

AWS_REGION="${AWS_REGION:-us-east-1}"

TF_DIR="$HOME/environment/config/ubuntu-vm"

export TF_PLUGIN_CACHE_DIR="/tmp/fiap/tf_cache"

echo
echo "=============================================="
echo " FIAP LAB - SUSPENDER VM(S)"
echo "=============================================="
echo

if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ Terraform não encontrado."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq não encontrado."
    exit 1
fi

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "$TF_DIR"
    exit 1
fi

mapfile -t INSTANCES < <(
    terraform -chdir="$TF_DIR" show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "❌ Nenhuma instância encontrada no Terraform state."
    exit 1
fi

for INSTANCE_ID in "${INSTANCES[@]}"; do

    STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)

    echo
    echo "Instância: $INSTANCE_ID"
    echo "Status   : $STATE"

    if [ "$STATE" = "running" ]; then

        echo "Suspendo..."

        aws ec2 stop-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION"

        if [ $? -eq 0 ]; then
            echo "✓ Comando de suspensão enviado."
        else
            echo "❌ Falha ao suspender $INSTANCE_ID."
        fi

    elif [ "$STATE" = "stopped" ]; then

        echo "✓ Já está desligada."

    else

        echo "⚠ Estado atual: $STATE"

    fi

done

echo
echo "Operação concluída."
EOF


# ============================================================
# status.sh
# ============================================================

cat > "$HOME_DIR/status.sh" <<'EOF'
#!/bin/bash

AWS_REGION="${AWS_REGION:-us-east-1}"

TF_DIR="$HOME/environment/config/ubuntu-vm"

export TF_PLUGIN_CACHE_DIR="/tmp/fiap/tf_cache"

echo
echo "=============================================="
echo " FIAP LAB - STATUS DAS VMs"
echo "=============================================="
echo

if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ Terraform não encontrado."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq não encontrado."
    exit 1
fi

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "$TF_DIR"
    exit 1
fi

mapfile -t INSTANCES < <(
    terraform -chdir="$TF_DIR" show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "Nenhuma instância encontrada no Terraform state."
    exit 0
fi

printf "%-18s %-12s %-12s %-18s %-18s\n" \
    "INSTANCE ID" "STATUS" "TIPO" "IP PÚBLICO" "IP PRIVADO"

printf "%-18s %-12s %-12s %-18s %-18s\n" \
    "------------------" \
    "------------" \
    "------------" \
    "------------------" \
    "------------------"

for INSTANCE_ID in "${INSTANCES[@]}"; do

    DATA=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].[State.Name,InstanceType,PublicIpAddress,PrivateIpAddress]' \
        --output text)

    STATE=$(echo "$DATA" | awk '{print $1}')
    TYPE=$(echo "$DATA" | awk '{print $2}')
    PUBLIC_IP=$(echo "$DATA" | awk '{print $3}')
    PRIVATE_IP=$(echo "$DATA" | awk '{print $4}')

    [ "$PUBLIC_IP" = "None" ] && PUBLIC_IP="-"
    [ "$PRIVATE_IP" = "None" ] && PRIVATE_IP="-"

    printf "%-18s %-12s %-12s %-18s %-18s\n" \
        "$INSTANCE_ID" \
        "$STATE" \
        "$TYPE" \
        "$PUBLIC_IP" \
        "$PRIVATE_IP"

done

echo

echo "URLs HTTP das instâncias running:"
echo

for INSTANCE_ID in "${INSTANCES[@]}"; do

    DATA=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' \
        --output text)

    STATE=$(echo "$DATA" | awk '{print $1}')
    PUBLIC_IP=$(echo "$DATA" | awk '{print $2}')

    if [ "$STATE" = "running" ] && [ "$PUBLIC_IP" != "None" ]; then
        echo "http://$PUBLIC_IP"
    fi

done

echo
EOF


# ============================================================
# ip
# ============================================================

cat > "$HOME_DIR/ip" <<'EOF'
#!/bin/bash

AWS_REGION="${AWS_REGION:-us-east-1}"

TF_DIR="$HOME/environment/config/ubuntu-vm"

export TF_PLUGIN_CACHE_DIR="/tmp/fiap/tf_cache"

if ! command -v terraform >/dev/null 2>&1; then
    echo "Terraform não encontrado."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq não encontrado."
    exit 1
fi

mapfile -t INSTANCES < <(
    terraform -chdir="$TF_DIR" show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "Nenhuma VM encontrada."
    exit 1
fi

for INSTANCE_ID in "${INSTANCES[@]}"; do

    DATA=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' \
        --output text)

    STATE=$(echo "$DATA" | awk '{print $1}')
    PUBLIC_IP=$(echo "$DATA" | awk '{print $2}')

    if [ "$STATE" = "running" ] && [ "$PUBLIC_IP" != "None" ]; then
        echo "$PUBLIC_IP"
        exit 0
    fi

done

echo "Desligada"
EOF


# ============================================================
# conectar.sh
# ============================================================

cat > "$HOME_DIR/conectar.sh" <<'EOF'
#!/bin/bash

AWS_REGION="${AWS_REGION:-us-east-1}"

TF_DIR="$HOME/environment/config/ubuntu-vm"
SSH_KEY="$HOME/environment/labsuser.pem"

NUMERO="${1:-1}"

export TF_PLUGIN_CACHE_DIR="/tmp/fiap/tf_cache"

echo
echo "=============================================="
echo " FIAP LAB - CONECTAR VIA SSH"
echo "=============================================="
echo

if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ Terraform não encontrado."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq não encontrado."
    exit 1
fi

mapfile -t INSTANCES < <(
    terraform -chdir="$TF_DIR" show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "❌ Nenhuma VM encontrada."
    exit 1
fi

INDEX=$((NUMERO - 1))

if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#INSTANCES[@]}" ]; then
    echo "❌ VM número $NUMERO não existe."
    echo "Quantidade disponível: ${#INSTANCES[@]}"
    exit 1
fi

INSTANCE_ID="${INSTANCES[$INDEX]}"

DATA=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' \
    --output text)

STATE=$(echo "$DATA" | awk '{print $1}')
PUBLIC_IP=$(echo "$DATA" | awk '{print $2}')

echo "VM          : $NUMERO"
echo "Instance ID : $INSTANCE_ID"
echo "Status      : $STATE"
echo "IP público  : $PUBLIC_IP"
echo

if [ "$STATE" != "running" ]; then
    echo "❌ A VM não está ligada."
    exit 1
fi

if [ "$PUBLIC_IP" = "None" ] || [ -z "$PUBLIC_IP" ]; then
    echo "❌ A VM não possui IP público."
    exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
    echo "❌ Chave SSH não encontrada:"
    echo "$SSH_KEY"
    exit 1
fi

chmod 400 "$SSH_KEY"

echo "Conectando..."
echo

ssh \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    ubuntu@"$PUBLIC_IP"
EOF


# ============================================================
# ansible.sh
# ============================================================

cat > "$HOME_DIR/ansible.sh" <<'EOF'
#!/bin/bash

AWS_REGION="${AWS_REGION:-us-east-1}"

ENV_DIR="$HOME/environment"
TF_DIR="$ENV_DIR/config/ubuntu-vm"
SSH_KEY="$ENV_DIR/labsuser.pem"

ANSIBLE_VENV="/tmp/fiap/ansible_venv"

export PATH="$ANSIBLE_VENV/bin:$PATH"

export ANSIBLE_PYTHON_INTERPRETER=auto_silent
export ANSIBLE_DEPRECATION_WARNINGS=false
export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false

echo
echo "=============================================="
echo " FIAP LAB - EXECUTAR ANSIBLE"
echo "=============================================="
echo

ANSIBLE_PLAYBOOK=$(command -v ansible-playbook)

if [ -z "$ANSIBLE_PLAYBOOK" ] && [ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then
    ANSIBLE_PLAYBOOK="$ANSIBLE_VENV/bin/ansible-playbook"
fi

ANSIBLE=$(command -v ansible)

if [ -z "$ANSIBLE" ] && [ -x "$ANSIBLE_VENV/bin/ansible" ]; then
    ANSIBLE="$ANSIBLE_VENV/bin/ansible"
fi

if [ -z "$ANSIBLE_PLAYBOOK" ]; then
    echo "❌ ansible-playbook não encontrado."
    exit 1
fi

if [ -z "$ANSIBLE" ]; then
    echo "❌ ansible não encontrado."
    exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
    echo "❌ Terraform não encontrado."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq não encontrado."
    exit 1
fi

echo "Ansible:"
"$ANSIBLE" --version | head -n 1

echo

mapfile -t INSTANCES < <(
    terraform -chdir="$TF_DIR" show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "❌ Nenhuma VM encontrada no Terraform state."
    exit 1
fi

INSTANCE_ID="${INSTANCES[0]}"

DATA=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' \
    --output text)

STATE=$(echo "$DATA" | awk '{print $1}')
PUBLIC_IP=$(echo "$DATA" | awk '{print $2}')

echo "Instance ID : $INSTANCE_ID"
echo "Status      : $STATE"
echo "IP público  : $PUBLIC_IP"
echo

if [ "$STATE" != "running" ]; then
    echo "❌ A primeira VM não está running."
    echo "Execute ~/ligar.sh antes do Ansible."
    exit 1
fi

if [ "$PUBLIC_IP" = "None" ] || [ -z "$PUBLIC_IP" ]; then
    echo "❌ A VM não possui IP público."
    exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
    echo "❌ Chave SSH não encontrada:"
    echo "$SSH_KEY"
    exit 1
fi

chmod 400 "$SSH_KEY"

# ------------------------------------------------------------
# Inventory temporário
# ------------------------------------------------------------

INVENTORY=$(mktemp)

cat > "$INVENTORY" <<EOF2
[nodes]
ubuntu ansible_host=$PUBLIC_IP ansible_user=ubuntu ansible_ssh_private_key_file=$SSH_KEY ansible_python_interpreter=auto_silent
EOF2

echo "Inventory:"
cat "$INVENTORY"

echo
echo "Testando conectividade Ansible..."
echo

"$ANSIBLE" \
    -i "$INVENTORY" \
    nodes \
    -m ping

if [ $? -ne 0 ]; then
    echo
    echo "❌ Falha no teste Ansible."
    rm -f "$INVENTORY"
    exit 1
fi

# ------------------------------------------------------------
# Encontrar playbooks
# ------------------------------------------------------------

mapfile -t PLAYBOOKS < <(
    find "$TF_DIR" \
        -type f \
        \( -name "*.yml" -o -name "*.yaml" \) \
        -not -path "*/.terraform/*" \
        | sort
)

if [ "${#PLAYBOOKS[@]}" -eq 0 ]; then
    echo
    echo "❌ Nenhum playbook .yml ou .yaml encontrado."
    rm -f "$INVENTORY"
    exit 1
fi

PLAYBOOK=""

if [ "${#PLAYBOOKS[@]}" -eq 1 ]; then

    PLAYBOOK="${PLAYBOOKS[0]}"

else

    echo
    echo "Playbooks encontrados:"
    echo

    for i in "${!PLAYBOOKS[@]}"; do
        echo "$((i + 1))) ${PLAYBOOKS[$i]}"
    done

    echo

    read -r -p "Escolha o playbook [1]: " OPCAO
    OPCAO="${OPCAO:-1}"

    INDEX=$((OPCAO - 1))

    if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#PLAYBOOKS[@]}" ]; then
        echo "❌ Opção inválida."
        rm -f "$INVENTORY"
        exit 1
    fi

    PLAYBOOK="${PLAYBOOKS[$INDEX]}"

fi

echo
echo "Playbook selecionado:"
echo "$PLAYBOOK"
echo

read -r -p "Executar este playbook? [s/N]: " CONFIRMA

if [[ ! "$CONFIRMA" =~ ^[Ss]$ ]]; then
    echo
    echo "Operação cancelada."
    rm -f "$INVENTORY"
    exit 0
fi

echo
echo ">>> Executando Ansible"
echo

"$ANSIBLE_PLAYBOOK" \
    -i "$INVENTORY" \
    "$PLAYBOOK"

RESULT=$?

rm -f "$INVENTORY"

echo

if [ "$RESULT" -eq 0 ]; then
    echo "✓ Ansible executado com sucesso."
else
    echo "❌ Ansible terminou com erro."
fi

exit "$RESULT"
EOF


# ============================================================
# fiaplab.sh
# Menu principal
# ============================================================

cat > "$HOME_DIR/fiaplab.sh" <<'EOF'
#!/bin/bash

# ============================================================
# FIAP LAB - MENU PRINCIPAL
# ============================================================

AWS_REGION="${AWS_REGION:-us-east-1}"

ENV_DIR="$HOME/environment"
TF_DIR="$ENV_DIR/config/ubuntu-vm"

TF_TMP_DIR="/tmp/fiap"
TF_PLUGIN_CACHE_DIR="$TF_TMP_DIR/tf_cache"
ANSIBLE_VENV="$TF_TMP_DIR/ansible_venv"

export TF_PLUGIN_CACHE_DIR
export PATH="$ANSIBLE_VENV/bin:$PATH"

export ANSIBLE_PYTHON_INTERPRETER=auto_silent
export ANSIBLE_DEPRECATION_WARNINGS=false
export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false

trap 'echo; echo "Saindo..."; exit 0' INT


# ============================================================
# Instalar Terraform
# ============================================================

install_terraform() {

    echo
    echo "=============================================="
    echo " Terraform não encontrado"
    echo "=============================================="
    echo

    echo "Instalando Terraform 1.16.0..."

    TMP_DIR=$(mktemp -d)

    cd "$TMP_DIR"

    echo
    echo "Baixando Terraform..."
    echo

    if ! curl -fsSL \
        "https://releases.hashicorp.com/terraform/1.16.0/terraform_1.16.0_linux_amd64.zip" \
        -o terraform.zip
    then
        echo
        echo "❌ Falha ao baixar Terraform."
        cd "$HOME"
        rm -rf "$TMP_DIR"
        return 1
    fi

    echo
    echo "Extraindo Terraform..."
    echo

    if ! unzip -q terraform.zip; then
        echo
        echo "❌ Falha ao extrair Terraform."
        cd "$HOME"
        rm -rf "$TMP_DIR"
        return 1
    fi

    echo
    echo "Instalando em /usr/local/bin..."
    echo

    if ! sudo install -m 0755 terraform /usr/local/bin/terraform; then
        echo
        echo "❌ Falha ao instalar Terraform."
        cd "$HOME"
        rm -rf "$TMP_DIR"
        return 1
    fi

    cd "$HOME"
    rm -rf "$TMP_DIR"

    echo
    echo "✓ Terraform instalado."
    terraform --version

    return 0
}


# ============================================================
# Instalar Ansible
# ============================================================

install_ansible() {

    echo
    echo "=============================================="
    echo " Ansible não encontrado"
    echo "=============================================="
    echo

    echo "Criando virtual environment:"
    echo "$ANSIBLE_VENV"
    echo

    mkdir -p "$TF_TMP_DIR"

    if [ ! -d "$ANSIBLE_VENV" ]; then

        echo "Criando ambiente Python..."

        if ! python3 -m venv "$ANSIBLE_VENV"; then
            echo
            echo "❌ Falha ao criar virtual environment."
            return 1
        fi

    fi

    echo
    echo "Instalando Ansible..."
    echo

    if ! "$ANSIBLE_VENV/bin/pip" install --no-cache-dir ansible; then
        echo
        echo "❌ Falha ao instalar Ansible."
        return 1
    fi

    echo
    echo "✓ Ansible instalado."
    "$ANSIBLE_VENV/bin/ansible" --version

    return 0
}


# ============================================================
# Verificar ferramentas
# ============================================================

ensure_tools() {

    mkdir -p "$TF_PLUGIN_CACHE_DIR"
    mkdir -p "$TF_TMP_DIR/tf_projects"

    if [ ! -f "$HOME/.terraformrc" ]; then

        cat > "$HOME/.terraformrc" <<EOF2
plugin_cache_dir = "$TF_PLUGIN_CACHE_DIR"
disable_checkpoint = true
EOF2

    fi

    if ! command -v terraform >/dev/null 2>&1; then
        install_terraform
    else
        echo
        echo "✓ Terraform encontrado."
        terraform --version | head -n 1
    fi

    if ! command -v ansible-playbook >/dev/null 2>&1; then
        install_ansible
    else
        echo
        echo "✓ Ansible encontrado."
        ansible-playbook --version | head -n 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo
        echo "⚠ jq não encontrado."
        echo "Os scripts de gerenciamento das VMs dependem dele."
    fi
}


# ============================================================
# Descobrir instâncias Terraform
# ============================================================

get_instances() {

    if ! command -v terraform >/dev/null 2>&1; then
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        return 1
    fi

    if [ ! -d "$TF_DIR" ]; then
        return 1
    fi

    terraform -chdir="$TF_DIR" show -json |
        jq -r '
            .values.root_module.resources[]?
            | select(.type=="aws_instance" and .name=="web")
            | .values.id
        '
}


# ============================================================
# Mostrar contexto AWS
# ============================================================

show_context() {

    echo
    echo "============================================================"
    echo " FIAP LAB"
    echo "============================================================"
    echo

    ACCOUNT_ID=$(aws sts get-caller-identity \
        --query Account \
        --output text)

    AWS_USER=$(aws sts get-caller-identity \
        --query Arn \
        --output text)

    if [ $? -eq 0 ] && [ -n "$ACCOUNT_ID" ]; then

        echo "AWS Account : $ACCOUNT_ID"
        echo "AWS Region  : $AWS_REGION"
        echo "AWS Identity: $AWS_USER"

        TFSTATE_BUCKET="tfstate-cloudshell-${ACCOUNT_ID}"

    else

        echo "AWS Account : ❌ não disponível"
        echo "AWS Region  : $AWS_REGION"

        TFSTATE_BUCKET="não disponível"

    fi

    echo

    echo "------------------ FERRAMENTAS ------------------"

    if command -v terraform >/dev/null 2>&1; then
        echo "Terraform   : $(terraform --version | head -n 1)"
    else
        echo "Terraform   : ❌ não instalado"
    fi

    if command -v ansible-playbook >/dev/null 2>&1; then
        echo "Ansible     : $(ansible-playbook --version | head -n 1)"
    elif [ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then
        echo "Ansible     : $("$ANSIBLE_VENV/bin/ansible-playbook" --version | head -n 1)"
    else
        echo "Ansible     : ❌ não instalado"
    fi

    if command -v aws >/dev/null 2>&1; then
        echo "AWS CLI     : $(aws --version 2>&1)"
    else
        echo "AWS CLI     : ❌ não encontrado"
    fi

    if command -v jq >/dev/null 2>&1; then
        echo "jq          : $(jq --version)"
    else
        echo "jq          : ❌ não encontrado"
    fi

    echo

    echo "------------------ TERRAFORM ------------------"

    echo "Diretório   : $TF_DIR"

    if [ -f "$TF_DIR/backend.tf" ]; then
        echo "Backend     : S3"
    elif [ -d "$TF_DIR" ]; then
        echo "Backend     : não configurado"
    else
        echo "Backend     : ❌ diretório não encontrado"
    fi

    echo "S3 State    : $TFSTATE_BUCKET"
    echo "State Key   : ubuntu-vm/terraform.tfstate"
    echo "DynamoDB    : terraform-locks"

    echo

    echo "------------------ ANSIBLE ------------------"

    if [ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then
        echo "Path        : $ANSIBLE_VENV/bin/ansible-playbook"
        echo "Status      : ✓ disponível"
    elif command -v ansible-playbook >/dev/null 2>&1; then
        echo "Path        : $(command -v ansible-playbook)"
        echo "Status      : ✓ disponível"
    else
        echo "Status      : ❌ indisponível"
    fi

    echo

    echo "------------------ EC2 ------------------"

    if ! command -v terraform >/dev/null 2>&1; then

        echo "Terraform não disponível para consultar as VMs."

    elif ! command -v jq >/dev/null 2>&1; then

        echo "jq não disponível para consultar as VMs."

    elif [ ! -d "$TF_DIR" ]; then

        echo "Diretório Terraform não encontrado."

    else

        mapfile -t INSTANCES < <(get_instances)

        if [ "${#INSTANCES[@]}" -eq 0 ]; then

            echo "Nenhuma instância encontrada no Terraform state."

        else

            printf "%-5s %-20s %-12s %-12s %-18s %-18s\n" \
                "#" \
                "INSTANCE ID" \
                "STATUS" \
                "TIPO" \
                "IP PÚBLICO" \
                "IP PRIVADO"

            printf "%-5s %-20s %-12s %-12s %-18s %-18s\n" \
                "---" \
                "--------------------" \
                "------------" \
                "------------" \
                "------------------" \
                "------------------"

            NUM=1

            for INSTANCE_ID in "${INSTANCES[@]}"; do

                DATA=$(aws ec2 describe-instances \
                    --instance-ids "$INSTANCE_ID" \
                    --region "$AWS_REGION" \
                    --query 'Reservations[0].Instances[0].[State.Name,InstanceType,PublicIpAddress,PrivateIpAddress]' \
                    --output text)

                if [ $? -ne 0 ]; then

                    printf "%-5s %-20s %-12s\n" \
                        "$NUM" \
                        "$INSTANCE_ID" \
                        "erro"

                else

                    STATE=$(echo "$DATA" | awk '{print $1}')
                    TYPE=$(echo "$DATA" | awk '{print $2}')
                    PUBLIC_IP=$(echo "$DATA" | awk '{print $3}')
                    PRIVATE_IP=$(echo "$DATA" | awk '{print $4}')

                    [ "$PUBLIC_IP" = "None" ] && PUBLIC_IP="-"
                    [ "$PRIVATE_IP" = "None" ] && PRIVATE_IP="-"

                    printf "%-5s %-20s %-12s %-12s %-18s %-18s\n" \
                        "$NUM" \
                        "$INSTANCE_ID" \
                        "$STATE" \
                        "$TYPE" \
                        "$PUBLIC_IP" \
                        "$PRIVATE_IP"

                fi

                NUM=$((NUM + 1))

            done

        fi

    fi

    echo
}


# ============================================================
# Menu
# ============================================================

show_menu() {

    echo "============================================================"
    echo " MENU"
    echo "============================================================"
    echo
    echo "  1) Criar infraestrutura"
    echo "  2) Ligar VM(s)"
    echo "  3) Suspender VM(s)"
    echo "  4) Conectar via SSH"
    echo "  5) Executar Ansible"
    echo "  6) Mostrar IP"
    echo "  7) Destruir infraestrutura"
    echo "  0) Sair"
    echo
}


# ============================================================
# Executar ação
# ============================================================

run_action() {

    case "$1" in

        1)
            "$HOME/criar.sh"
            ;;

        2)
            "$HOME/ligar.sh"
            ;;

        3)
            "$HOME/suspender.sh"
            ;;

        4)

            echo
            read -r -p "Número da VM [1]: " NUMERO
            NUMERO="${NUMERO:-1}"

            "$HOME/conectar.sh" "$NUMERO"
            ;;

        5)
            "$HOME/ansible.sh"
            ;;

        6)
            echo
            echo "IP público:"
            "$HOME/ip"
            ;;

        7)
            "$HOME/destruir.sh"
            ;;

        0)
            echo
            echo "Saindo..."
            exit 0
            ;;

        *)
            echo
            echo "❌ Opção inválida."
            ;;

    esac
}


# ============================================================
# Inicialização
# ============================================================

echo
echo "============================================================"
echo " Inicializando FIAP Lab"
echo "============================================================"

echo
echo "Verificando ferramentas..."
ensure_tools

echo
echo "Inicialização concluída."

# ============================================================
# Loop principal
# ============================================================

while true; do

    show_context
    show_menu

    read -r -p "Escolha uma opção: " OPCAO

    echo

    run_action "$OPCAO"

    echo
    echo "============================================================"
    echo " Operação finalizada"
    echo "============================================================"
    echo

    read -r -p "Pressione ENTER para atualizar o status e voltar ao menu..."

done
EOF


# ============================================================
# Permissões
# ============================================================

chmod +x "$HOME_DIR/criar.sh"
chmod +x "$HOME_DIR/destruir.sh"
chmod +x "$HOME_DIR/ligar.sh"
chmod +x "$HOME_DIR/suspender.sh"
chmod +x "$HOME_DIR/status.sh"
chmod +x "$HOME_DIR/ip"
chmod +x "$HOME_DIR/conectar.sh"
chmod +x "$HOME_DIR/ansible.sh"
chmod +x "$HOME_DIR/fiaplab.sh"


# ============================================================
# Final
# ============================================================

echo
echo "\tScripts criados com sucesso"
echo
echo "\tPara iniciar o laboratório:"
echo
echo "  ~/fiaplab.sh"
echo
