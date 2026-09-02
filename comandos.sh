#!/bin/bash

# ============================================================
# CONFIGURAÇÕES
# ============================================================

HOME_DIR="$HOME"
FIAPLAB_DIR="$HOME/.fiaplab"
TF_DIR="$HOME/environment/config/ubuntu-vm"
SSH_KEY="$HOME/labsuser.pem"

# ============================================================
# VALIDAR AMBIENTE
# ============================================================

echo ""
echo "============================================================"
echo " CONFIGURANDO AMBIENTE FIAPLAB"
echo "============================================================"
echo ""

if [ ! -d "$HOME/environment" ]; then
    echo "❌ Diretório não encontrado:"
    echo "$HOME/environment"
    echo ""
    echo "Verifique se o projeto config foi clonado corretamente."
    exit 1
fi

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Diretório Terraform não encontrado:"
    echo "$TF_DIR"
    echo ""
    exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
    echo "⚠️ Chave SSH não encontrada:"
    echo "$SSH_KEY"
    echo ""
    echo "Os scripts serão criados, mas SSH/Ansible não funcionarão"
    echo "até que labsuser.pem esteja disponível."
    echo ""
else
    chmod 400 "$SSH_KEY"
fi

# ============================================================
# CRIAR DIRETÓRIO AUXILIAR
# ============================================================

mkdir -p "$FIAPLAB_DIR"

# ============================================================
# CONFIG.SH
# ============================================================

cat > "$FIAPLAB_DIR/config.sh" <<'EOF'
#!/bin/bash

# ============================================================
# CONFIGURAÇÕES CENTRAIS
# ============================================================

export TF_DIR="$HOME/environment/config/ubuntu-vm"
export SSH_KEY="$HOME/labsuser.pem"
export SSH_USER="ubuntu"
export AWS_REGION="us-east-1"
EOF

chmod +x "$FIAPLAB_DIR/config.sh"

# ============================================================
# GET_INSTANCES.SH
# ============================================================

cat > "$FIAPLAB_DIR/get_instances.sh" <<'EOF'
#!/bin/bash

source "$HOME/.fiaplab/config.sh"

cd "$TF_DIR" || exit 1

terraform show -json 2>/dev/null |
jq -r '
    .values.root_module.resources[]?
    | select(.type=="aws_instance" and .name=="web")
    | .values.id
'
EOF

chmod +x "$FIAPLAB_DIR/get_instances.sh"

# ============================================================
# CRIAR.SH
# ============================================================

cat > "$HOME/criar.sh" <<'EOF'
#!/bin/bash

set -e

source "$HOME/.fiaplab/config.sh"

cd "$TF_DIR" || exit 1

echo ""
echo "============================================================"
echo " TERRAFORM INIT"
echo "============================================================"
echo ""

terraform init

echo ""
echo "============================================================"
echo " TERRAFORM VALIDATE"
echo "============================================================"
echo ""

terraform validate

echo ""
echo "============================================================"
echo " TERRAFORM PLAN"
echo "============================================================"
echo ""

terraform plan

echo ""
echo "============================================================"
echo " APLICAR ALTERAÇÕES"
echo "============================================================"
echo ""

read -r -p "Deseja executar terraform apply? [s/N]: " CONFIRM

case "$CONFIRM" in
    s|S|sim|SIM|Sim)
        ;;
    *)
        echo ""
        echo "Operação cancelada."
        exit 0
        ;;
esac

terraform apply -auto-approve

echo ""
echo "============================================================"
echo " ✅ INFRAESTRUTURA CRIADA"
echo "============================================================"
echo ""

"$HOME/status.sh"
EOF

chmod +x "$HOME/criar.sh"

# ============================================================
# DESTRUIR.SH
# ============================================================

cat > "$HOME/destruir.sh" <<'EOF'
#!/bin/bash

set -e

source "$HOME/.fiaplab/config.sh"

cd "$TF_DIR" || exit 1

echo ""
echo "============================================================"
echo " ATENÇÃO"
echo "============================================================"
echo ""
echo "Este comando irá destruir TODOS os recursos gerenciados"
echo "pelo Terraform neste diretório:"
echo ""
echo "$TF_DIR"
echo ""

read -r -p "Digite DESTROY para confirmar: " CONFIRM

if [ "$CONFIRM" != "DESTROY" ]; then
    echo ""
    echo "Operação cancelada."
    exit 0
fi

echo ""
echo "============================================================"
echo " TERRAFORM DESTROY"
echo "============================================================"
echo ""

terraform destroy

echo ""
echo "============================================================"
echo " ✅ RECURSOS DESTRUÍDOS"
echo "============================================================"
echo ""
EOF

chmod +x "$HOME/destruir.sh"

# ============================================================
# LIGAR.SH
# ============================================================

cat > "$HOME/ligar.sh" <<'EOF'
#!/bin/bash

set -e

source "$HOME/.fiaplab/config.sh"

GET_INSTANCES="$HOME/.fiaplab/get_instances.sh"

if [ ! -x "$GET_INSTANCES" ]; then
    echo "❌ get_instances.sh não encontrado."
    exit 1
fi

mapfile -t INSTANCE_IDS < <("$GET_INSTANCES")

if [ "${#INSTANCE_IDS[@]}" -eq 0 ]; then
    echo ""
    echo "❌ Nenhuma instância encontrada no Terraform."
    echo ""
    exit 1
fi

echo ""
echo "============================================================"
echo " LIGANDO INSTÂNCIAS"
echo "============================================================"
echo ""

for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do

    STATE="$(
        aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text
    )"

    echo "Instância: $INSTANCE_ID"
    echo "Estado atual: $STATE"

    if [ "$STATE" = "running" ]; then
        echo "Já está ligada."
        echo ""
        continue
    fi

    if [ "$STATE" = "stopped" ]; then

        aws ec2 start-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            >/dev/null

        echo "Aguardando instância ficar disponível..."

        aws ec2 wait instance-running \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION"

        echo "✅ Instância ligada."
        echo ""

    else
        echo "⚠️ Estado não tratado: $STATE"
        echo ""
    fi

done

echo "============================================================"
echo " STATUS"
echo "============================================================"
echo ""

"$HOME/status.sh"
EOF

chmod +x "$HOME/ligar.sh"

# ============================================================
# SUSPENDER.SH
# ============================================================

cat > "$HOME/suspender.sh" <<'EOF'
#!/bin/bash

set -e

source "$HOME/.fiaplab/config.sh"

GET_INSTANCES="$HOME/.fiaplab/get_instances.sh"

if [ ! -x "$GET_INSTANCES" ]; then
    echo "❌ get_instances.sh não encontrado."
    exit 1
fi

mapfile -t INSTANCE_IDS < <("$GET_INSTANCES")

if [ "${#INSTANCE_IDS[@]}" -eq 0 ]; then
    echo ""
    echo "❌ Nenhuma instância encontrada no Terraform."
    echo ""
    exit 1
fi

echo ""
echo "============================================================"
echo " SUSPENDENDO INSTÂNCIAS"
echo "============================================================"
echo ""

for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do

    STATE="$(
        aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text
    )"

    echo "Instância: $INSTANCE_ID"
    echo "Estado atual: $STATE"

    if [ "$STATE" = "stopped" ]; then
        echo "Já está desligada."
        echo ""
        continue
    fi

    if [ "$STATE" = "running" ]; then

        aws ec2 stop-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            >/dev/null

        echo "Aguardando instância parar..."

        aws ec2 wait instance-stopped \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION"

        echo "✅ Instância suspensa."
        echo ""

    else
        echo "⚠️ Estado não tratado: $STATE"
        echo ""
    fi

done

echo "============================================================"
echo " STATUS"
echo "============================================================"
echo ""

"$HOME/status.sh"
EOF

chmod +x "$HOME/suspender.sh"

# ============================================================
# STATUS.SH
# ============================================================

cat > "$HOME/status.sh" <<'EOF'
#!/bin/bash

source "$HOME/.fiaplab/config.sh"

GET_INSTANCES="$HOME/.fiaplab/get_instances.sh"

if [ ! -x "$GET_INSTANCES" ]; then
    echo "❌ get_instances.sh não encontrado."
    exit 1
fi

mapfile -t INSTANCE_IDS < <("$GET_INSTANCES")

if [ "${#INSTANCE_IDS[@]}" -eq 0 ]; then
    echo ""
    echo "❌ Nenhuma instância encontrada no Terraform."
    echo ""
    exit 0
fi

echo ""
echo "============================================================"
echo " STATUS DAS VMs"
echo "============================================================"
echo ""

for i in "${!INSTANCE_IDS[@]}"; do

    INSTANCE_ID="${INSTANCE_IDS[$i]}"

    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].[InstanceId,State.Name,InstanceType,PublicIpAddress,PrivateIpAddress]' \
        --output table

    PUBLIC_IP="$(
        aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text
    )"

    STATE="$(
        aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text
    )"

    if [ "$STATE" = "running" ] && [ "$PUBLIC_IP" != "None" ]; then
        echo "VM $((i + 1)):"
        echo "  http://$PUBLIC_IP"
        echo ""
    fi

done
EOF

chmod +x "$HOME/status.sh"

# ============================================================
# IP
# ============================================================

cat > "$HOME/ip" <<'EOF'
#!/bin/bash

source "$HOME/.fiaplab/config.sh"

GET_INSTANCES="$HOME/.fiaplab/get_instances.sh"

mapfile -t INSTANCE_IDS < <("$GET_INSTANCES")

if [ "${#INSTANCE_IDS[@]}" -eq 0 ]; then
    echo "Desligada"
    exit 0
fi

INSTANCE_ID="${INSTANCE_IDS[0]}"

STATE="$(
    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null
)"

if [ "$STATE" != "running" ]; then
    echo "Desligada"
    exit 0
fi

PUBLIC_IP="$(
    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null
)"

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
    echo "Desligada"
else
    echo "$PUBLIC_IP"
fi
EOF

chmod +x "$HOME/ip"

# ============================================================
# CONECTAR.SH
# ============================================================

cat > "$HOME/conectar.sh" <<'EOF'
#!/bin/bash

source "$HOME/.fiaplab/config.sh"

GET_INSTANCES="$HOME/.fiaplab/get_instances.sh"

if [ ! -x "$GET_INSTANCES" ]; then
    echo "❌ get_instances.sh não encontrado."
    exit 1
fi

mapfile -t INSTANCE_IDS < <("$GET_INSTANCES")

if [ "${#INSTANCE_IDS[@]}" -eq 0 ]; then
    echo ""
    echo "❌ Nenhuma instância encontrada."
    exit 1
fi

VM_NUMBER="${1:-1}"

if ! [[ "$VM_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "❌ Número da VM inválido."
    echo ""
    echo "Exemplo:"
    echo "  ~/conectar.sh"
    echo "  ~/conectar.sh 2"
    exit 1
fi

if [ "$VM_NUMBER" -lt 1 ] || [ "$VM_NUMBER" -gt "${#INSTANCE_IDS[@]}" ]; then
    echo ""
    echo "❌ VM $VM_NUMBER não existe."
    echo ""
    echo "VMs disponíveis: 1 até ${#INSTANCE_IDS[@]}"
    exit 1
fi

INDEX=$((VM_NUMBER - 1))
INSTANCE_ID="${INSTANCE_IDS[$INDEX]}"

STATE="$(
    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text
)"

if [ "$STATE" != "running" ]; then
    echo ""
    echo "❌ A VM $VM_NUMBER não está ligada."
    echo ""
    echo "Estado: $STATE"
    echo ""
    echo "Execute:"
    echo "  ~/ligar.sh"
    exit 1
fi

PUBLIC_IP="$(
    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text
)"

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
    echo ""
    echo "❌ A VM não possui IP público."
    exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
    echo ""
    echo "❌ Chave SSH não encontrada:"
    echo "$SSH_KEY"
    exit 1
fi

chmod 400 "$SSH_KEY"

echo ""
echo "============================================================"
echo " CONECTANDO À VM $VM_NUMBER"
echo "============================================================"
echo ""
echo "Instance ID: $INSTANCE_ID"
echo "IP:          $PUBLIC_IP"
echo ""

ssh \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    "$SSH_USER@$PUBLIC_IP"
EOF

chmod +x "$HOME/conectar.sh"

# ============================================================
# ANISBLE.SH
# ============================================================

cat > "$HOME/ansible.sh" <<'EOF'
#!/bin/bash

# ============================================================
# CONFIGURAÇÕES
# ============================================================

export ANSIBLE_PYTHON_INTERPRETER=auto_silent
export ANSIBLE_DEPRECATION_WARNINGS=false
export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false

source "$HOME/.fiaplab/config.sh"

cd "$TF_DIR" || exit 1

# ============================================================
# LOCALIZAR ANSIBLE
# ============================================================

ANSIBLE_PLAYBOOK="$(command -v ansible-playbook 2>/dev/null || true)"

if [ -z "$ANSIBLE_PLAYBOOK" ]; then

    if [ -x "/tmp/fiap/ansible_venv/bin/ansible-playbook" ]; then
        ANSIBLE_PLAYBOOK="/tmp/fiap/ansible_venv/bin/ansible-playbook"
    else
        echo ""
        echo "❌ ansible-playbook não encontrado!"
        echo ""
        echo "Verifique a instalação do Ansible no CloudShell."
        exit 1
    fi

fi

echo ""
echo "ANSIBLE:"
echo "$ANSIBLE_PLAYBOOK"
echo ""

# ============================================================
# LOCALIZAR COMANDO ANSIBLE
# ============================================================

ANSIBLE_BIN="$(dirname "$ANSIBLE_PLAYBOOK")/ansible"

if [ ! -x "$ANSIBLE_BIN" ]; then
    ANSIBLE_BIN="$(command -v ansible 2>/dev/null || true)"
fi

if [ -z "$ANSIBLE_BIN" ]; then
    echo ""
    echo "❌ Comando ansible não encontrado!"
    exit 1
fi

# ============================================================
# LOCALIZAR INSTÂNCIAS
# ============================================================

GET_INSTANCES="$HOME/.fiaplab/get_instances.sh"

if [ ! -x "$GET_INSTANCES" ]; then
    echo ""
    echo "❌ get_instances.sh não encontrado:"
    echo "$GET_INSTANCES"
    exit 1
fi

mapfile -t INSTANCE_IDS < <("$GET_INSTANCES")

if [ "${#INSTANCE_IDS[@]}" -eq 0 ]; then
    echo ""
    echo "❌ Nenhuma instância EC2 encontrada no Terraform."
    echo ""
    echo "Execute primeiro:"
    echo "  ~/criar.sh"
    exit 1
fi

INSTANCE_ID="${INSTANCE_IDS[0]}"

# ============================================================
# CONSULTAR ESTADO DA VM
# ============================================================

echo "Consultando instância:"
echo "$INSTANCE_ID"
echo ""

STATE="$(
    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null
)"

if [ "$STATE" != "running" ]; then
    echo ""
    echo "❌ A VM não está ligada."
    echo ""
    echo "Estado: $STATE"
    echo "Instância: $INSTANCE_ID"
    echo ""
    echo "Execute:"
    echo "  ~/ligar.sh"
    exit 1
fi

# ============================================================
# DESCOBRIR IP
# ============================================================

PUBLIC_IP="$(
    aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null
)"

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
    echo ""
    echo "❌ A VM está ligada, mas não possui IP público."
    exit 1
fi

echo ""
echo "IP público:"
echo "$PUBLIC_IP"
echo ""

# ============================================================
# VALIDAR CHAVE SSH
# ============================================================

if [ ! -f "$SSH_KEY" ]; then
    echo ""
    echo "❌ Chave SSH não encontrada:"
    echo "$SSH_KEY"
    exit 1
fi

chmod 400 "$SSH_KEY"

# ============================================================
# CRIAR INVENTÁRIO TEMPORÁRIO
# ============================================================

INVENTORY="$(mktemp)"

trap 'rm -f "$INVENTORY"' EXIT

cat > "$INVENTORY" <<INVENTORY_EOF
[ubuntu]
vm1 ansible_host=$PUBLIC_IP ansible_user=$SSH_USER

[ubuntu:vars]
ansible_ssh_private_key_file=$SSH_KEY
ansible_python_interpreter=/usr/bin/python3
INVENTORY_EOF

echo "============================================================"
echo " INVENTÁRIO"
echo "============================================================"
echo ""

cat "$INVENTORY"

echo ""

# ============================================================
# TESTAR ANSIBLE
# ============================================================

echo "============================================================"
echo " TESTANDO ANSIBLE"
echo "============================================================"
echo ""

echo "Ansible:"
"$ANSIBLE_PLAYBOOK" --version | head -n 1

echo ""
echo "Executando:"
echo "$ANSIBLE_BIN -i $INVENTORY ubuntu -m ping"
echo ""

if ! "$ANSIBLE_BIN" -i "$INVENTORY" ubuntu -m ping; then

    echo ""
    echo "❌ Falha na conexão com a VM."
    echo ""
    echo "Verifique:"
    echo "  - VM está ligada"
    echo "  - IP público"
    echo "  - labsuser.pem"
    echo "  - Security Group"
    echo "  - acesso SSH"
    echo ""

    exit 1
fi

echo ""
echo "✅ Conexão Ansible funcionando!"
echo ""

# ============================================================
# LOCALIZAR PLAYBOOKS
# ============================================================

mapfile -t PLAYBOOKS < <(
    find "$TF_DIR" -maxdepth 2 -type f \
        \( -name "*.yml" -o -name "*.yaml" \) \
        ! -name "inventory*" \
        | sort
)

if [ "${#PLAYBOOKS[@]}" -eq 0 ]; then

    echo ""
    echo "⚠️ Nenhum playbook YAML encontrado em:"
    echo "$TF_DIR"
    echo ""

    exit 0
fi

# ============================================================
# MOSTRAR PLAYBOOKS
# ============================================================

echo "============================================================"
echo " PLAYBOOKS ENCONTRADOS"
echo "============================================================"
echo ""

for i in "${!PLAYBOOKS[@]}"; do
    echo "[$((i + 1))] ${PLAYBOOKS[$i]}"
done

echo ""

# ============================================================
# ESCOLHER PLAYBOOK
# ============================================================

if [ "${#PLAYBOOKS[@]}" -eq 1 ]; then

    SELECTED_PLAYBOOK="${PLAYBOOKS[0]}"

    echo "Playbook selecionado:"
    echo "$SELECTED_PLAYBOOK"
    echo ""

else

    read -r -p "Escolha o playbook [1-${#PLAYBOOKS[@]}]: " OPTION

    if ! [[ "$OPTION" =~ ^[0-9]+$ ]] ||
       [ "$OPTION" -lt 1 ] ||
       [ "$OPTION" -gt "${#PLAYBOOKS[@]}" ]; then

        echo ""
        echo "❌ Opção inválida."
        exit 1
    fi

    SELECTED_PLAYBOOK="${PLAYBOOKS[$((OPTION - 1))]}"

fi

# ============================================================
# CONFIRMAR EXECUÇÃO
# ============================================================

echo ""
echo "============================================================"
echo " PLAYBOOK SELECIONADO"
echo "============================================================"
echo ""
echo "Playbook:"
echo "$SELECTED_PLAYBOOK"
echo ""
echo "VM:"
echo "$INSTANCE_ID"
echo ""
echo "IP:"
echo "$PUBLIC_IP"
echo ""

read -r -p "Deseja executar este playbook? [s/N]: " CONFIRM

case "$CONFIRM" in
    s|S|sim|SIM|Sim)
        ;;
    *)
        echo ""
        echo "Operação cancelada."
        exit 0
        ;;
esac

# ============================================================
# EXECUTAR PLAYBOOK
# ============================================================

echo ""
echo "============================================================"
echo " EXECUTANDO ANSIBLE"
echo "============================================================"
echo ""

"$ANSIBLE_PLAYBOOK" \
    -i "$INVENTORY" \
    "$SELECTED_PLAYBOOK"

RESULT=$?

echo ""

if [ "$RESULT" -eq 0 ]; then

    echo "============================================================"
    echo " ✅ ANSIBLE EXECUTADO COM SUCESSO"
    echo "============================================================"

else

    echo "============================================================"
    echo " ❌ ANSIBLE FINALIZOU COM ERRO"
    echo "============================================================"

    exit "$RESULT"

fi
EOF

chmod +x "$HOME/ansible.sh"

# ============================================================
# FINALIZAÇÃO
# ============================================================

echo ""
echo "============================================================"
echo " ✅ CONFIGURAÇÃO CONCLUÍDA"
echo "============================================================"
echo ""

echo "Scripts criados:"
echo ""
echo "  ~/criar.sh"
echo "  ~/destruir.sh"
echo "  ~/ligar.sh"
echo "  ~/suspender.sh"
echo "  ~/status.sh"
echo "  ~/ip"
echo "  ~/conectar.sh"
echo "  ~/ansible.sh"
echo ""

echo "Configurações auxiliares:"
echo ""
echo "  ~/.fiaplab/config.sh"
echo "  ~/.fiaplab/get_instances.sh"
echo ""

echo "============================================================"
echo " COMANDOS PRINCIPAIS"
echo "============================================================"
echo ""
echo "Criar VM:"
echo "  ~/criar.sh"
echo ""
echo "Ver status:"
echo "  ~/status.sh"
echo ""
echo "Ver somente IP:"
echo "  ~/ip"
echo ""
echo "Conectar na primeira VM:"
echo "  ~/conectar.sh"
echo ""
echo "Conectar na VM 2:"
echo "  ~/conectar.sh 2"
echo ""
echo "Ligar VM(s):"
echo "  ~/ligar.sh"
echo ""
echo "Suspender VM(s):"
echo "  ~/suspender.sh"
echo ""
echo "Executar Ansible:"
echo "  ~/ansible.sh"
echo ""
echo "Destruir infraestrutura:"
echo "  ~/destruir.sh"
echo ""
echo "============================================================"
