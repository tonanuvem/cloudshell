#!/bin/bash

# ============================================================
# COMANDOS CLOUDSHELL
#
# Este script é chamado pelo:
#   ~/cloudshell/init.sh
#
# Ele cria os scripts auxiliares diretamente em $HOME:
#
#   ~/criar.sh
#   ~/destruir.sh
#   ~/ligar.sh
#   ~/suspender.sh
#   ~/status.sh
#   ~/ip
#   ~/conectar.sh
#   ~/ansible.sh
#
# Não utiliza:
#   - set -e
#   - source de outro arquivo de configuração
#   - ~/.fiaplab/comandos.sh
# ============================================================


# ============================================================
# CONFIGURAÇÕES
# ============================================================

TF_DIR="$HOME/environment/config/ubuntu-vm"
SSH_KEY="$HOME/environment/labsuser.pem"

AWS_REGION="${AWS_REGION:-us-east-1}"

ACCOUNT_ID="$(aws sts get-caller-identity \
    --query Account \
    --output text 2>/dev/null)"

TFSTATE_BUCKET="tfstate-cloudshell-${ACCOUNT_ID}"
TFSTATE_TABLE="terraform-locks"
TFSTATE_KEY="ubuntu-vm/terraform.tfstate"


# ============================================================
# CRIAR
# ============================================================

cat > "$HOME/criar.sh" <<'EOF'
#!/bin/bash

# ============================================================
# CRIAR INFRAESTRUTURA
# ============================================================

TF_DIR="$HOME/environment/config/ubuntu-vm"

AWS_REGION="${AWS_REGION:-us-east-1}"

ACCOUNT_ID="$(aws sts get-caller-identity \
    --query Account \
    --output text)"

TFSTATE_BUCKET="tfstate-cloudshell-${ACCOUNT_ID}"
TFSTATE_TABLE="terraform-locks"
TFSTATE_KEY="ubuntu-vm/terraform.tfstate"


echo ""
echo "=========================================="
echo " CRIAR INFRAESTRUTURA"
echo "=========================================="
echo ""

echo "AWS Account : $ACCOUNT_ID"
echo "AWS Region  : $AWS_REGION"
echo "S3 Bucket   : $TFSTATE_BUCKET"
echo "DynamoDB    : $TFSTATE_TABLE"
echo "TF State    : $TFSTATE_KEY"
echo ""

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

cd "$TF_DIR"

# ============================================================
# BACKEND
# ============================================================

if ! grep -Rqs 'backend[[:space:]]*"s3"' "$TF_DIR"/*.tf 2>/dev/null; then

    cat > "$TF_DIR/backend.tf" <<'BACKEND'
terraform {
  backend "s3" {}
}
BACKEND

    echo "✓ backend.tf criado."

else

    echo "✓ Backend S3 já configurado."

fi

echo ""
echo "=========================================="
echo " TERRAFORM INIT"
echo "=========================================="
echo ""

terraform init \
    -reconfigure \
    -backend-config="bucket=$TFSTATE_BUCKET" \
    -backend-config="key=$TFSTATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="dynamodb_table=$TFSTATE_TABLE"

echo ""
echo "=========================================="
echo " TERRAFORM VALIDATE"
echo "=========================================="
echo ""

terraform validate

echo ""
echo "=========================================="
echo " TERRAFORM PLAN"
echo "=========================================="
echo ""

terraform plan

echo ""
echo "=========================================="
echo " CONFIRMAÇÃO"
echo "=========================================="
echo ""

read -r -p "Deseja executar terraform apply? [s/N]: " CONFIRMA

if [[ ! "$CONFIRMA" =~ ^[sS]$ ]]; then
    echo ""
    echo "Operação cancelada."
    exit 0
fi

echo ""
echo "=========================================="
echo " TERRAFORM APPLY"
echo "=========================================="
echo ""

terraform apply -auto-approve

echo ""
echo "=========================================="
echo " INFRAESTRUTURA CRIADA"
echo "=========================================="
echo ""

"$HOME/status.sh"
EOF

chmod +x "$HOME/criar.sh"


# ============================================================
# DESTRUIR
# ============================================================

cat > "$HOME/destruir.sh" <<'EOF'
#!/bin/bash

# ============================================================
# DESTRUIR INFRAESTRUTURA
# ============================================================

TF_DIR="$HOME/environment/config/ubuntu-vm"

AWS_REGION="${AWS_REGION:-us-east-1}"

ACCOUNT_ID="$(aws sts get-caller-identity \
    --query Account \
    --output text)"

TFSTATE_BUCKET="tfstate-cloudshell-${ACCOUNT_ID}"
TFSTATE_TABLE="terraform-locks"
TFSTATE_KEY="ubuntu-vm/terraform.tfstate"


echo ""
echo "=========================================="
echo " DESTRUIR INFRAESTRUTURA"
echo "=========================================="
echo ""

echo "AWS Account : $ACCOUNT_ID"
echo "AWS Region  : $AWS_REGION"
echo "S3 Bucket   : $TFSTATE_BUCKET"
echo "DynamoDB    : $TFSTATE_TABLE"
echo ""

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

cd "$TF_DIR"

# ============================================================
# BACKEND
# ============================================================

if ! grep -Rqs 'backend[[:space:]]*"s3"' "$TF_DIR"/*.tf 2>/dev/null; then

    cat > "$TF_DIR/backend.tf" <<'BACKEND'
terraform {
  backend "s3" {}
}
BACKEND

    echo "✓ backend.tf criado."

fi

echo ""
echo "Inicializando Terraform..."
echo ""

terraform init \
    -reconfigure \
    -backend-config="bucket=$TFSTATE_BUCKET" \
    -backend-config="key=$TFSTATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="dynamodb_table=$TFSTATE_TABLE"

echo ""
echo "Recursos atualmente gerenciados:"
echo ""

terraform state list

echo ""
echo "=========================================="
echo " ATENÇÃO"
echo "=========================================="
echo ""
echo "Esta operação irá destruir os recursos"
echo "gerenciados por este Terraform."
echo ""

read -r -p "Deseja realmente destruir tudo? [s/N]: " CONFIRMA

if [[ ! "$CONFIRMA" =~ ^[sS]$ ]]; then
    echo ""
    echo "Operação cancelada."
    exit 0
fi

echo ""
echo "Destruindo infraestrutura..."
echo ""

terraform destroy -auto-approve

echo ""
echo "=========================================="
echo " INFRAESTRUTURA DESTRUÍDA"
echo "=========================================="
echo ""
EOF

chmod +x "$HOME/destruir.sh"


# ============================================================
# LIGAR
# ============================================================

cat > "$HOME/ligar.sh" <<'EOF'
#!/bin/bash

# ============================================================
# LIGAR INSTÂNCIAS
# ============================================================

TF_DIR="$HOME/environment/config/ubuntu-vm"

AWS_REGION="${AWS_REGION:-us-east-1}"


echo ""
echo "=========================================="
echo " LIGAR INSTÂNCIAS"
echo "=========================================="
echo ""

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

cd "$TF_DIR"

mapfile -t INSTANCES < <(
    terraform show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "Nenhuma instância encontrada no Terraform."
    exit 0
fi

for INSTANCE_ID in "${INSTANCES[@]}"; do

    [ -z "$INSTANCE_ID" ] && continue

    STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)

    echo "$INSTANCE_ID -> $STATE"

    if [ "$STATE" = "stopped" ]; then

        echo "Ligando $INSTANCE_ID..."

        aws ec2 start-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION"

        echo ""
        echo "Aguardando instância iniciar..."
        echo ""

        aws ec2 wait instance-running \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION"

        echo "✓ $INSTANCE_ID ligada."

    elif [ "$STATE" = "running" ]; then

        echo "✓ $INSTANCE_ID já está ligada."

    else

        echo "⚠️ Estado atual: $STATE"

    fi

    echo ""

done
EOF

chmod +x "$HOME/ligar.sh"


# ============================================================
# SUSPENDER
# ============================================================

cat > "$HOME/suspender.sh" <<'EOF'
#!/bin/bash

# ============================================================
# SUSPENDER INSTÂNCIAS
# ============================================================

TF_DIR="$HOME/environment/config/ubuntu-vm"

AWS_REGION="${AWS_REGION:-us-east-1}"


echo ""
echo "=========================================="
echo " SUSPENDER INSTÂNCIAS"
echo "=========================================="
echo ""

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

cd "$TF_DIR"

mapfile -t INSTANCES < <(
    terraform show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "Nenhuma instância encontrada no Terraform."
    exit 0
fi

for INSTANCE_ID in "${INSTANCES[@]}"; do

    [ -z "$INSTANCE_ID" ] && continue

    STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)

    echo "$INSTANCE_ID -> $STATE"

    if [ "$STATE" = "running" ]; then

        echo "Suspendendo $INSTANCE_ID..."

        aws ec2 stop-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION"

        echo "✓ Comando de suspensão enviado."

    elif [ "$STATE" = "stopped" ]; then

        echo "✓ $INSTANCE_ID já está desligada."

    else

        echo "⚠️ Estado atual: $STATE"

    fi

    echo ""

done
EOF

chmod +x "$HOME/suspender.sh"


# ============================================================
# STATUS
# ============================================================

cat > "$HOME/status.sh" <<'EOF'
#!/bin/bash

# ============================================================
# STATUS DAS INSTÂNCIAS
# ============================================================

TF_DIR="$HOME/environment/config/ubuntu-vm"

AWS_REGION="${AWS_REGION:-us-east-1}"


echo ""
echo "=========================================="
echo " STATUS DAS INSTÂNCIAS"
echo "=========================================="
echo ""

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

cd "$TF_DIR"

mapfile -t INSTANCES < <(
    terraform show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "Nenhuma instância encontrada no Terraform."
    exit 0
fi

printf "%-18s %-12s %-12s %-16s %-16s\n" \
    "INSTANCE ID" "STATUS" "TIPO" "IP PÚBLICO" "IP PRIVADO"

echo "--------------------------------------------------------------------------------"

for INSTANCE_ID in "${INSTANCES[@]}"; do

    [ -z "$INSTANCE_ID" ] && continue

    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].[InstanceId,State.Name,InstanceType,PublicIpAddress,PrivateIpAddress]' \
        --output text |
    awk '{
        printf "%-18s %-12s %-12s %-16s %-16s\n",
        $1, $2, $3, ($4=="None" ? "-" : $4), ($5=="None" ? "-" : $5)
    }'

done

echo ""
echo "URLs das instâncias em execução:"
echo ""

for INSTANCE_ID in "${INSTANCES[@]}"; do

    [ -z "$INSTANCE_ID" ] && continue

    INFO=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' \
        --output text)

    STATE=$(echo "$INFO" | awk '{print $1}')
    PUBLIC_IP=$(echo "$INFO" | awk '{print $2}')

    if [ "$STATE" = "running" ] && [ "$PUBLIC_IP" != "None" ]; then
        echo "http://$PUBLIC_IP"
    fi

done

echo ""
EOF

chmod +x "$HOME/status.sh"


# ============================================================
# IP
# ============================================================

cat > "$HOME/ip" <<'EOF'
#!/bin/bash

# ============================================================
# IP PÚBLICO DA PRIMEIRA INSTÂNCIA
# ============================================================

TF_DIR="$HOME/environment/config/ubuntu-vm"

AWS_REGION="${AWS_REGION:-us-east-1}"


if [ ! -d "$TF_DIR" ]; then
    echo "Desligada"
    exit 0
fi

cd "$TF_DIR"

mapfile -t INSTANCES < <(
    terraform show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    echo "Desligada"
    exit 0
fi

for INSTANCE_ID in "${INSTANCES[@]}"; do

    [ -z "$INSTANCE_ID" ] && continue

    INFO=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' \
        --output text)

    STATE=$(echo "$INFO" | awk '{print $1}')
    PUBLIC_IP=$(echo "$INFO" | awk '{print $2}')

    if [ "$STATE" = "running" ] && [ "$PUBLIC_IP" != "None" ]; then
        echo "$PUBLIC_IP"
        exit 0
    fi

done

echo "Desligada"
EOF

chmod +x "$HOME/ip"


# ============================================================
# CONECTAR
# ============================================================

cat > "$HOME/conectar.sh" <<'EOF'
#!/bin/bash

# ============================================================
# CONECTAR VIA SSH
#
# Uso:
#   ~/conectar.sh
#   ~/conectar.sh 2
#   ~/conectar.sh 3
# ============================================================

TF_DIR="$HOME/environment/config/ubuntu-vm"
SSH_KEY="$HOME/environment/labsuser.pem"

AWS_REGION="${AWS_REGION:-us-east-1}"

NUMERO="${1:-1}"


if ! [[ "$NUMERO" =~ ^[0-9]+$ ]] || [ "$NUMERO" -lt 1 ]; then

    echo "Uso:"
    echo "  ~/conectar.sh"
    echo "  ~/conectar.sh 2"

    exit 1

fi


if [ ! -d "$TF_DIR" ]; then

    echo "❌ Diretório Terraform não encontrado:"
    echo "   $TF_DIR"

    exit 1

fi

cd "$TF_DIR"

mapfile -t INSTANCES < <(
    terraform show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

TOTAL="${#INSTANCES[@]}"

if [ "$TOTAL" -eq 0 ]; then

    echo "❌ Nenhuma instância encontrada no Terraform."

    exit 1

fi

if [ "$NUMERO" -gt "$TOTAL" ]; then

    echo "❌ Instância $NUMERO não existe."
    echo "Total de instâncias: $TOTAL"

    exit 1

fi


INSTANCE_ID="${INSTANCES[$((NUMERO - 1))]}"


INFO=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' \
    --output text)

STATE=$(echo "$INFO" | awk '{print $1}')
PUBLIC_IP=$(echo "$INFO" | awk '{print $2}')


if [ "$STATE" != "running" ]; then

    echo "❌ A instância $INSTANCE_ID não está ligada."
    echo "Estado atual: $STATE"
    echo ""
    echo "Execute:"
    echo "  ~/ligar.sh"

    exit 1

fi


if [ "$PUBLIC_IP" = "None" ] || [ -z "$PUBLIC_IP" ]; then

    echo "❌ A instância não possui IP público."

    exit 1

fi


if [ ! -f "$SSH_KEY" ]; then

    echo "❌ Chave SSH não encontrada:"
    echo "   $SSH_KEY"

    exit 1

fi


chmod 400 "$SSH_KEY"


echo ""
echo "=========================================="
echo " CONECTANDO"
echo "=========================================="
echo ""

echo "Instância : #$NUMERO"
echo "ID        : $INSTANCE_ID"
echo "IP        : $PUBLIC_IP"
echo ""

ssh \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    ubuntu@"$PUBLIC_IP"
EOF

chmod +x "$HOME/conectar.sh"


# ============================================================
# ANSIBLE
# ============================================================

cat > "$HOME/ansible.sh" <<'EOF'
#!/bin/bash

# ============================================================
# ANSIBLE
# ============================================================

TF_DIR="$HOME/environment/config/ubuntu-vm"
SSH_KEY="$HOME/environment/labsuser.pem"

AWS_REGION="${AWS_REGION:-us-east-1}"


echo ""
echo "=========================================="
echo " ANSIBLE"
echo "=========================================="
echo ""


# ============================================================
# Localizar ansible-playbook
# ============================================================

ANSIBLE_PLAYBOOK="$(command -v ansible-playbook 2>/dev/null || true)"

if [ -z "$ANSIBLE_PLAYBOOK" ]; then

    if [ -x "/tmp/fiap/ansible_venv/bin/ansible-playbook" ]; then

        ANSIBLE_PLAYBOOK="/tmp/fiap/ansible_venv/bin/ansible-playbook"

    else

        echo "❌ ansible-playbook não encontrado!"
        echo ""
        echo "Verifique a instalação do Ansible no CloudShell."

        exit 1

    fi

fi


echo "ANSIBLE:"
echo "$ANSIBLE_PLAYBOOK"
echo ""


# ============================================================
# Localizar ansible
# ============================================================

ANSIBLE="$(command -v ansible 2>/dev/null || true)"

if [ -z "$ANSIBLE" ]; then

    if [ -x "/tmp/fiap/ansible_venv/bin/ansible" ]; then

        ANSIBLE="/tmp/fiap/ansible_venv/bin/ansible"

    else

        echo "❌ Comando ansible não encontrado."

        exit 1

    fi

fi


# ============================================================
# Configurações Ansible
# ============================================================

export ANSIBLE_PYTHON_INTERPRETER=auto_silent
export ANSIBLE_DEPRECATION_WARNINGS=false
export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false


# ============================================================
# Terraform
# ============================================================

if [ ! -d "$TF_DIR" ]; then

    echo "❌ Diretório Terraform não encontrado:"
    echo "   $TF_DIR"

    exit 1

fi

cd "$TF_DIR"


# ============================================================
# Obter instâncias
# ============================================================

mapfile -t INSTANCES < <(
    terraform show -json 2>/dev/null |
    jq -r '
        .values.root_module.resources[]?
        | select(.type=="aws_instance" and .name=="web")
        | .values.id
    '
)

if [ "${#INSTANCES[@]}" -eq 0 ]; then

    echo "❌ Nenhuma instância encontrada no Terraform."

    exit 1

fi


echo "Instâncias encontradas:"
echo ""


for INDEX in "${!INSTANCES[@]}"; do

    INSTANCE_ID="${INSTANCES[$INDEX]}"

    STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)

    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)

    echo "$((INDEX + 1)). $INSTANCE_ID | $STATE | $PUBLIC_IP"

done


echo ""


# ============================================================
# Primeira instância
# ============================================================

FIRST_INSTANCE="${INSTANCES[0]}"


STATE=$(aws ec2 describe-instances \
    --instance-ids "$FIRST_INSTANCE" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)


if [ "$STATE" != "running" ]; then

    echo "❌ A primeira instância não está ligada."
    echo "Estado: $STATE"
    echo ""
    echo "Execute:"
    echo "  ~/ligar.sh"

    exit 1

fi


PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$FIRST_INSTANCE" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)


if [ "$PUBLIC_IP" = "None" ] || [ -z "$PUBLIC_IP" ]; then

    echo "❌ A primeira instância não possui IP público."

    exit 1

fi


# ============================================================
# Chave SSH
# ============================================================

if [ ! -f "$SSH_KEY" ]; then

    echo "❌ Chave SSH não encontrada:"
    echo "$SSH_KEY"

    exit 1

fi


chmod 400 "$SSH_KEY"


# ============================================================
# Inventário temporário
# ============================================================

INVENTORY="$(mktemp)"

trap 'rm -f "$INVENTORY"' EXIT


cat > "$INVENTORY" <<INVENTORY_EOF
[nodes]
ubuntu ansible_host=$PUBLIC_IP ansible_user=ubuntu ansible_ssh_private_key_file=$SSH_KEY ansible_python_interpreter=auto_silent
INVENTORY_EOF


echo ""
echo "Inventário:"
echo "------------------------------------------"
cat "$INVENTORY"
echo "------------------------------------------"
echo ""


# ============================================================
# Testar conexão
# ============================================================

echo "Testando conexão com a VM..."
echo ""


"$ANSIBLE" \
    -i "$INVENTORY" \
    nodes \
    -m ping


echo ""
echo "✓ Conexão Ansible OK."
echo ""


# ============================================================
# Procurar playbooks
# ============================================================

mapfile -t PLAYBOOKS < <(
    find "$TF_DIR" \
        -type f \
        \( -name "*.yml" -o -name "*.yaml" \) \
        ! -path "*/.terraform/*" \
        | sort
)


if [ "${#PLAYBOOKS[@]}" -eq 0 ]; then

    echo "❌ Nenhum playbook .yml/.yaml encontrado em:"
    echo "$TF_DIR"

    exit 1

fi


echo "Playbooks encontrados:"
echo ""


for INDEX in "${!PLAYBOOKS[@]}"; do

    echo "$((INDEX + 1)). ${PLAYBOOKS[$INDEX]}"

done


echo ""


# ============================================================
# Selecionar playbook
# ============================================================

if [ "${#PLAYBOOKS[@]}" -eq 1 ]; then

    PLAYBOOK="${PLAYBOOKS[0]}"

else

    read -r -p "Escolha o número do playbook: " OPCAO

    if ! [[ "$OPCAO" =~ ^[0-9]+$ ]]; then

        echo "❌ Opção inválida."

        exit 1

    fi

    if [ "$OPCAO" -lt 1 ] || [ "$OPCAO" -gt "${#PLAYBOOKS[@]}" ]; then

        echo "❌ Opção inválida."

        exit 1

    fi

    PLAYBOOK="${PLAYBOOKS[$((OPCAO - 1))]}"

fi


echo ""
echo "Playbook selecionado:"
echo "$PLAYBOOK"
echo ""


read -r -p "Deseja executar este playbook? [s/N]: " CONFIRMA


if [[ ! "$CONFIRMA" =~ ^[sS]$ ]]; then

    echo ""
    echo "Operação cancelada."

    exit 0

fi


echo ""
echo "Executando Ansible..."
echo ""


"$ANSIBLE_PLAYBOOK" \
    -i "$INVENTORY" \
    "$PLAYBOOK"


echo ""
echo "=========================================="
echo " ANSIBLE FINALIZADO"
echo "=========================================="
echo ""
EOF

chmod +x "$HOME/ansible.sh"


# ============================================================
# RESUMO
# ============================================================

echo ""
echo "=========================================="
echo " SCRIPTS CRIADOS"
echo "=========================================="
echo ""

echo "Criar infraestrutura:"
echo "  ~/criar.sh"
echo ""

echo "Destruir infraestrutura:"
echo "  ~/destruir.sh"
echo ""

echo "Ligar VM:"
echo "  ~/ligar.sh"
echo ""

echo "Suspender VM:"
echo "  ~/suspender.sh"
echo ""

echo "Ver status:"
echo "  ~/status.sh"
echo ""

echo "Ver IP da primeira VM:"
echo "  ~/ip"
echo ""

echo "Conectar na primeira VM:"
echo "  ~/conectar.sh"
echo ""

echo "Conectar na VM 2:"
echo "  ~/conectar.sh 2"
echo ""

echo "Executar Ansible:"
echo "  ~/ansible.sh"
echo ""

echo "=========================================="
