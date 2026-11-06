#!/bin/bash

# Localiza o proprio diretorio (bin/) para achar a lib e os
# scripts irmaos, sem depender de copias no $HOME.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

PROJECT="$1"
ALVO="$2"      # numero da VM, IP, ou vazio (escolhe/descobre)

if [ -z "$PROJECT" ]; then
    echo "Uso:"
    echo "  ~/conectar.sh <projeto> [numero|IP]"
    echo ""
    echo "Exemplos:"
    echo "  ~/conectar.sh cluster 3"
    echo "  ~/conectar.sh ubuntu-vm 54.1.2.3"
    echo ""
    echo "Sem o 2o argumento: com uma VM conecta nela; com várias,"
    echo "pergunta em qual."
    exit 1
fi

# Um IP como 2o argumento vai direto: e assim que o menu manda a VM
# escolhida no vm_pick, sem ter de traduzir nome em "numero do no"
# (que so existe para projetos multi-node lidos do state).
NODENUM=""
IP_ARG=""

if [[ "$ALVO" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    IP_ARG="$ALVO"
elif [[ "$ALVO" =~ ^[0-9]+$ ]] && [ "$ALVO" -ge 1 ]; then
    NODENUM="$ALVO"
elif [ -n "$ALVO" ]; then
    echo "❌ Argumento inválido: $ALVO (use o número da VM ou o IP)."
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

KEY="$ENV_DIR/labsuser.pem"
CREDENTIALS="$CRED_DIR/credentials"

if [ ! -f "$KEY" ]; then
    echo "❌ Chave SSH não encontrada:"
    echo "   $KEY"
    exit 1
fi

# Regenera o arquivo de credenciais imediatamente antes do scp,
# para a VM nao receber um token ja vencido.
aws_require || exit 1

echo ""
echo "Conectando ao projeto: $PROJECT"
echo ""

# --- IP vindo pronto no argumento ---
IP="$IP_ARG"

# --- Sem argumento: escolhe entre as VMs do lab em execucao ---
# Antes, o menu chamava sempre com o no 1 e o aluno com varias VMs
# (lotes do criar-varias.sh) so conseguia entrar na primeira. Com uma
# VM so, o vm_pick nao pergunta nada -- o comportamento de sempre.
if [ -z "$IP" ] && [ -z "$NODENUM" ]; then
    if vm_pick "Conectar em" running ""; then
        IP="${VM_PICK_IPS[0]}"
        echo ""
        echo "VM: ${VM_PICK_NAMES[0]}"
    else
        exit 1
    fi
fi

# --- Caminho rapido: IP da VM do fiaplab via AWS CLI ---
# Evita instalar/inicializar o Terraform so para descobrir o IP (o
# menu ja mostrou esse IP). So vale para a VM unica do fiaplab (node 1).
if [ -z "$IP" ] && [ "$NODENUM" = "1" ]; then
    IP=$(fiaplab_running_ip)
fi

# --- Fallback generico: outros projetos / multi-node ---
# Le o IP do state (precisa do Terraform), instalando-o se necessario.
if [ -z "$IP" ] || [ "$IP" = "None" ]; then
    prepare_tools_tf || exit 1
    tf_ensure_init "$PROJECT" || exit 1
    mapfile -t IPS < <(ec2_public_ips "$PROJECT" | grep -v '^[[:space:]]*$')
    IP="${IPS[$((${NODENUM:-1} - 1))]}"
fi

if [ ! -f "$CREDENTIALS" ]; then
    echo "❌ Credenciais AWS não encontradas:"
    echo "   $CREDENTIALS"
    exit 1
fi

if [ -z "$IP" ] || [ "$IP" = "null" ] || [ "$IP" = "None" ]; then

    echo ""
    echo "❌ Não foi possível obter o IP da VM ${NODENUM:-1}."
    echo ""
    echo "   A VM pode estar desligada. Ligue-a primeiro (opção Ligar)"
    echo "   e aguarde alguns segundos antes de conectar."
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

SSH_OPTS=(-o LogLevel=error -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$KEY")

# Descobre o usuario SSH: ubuntu (Ubuntu) ou ec2-user (Amazon Linux).
# Forcavel com FIAPLAB_SSH_USER. BatchMode evita prompt de senha ao
# testar cada candidato.
SSH_USER=""
for U in ${FIAPLAB_SSH_USER:-} ubuntu ec2-user; do
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "${SSH_OPTS[@]}" "$U@$IP" true 2>/dev/null; then
        SSH_USER="$U"
        break
    fi
done

if [ -z "$SSH_USER" ]; then
    echo "❌ Não foi possível autenticar por SSH (tentei ubuntu e ec2-user)."
    echo "   Verifique se a VM terminou de iniciar e a chave labsuser.pem."
    exit 1
fi

REMOTE_HOME="/home/$SSH_USER"

ssh "${SSH_OPTS[@]}" "$SSH_USER@$IP" "mkdir -p $REMOTE_HOME/.aws" || {
    echo "❌ Não foi possível preparar a VM."
    exit 1
}

scp -q "${SSH_OPTS[@]}" "$CREDENTIALS" "$SSH_USER@$IP:$REMOTE_HOME/.aws/credentials" || {
    echo "❌ Erro ao copiar credenciais."
    exit 1
}

if [ -f "$CRED_DIR/config" ]; then
    scp -q "${SSH_OPTS[@]}" "$CRED_DIR/config" "$SSH_USER@$IP:$REMOTE_HOME/.aws/config"
fi

ssh "${SSH_OPTS[@]}" "$SSH_USER@$IP" "chmod 600 $REMOTE_HOME/.aws/credentials"

ssh "${SSH_OPTS[@]}" "$SSH_USER@$IP"
