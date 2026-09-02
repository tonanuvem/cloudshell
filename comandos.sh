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
# NÃO copia comandos.sh para ~/.fiaplab
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

# Cria backend.tf apenas se o projeto ainda não possuir
# configuração de backend S3.
if ! grep -Rqs 'backend[[:space:]]*"s3"' "$TF_DIR"/*.tf 2>/dev/null; then

    echo ">> Configurando backend S3..."

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

echo ""
echo ">> Terraform apply..."

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

echo ""
echo ">> Terraform destroy..."

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

AWS_REGION="${AWS_REGION:-us-east-1}"

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

if [ -z "$INSTANCE_COUNT" ]; then
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

terraform -chdir="$TF_DIR" refresh

echo ""
echo "IPs externos:"
echo ""

terraform -chdir="$TF_DIR" output -json 2>/dev/null |
    jq -r '
        if .ip_externo.value? then
            .ip_externo.value |
            if type == "string" then
                .
            else
                .. | strings
            end
        else
            empty
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

STATE_JSON=$(terraform -chdir="$TF_DIR" show -json)

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

    aws ec2 start-instances \
        --instance-ids "${IDS[@]}" \
        --region "$AWS_REGION"

else

    INDEX=$((NUMERO - 1))

    if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#IDS[@]}" ]; then
        echo "❌ Número inválido."
        exit 1
    fi

    echo ""
    echo ">> Ligando ${IDS[$INDEX]}..."

    aws ec2 start-instances \
        --instance-ids "${IDS[$INDEX]}" \
        --region "$AWS_REGION"
fi

echo ""
echo "✅ Comando enviado."
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

STATE_JSON=$(terraform -chdir="$TF_DIR" show -json)

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

    aws ec2 stop-instances \
        --instance-ids "${IDS[@]}" \
        --region "$AWS_REGION"

else

    INDEX=$((NUMERO - 1))

    if [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge "${#IDS[@]}" ]; then
        echo "❌ Número inválido."
        exit 1
    fi

    echo ""
    echo ">> Suspendendo ${IDS[$INDEX]}..."

    aws ec2 stop-instances \
        --instance-ids "${IDS[$INDEX]}" \
        --region "$AWS_REGION"
fi

echo ""
echo "✅ Comando enviado."
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

terraform -chdir="$TF_DIR" refresh

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

    echo "IPs encontrados:"
    printf '%s\n' "${IPS[@]}"

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

scp \
    -q \
    -o LogLevel=error \
    -o StrictHostKeyChecking=no \
    -i "$KEY" \
    "$CREDENTIALS" \
    ubuntu@"$IP":/home/ubuntu/.aws/credentials

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
    echo "Execute ~/fiaplab.sh para reconstruir o ambiente."
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
# O S3 é a fonte persistente dos projetos com Terraform state.
#
# $HOME/environment/config
#       ↓
# código Terraform local
#
# S3
#       ↓
# projetos que possuem state
#
# O menu cruza as duas informações.
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
        return
    fi

    find "$CONFIG_DIR" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -print0 |
    while IFS= read -r -d '' SUBDIR; do

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

    unzip -o terraform_1.16.0_linux_amd64.zip

    sudo install terraform /usr/local/bin/terraform

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

    "$ANSIBLE_VENV/bin/pip" install \
        --no-cache-dir \
        ansible

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

    if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
        echo ""
        echo "❌ Não foi possível identificar a conta AWS."
        return 1
    fi

    BUCKET_NAME="tfstate-cloudshell-${ACCOUNT_ID}"

    return 0
}

# ============================================================
# LISTAR PROJETOS COM STATE NO S3
# ============================================================

get_s3_projects() {

    S3_PROJECTS=()

    if ! aws s3api head-bucket \
        --bucket "$BUCKET_NAME" \
        >/dev/null 2>&1; then

        return 0
    fi

    while IFS= read -r PROJECT; do

        [ -z "$PROJECT" ] && continue

        S3_PROJECTS+=("$PROJECT")

    done < <(
        aws s3api list-objects-v2 \
            --bucket "$BUCKET_NAME" \
            --delimiter "/" \
            --query 'CommonPrefixes[].Prefix' \
            --output text 2>/dev/null |
        tr '\t' '\n' |
        sed 's:/$::' |
        sort
    )
}

# ============================================================
# LISTAR PROJETOS TERRAFORM LOCAIS
# ============================================================

get_local_projects() {

    LOCAL_PROJECTS=()

    if [ ! -d "$CONFIG_DIR" ]; then
        return
    fi

    while IFS= read -r -d '' DIR; do

        if find "$DIR" \
            -maxdepth 1 \
            -type f \
            -name "*.tf" |
            grep -q .; then

            LOCAL_PROJECTS+=("$(basename "$DIR")")
        fi

    done < <(
        find "$CONFIG_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -print0 |
        sort -z
    )
}

# ============================================================
# TESTAR SE PROJETO POSSUI STATE
# ============================================================

project_has_state() {

    local PROJECT="$1"

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

    [ -d "$CONFIG_DIR/$PROJECT" ] &&
    find "$CONFIG_DIR/$PROJECT" \
        -maxdepth 1 \
        -type f \
        -name "*.tf" |
        grep -q .
}

# ============================================================
# SELECIONAR PROJETO
# ============================================================

select_project() {

    get_s3_projects
    get_local_projects

    PROJECTS=()

    # Primeiro entram os projetos do S3.
    for P in "${S3_PROJECTS[@]}"; do
        PROJECTS+=("$P")
    done

    # Depois entram projetos locais que ainda não têm state.
    for P in "${LOCAL_PROJECTS[@]}"; do

        FOUND=0

        for S3P in "${S3_PROJECTS[@]}"; do
            if [ "$P" = "$S3P" ]; then
                FOUND=1
                break
            fi
        done

        if [ "$FOUND" -eq 0 ]; then
            PROJECTS+=("$P")
        fi
    done

    if [ "${#PROJECTS[@]}" -eq 0 ]; then

        echo ""
        echo "❌ Nenhum projeto Terraform encontrado."
        echo ""
        echo "Verifique:"
        echo "   $CONFIG_DIR"
        echo ""

        return 1
    fi

    # Apenas um projeto.
    if [ "${#PROJECTS[@]}" -eq 1 ]; then

        CURRENT_PROJECT="${PROJECTS[0]}"

        echo ""
        echo "Projeto selecionado automaticamente:"
        echo "  $CURRENT_PROJECT"
        echo ""

        return 0
    fi

    echo ""
    echo "========================================"
    echo " PROJETOS"
    echo "========================================"
    echo ""

    for i in "${!PROJECTS[@]}"; do

        P="${PROJECTS[$i]}"

        if project_has_state "$P"; then
            STATUS="S3 STATE"
        else
            STATUS="NOVO"
        fi

        if project_exists_local "$P"; then
            LOCAL="LOCAL"
        else
            LOCAL="SEM CÓDIGO"
        fi

        if project_has_state "$P" && ! project_exists_local "$P"; then
            echo "$((i + 1))) $P [$STATUS / $LOCAL]"
        else
            echo "$((i + 1))) $P [$STATUS]"
        fi
    done

    echo ""

    while true; do

        read -rp "Escolha o projeto: " NUMERO

        if [[ "$NUMERO" =~ ^[0-9]+$ ]]; then

            INDEX=$((NUMERO - 1))

            if [ "$INDEX" -ge 0 ] && \
               [ "$INDEX" -lt "${#PROJECTS[@]}" ]; then

                SELECTED="${PROJECTS[$INDEX]}"

                # Não permite executar Terraform sem código local.
                if ! project_exists_local "$SELECTED"; then

                    echo ""
                    echo "⚠️ O projeto '$SELECTED' possui state no S3,"
                    echo "mas não possui código Terraform local:"
                    echo ""
                    echo "   $CONFIG_DIR/$SELECTED"
                    echo ""
                    echo "Esse projeto não pode ser executado."
                    echo ""

                    continue
                fi

                CURRENT_PROJECT="$SELECTED"

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
# STATUS RESUMIDO DO MENU
# ============================================================

show_menu_status() {

    echo ""
    echo "========================================"
    echo " FIAP LAB"
    echo "========================================"

    if [ -n "$CURRENT_PROJECT" ]; then

        if project_has_state "$CURRENT_PROJECT"; then
            STATE_STATUS="S3 STATE"
        else
            STATE_STATUS="NOVO"
        fi

        echo "Projeto atual : $CURRENT_PROJECT"
        echo "State         : $STATE_STATUS"

    else

        echo "Projeto atual : nenhum"
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

select_project || {
    pause_menu
    exit 1
}

# ============================================================
# MENU PRINCIPAL
# ============================================================

while true; do

    # Recria estruturas temporárias caso o CloudShell
    # tenha limpado /tmp.
    prepare_tools

    # Atualiza informações do S3.
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

        1)
            run_operation "criar.sh"
            pause_menu
            ;;

        2)
            run_operation "ligar.sh"
            pause_menu
            ;;

        3)
            run_operation "suspender.sh"
            pause_menu
            ;;

        4)

            echo ""
            read -rp "Número da VM: " NUMERO

            if [[ ! "$NUMERO" =~ ^[0-9]+$ ]]; then
                echo "❌ Número inválido."
            else
                "$HOME/conectar.sh" "$CURRENT_PROJECT" "$NUMERO"
            fi

            pause_menu
            ;;

        5)
            run_operation "ansible.sh"
            pause_menu
            ;;

        6)
            run_operation "ip"
            pause_menu
            ;;

        7)
            run_operation "destruir.sh"
            pause_menu
            ;;

        8)

            if select_project; then
                echo ""
                echo "✅ Projeto alterado para: $CURRENT_PROJECT"
            fi

            pause_menu
            ;;

        0)

            echo ""
            echo "Saindo..."
            exit 0
            ;;

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
echo "\t SCRIPTS GERADOS"
echo ""
echo "Execute:"
echo ""
echo "  ~/fiaplab.sh"
echo ""
