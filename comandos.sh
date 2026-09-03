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
# .fiaplab.lib.sh  -  biblioteca comum
#
# Gerada primeiro: todos os demais scripts a carregam com
# "source". Antes desta lib, o bloco de credenciais estava
# copiado em 6 scripts e ausente em outros 2.
# ============================================================

cat > "$HOME_DIR/.fiaplab.lib.sh" <<'LIBEOF'
#!/bin/bash

# ============================================================
# FIAP LAB - BIBLIOTECA COMUM
#
# Carregada por todos os scripts:
#
#     source "$HOME/.fiaplab.lib.sh"
#
# Concentra o que antes estava copiado em 6 scripts (e ausente
# em outros 2, ja tendo divergido entre eles):
#
#   - credenciais AWS
#   - descoberta e cache do account id
#   - preparo do /tmp, que o CloudShell apaga entre sessoes
#   - terraform init
#
# Nao usa "set -e": os scripts tratam RC explicitamente.
# ============================================================

FIAPLAB_CFG="$HOME/.fiaplab"

ENV_DIR="$HOME/environment"
CONFIG_DIR="$ENV_DIR/config"
CRED_DIR="$ENV_DIR/credenciais"

TMP_APP_DIR="/tmp/fiap"
TF_CACHE="$TMP_APP_DIR/tf_cache"
TF_PROJECTS="$TMP_APP_DIR/tf_projects"
ANSIBLE_VENV="$TMP_APP_DIR/ansible_venv"

# Inventarios do Ansible ficam fora do clone do repositorio config:
# antes, cada ajustar.sh gravava um inv.hosts dentro da propria pasta
# versionada do projeto.
INVENTORY_DIR="$TMP_APP_DIR/inventory"

INVENTORY_FILE=""

TERRAFORM_VERSION="1.16.0"

AWS_REGION="${AWS_REGION:-us-east-1}"

ACCOUNT_ID=""
BUCKET_NAME=""


# ============================================================
# CACHE PERSISTENTE  (~/.fiaplab)
#
# O $HOME sobrevive entre sessoes do CloudShell; o /tmp nao.
# Guardamos aqui o que e caro ou impossivel de redescobrir com
# a credencial vencida -- em especial o account id, do qual o
# nome do bucket de state e derivado.
# ============================================================

cfg_get() {

    [ -f "$FIAPLAB_CFG" ] || return 1

    sed -n "s/^$1=//p" "$FIAPLAB_CFG" | tail -1
}

cfg_set() {

    local TMP

    touch "$FIAPLAB_CFG" 2>/dev/null || return 1

    # Reescrita atomica em vez de "sed -i": evita a diferenca de
    # sintaxe entre GNU e BSD e nao deixa o arquivo truncado se a
    # sessao cair no meio da escrita.
    TMP=$(mktemp) || return 1

    grep -v "^$1=" "$FIAPLAB_CFG" > "$TMP" 2>/dev/null

    printf '%s=%s\n' "$1" "$2" >> "$TMP"

    mv "$TMP" "$FIAPLAB_CFG" || return 1

    chmod 600 "$FIAPLAB_CFG" 2>/dev/null

    return 0
}


# ============================================================
# ARQUIVO ESTATICO DE CREDENCIAIS
#
# Le o endpoint de credenciais do CloudShell e materializa o
# par credentials/config.
#
# ATENCAO: este arquivo NAO e a fonte de credenciais do CLI.
# Ele existe por um motivo so -- o conectar.sh e o ajustar.sh
# precisam de um arquivo para copiar via scp para dentro da VM.
# ============================================================

aws_write_credentials_file() {

    [ -n "$AWS_CONTAINER_CREDENTIALS_FULL_URI" ] || return 1
    [ -n "$AWS_CONTAINER_AUTHORIZATION_TOKEN" ]  || return 1

    local CREDS KEY SECRET TOKEN

    CREDS=$(curl -s --max-time 5 \
        -H "Authorization: $AWS_CONTAINER_AUTHORIZATION_TOKEN" \
        "$AWS_CONTAINER_CREDENTIALS_FULL_URI" 2>/dev/null)

    [ -n "$CREDS" ] || return 1

    KEY=$(printf '%s' "$CREDS"    | jq -r '.AccessKeyId // empty'     2>/dev/null)
    SECRET=$(printf '%s' "$CREDS" | jq -r '.SecretAccessKey // empty' 2>/dev/null)
    TOKEN=$(printf '%s' "$CREDS"  | jq -r '.Token // empty'           2>/dev/null)

    [ -n "$KEY" ] || return 1

    mkdir -p "$CRED_DIR" || return 1
    chmod 700 "$CRED_DIR" 2>/dev/null

    (
        umask 077

        printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\naws_session_token = %s\n' \
            "$KEY" "$SECRET" "$TOKEN" > "$CRED_DIR/credentials"

        printf '[default]\nregion = %s\noutput = json\n' \
            "$AWS_REGION" > "$CRED_DIR/config"
    )

    return 0
}


# ============================================================
# aws_login : garante credencial valida AGORA
#
# O CloudShell expoe um provedor de credenciais que se renova
# sozinho (AWS_CONTAINER_CREDENTIALS_FULL_URI). Os scripts
# antigos exportavam AWS_SHARED_CREDENTIALS_FILE apontando para
# um snapshot gravado la no init.sh -- e como o arquivo tem
# precedencia sobre o provedor nativo, isso DESLIGAVA a renovacao
# automatica e produzia o ExpiredToken depois de algum tempo.
#
# Ordem adotada aqui:
#
#   1) provedor nativo do CloudShell   (renova sozinho)
#   2) arquivo estatico recem-gerado   (fallback)
#
# Assim um "terraform apply" longo renova a credencial no meio
# do caminho, coisa que o arquivo estatico nunca faria.
# ============================================================

aws_login() {

    export AWS_DEFAULT_REGION="$AWS_REGION"
    export AWS_EC2_METADATA_DISABLED=true

    # Sempre materializa um arquivo fresco: e o insumo do scp.
    aws_write_credentials_file

    if [ -f "$CRED_DIR/config" ]; then
        export AWS_CONFIG_FILE="$CRED_DIR/config"
    fi

    # 1) Provedor nativo: nao fixar arquivo.
    if [ -n "$AWS_CONTAINER_CREDENTIALS_FULL_URI" ]; then

        unset AWS_SHARED_CREDENTIALS_FILE

        if aws sts get-caller-identity >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 2) Fallback: arquivo estatico.
    if [ -f "$CRED_DIR/credentials" ]; then

        export AWS_SHARED_CREDENTIALS_FILE="$CRED_DIR/credentials"

        if aws sts get-caller-identity >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}


# ============================================================
# aws_require : porta de entrada de toda operacao AWS
#
# Chamado imediatamente antes de cada operacao, nao no boot.
# ============================================================

aws_require() {

    aws_login && return 0

    echo ""
    echo "========================================"
    echo " SESSAO AWS EXPIRADA"
    echo "========================================"
    echo ""
    echo "As credenciais temporarias do laboratorio venceram."
    echo ""
    echo "O que fazer:"
    echo ""
    echo "  1. Volte ao AWS Academy e clique em 'Start Lab'"
    echo "     (aguarde o circulo ficar VERDE)."
    echo ""
    echo "  2. Feche esta aba do CloudShell e abra novamente."
    echo ""
    echo "  3. Execute:  ~/fiaplab.sh"
    echo ""
    echo "Sua infraestrutura na AWS nao foi perdida."
    echo ""

    return 1
}


# ============================================================
# get_account_id : online, com fallback no cache
#
# O nome do bucket de state deriva do account id. Com o cache,
# o menu continua sabendo onde esta o state mesmo com a
# credencial vencida, em vez de morrer no boot.
# ============================================================

get_account_id() {

    local ID

    ID=$(aws sts get-caller-identity \
        --query Account \
        --output text 2>/dev/null)

    if [[ "$ID" =~ ^[0-9]{12}$ ]]; then
        cfg_set ACCOUNT_ID "$ID"
    else
        ID=$(cfg_get ACCOUNT_ID)
    fi

    [[ "$ID" =~ ^[0-9]{12}$ ]] || return 1

    ACCOUNT_ID="$ID"
    BUCKET_NAME="tfstate-cloudshell-${ACCOUNT_ID}"

    cfg_set BUCKET_NAME "$BUCKET_NAME"
    cfg_set AWS_REGION "$AWS_REGION"

    return 0
}


# ============================================================
# AMBIENTE TEMPORARIO
#
# O CloudShell preserva o $HOME (1 GB) e apaga o /tmp entre
# sessoes. Terraform e Ansible ficam no /tmp de proposito, para
# nao consumir a cota do $HOME.
# ============================================================

prepare_tmp_environment() {

    mkdir -p "$TF_CACHE" "$TF_PROJECTS" "$ANSIBLE_VENV" "$INVENTORY_DIR"

    export TF_PLUGIN_CACHE_DIR="$TF_CACHE"

    case ":$PATH:" in
        *":$ANSIBLE_VENV/bin:"*) ;;
        *) export PATH="$ANSIBLE_VENV/bin:$PATH" ;;
    esac

    export ANSIBLE_PYTHON_INTERPRETER=auto_silent
    export ANSIBLE_DEPRECATION_WARNINGS=false
    export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false

    printf 'plugin_cache_dir = "%s"\ndisable_checkpoint = true\n' \
        "$TF_CACHE" > "$HOME/.terraformrc"
}


# ============================================================
# LINKS .terraform DOS PROJETOS
# ============================================================

prepare_terraform_projects() {

    [ -d "$CONFIG_DIR" ] || return 0

    local SUBDIR PROJECT TMP_TF_DATA

    for SUBDIR in "$CONFIG_DIR"/*; do

        [ -d "$SUBDIR" ] || continue

        find "$SUBDIR" -maxdepth 1 -type f -name "*.tf" |
            grep -q . || continue

        PROJECT=$(basename "$SUBDIR")
        TMP_TF_DATA="$TF_PROJECTS/$PROJECT"

        mkdir -p "$TMP_TF_DATA"

        if [ -d "$SUBDIR/.terraform" ] && [ ! -L "$SUBDIR/.terraform" ]; then
            rm -rf "$SUBDIR/.terraform"
        fi

        if [ ! -L "$SUBDIR/.terraform" ]; then
            ln -s "$TMP_TF_DATA" "$SUBDIR/.terraform"
        fi

    done
}


# ============================================================
# TERRAFORM
# ============================================================

ensure_terraform() {

    command -v terraform >/dev/null 2>&1 && return 0

    echo ""
    echo ">> Instalando Terraform ${TERRAFORM_VERSION}..."
    echo ""

    local ZIP="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    local URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${ZIP}"

    # Subshell: o "cd /tmp" solto que existia aqui mudava o
    # diretorio corrente do fiaplab.sh inteiro.
    (
        cd /tmp || exit 1

        rm -f "$ZIP" terraform

        curl -fsSL -o "$ZIP" "$URL" || exit 1
        unzip -o -q "$ZIP"          || exit 1

        sudo install terraform /usr/local/bin/terraform || exit 1

        rm -f terraform "$ZIP"
    )

    if [ "$?" -ne 0 ]; then
        echo ""
        echo "Nao foi possivel instalar o Terraform ${TERRAFORM_VERSION}."
        echo "Verifique a conexao de rede e tente novamente."
        echo ""
        return 1
    fi

    echo ""
    terraform version | head -1

    return 0
}


# ============================================================
# ANSIBLE
# ============================================================

ensure_ansible() {

    if [ -x "$ANSIBLE_VENV/bin/ansible" ] && \
       [ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then
        return 0
    fi

    echo ""
    echo ">> Recriando ambiente virtual do Ansible..."
    echo ""

    rm -rf "$ANSIBLE_VENV"

    python3 -m venv "$ANSIBLE_VENV" || {
        echo "Nao foi possivel criar o ambiente virtual."
        return 1
    }

    "$ANSIBLE_VENV/bin/pip" install --no-cache-dir ansible || {
        echo "Nao foi possivel instalar o Ansible."
        return 1
    }

    export PATH="$ANSIBLE_VENV/bin:$PATH"

    return 0
}


# ============================================================
# prepare_tools : reconstroi o /tmp apagado pelo CloudShell
# ============================================================

prepare_tools() {

    prepare_tmp_environment
    ensure_terraform || return 1
    ensure_ansible   || return 1
    prepare_terraform_projects

    return 0
}


# ============================================================
# TERRAFORM INIT
#
# tf_ensure_init resolve o sintoma mais comum do lab: o aluno
# fecha e reabre o CloudShell, o /tmp e apagado, o .terraform
# (symlink para /tmp) fica vazio e as opcoes ligar/suspender/
# conectar/ip passam a falhar com "Backend initialization
# required" ate ele rodar "Criar infraestrutura" de novo.
# ============================================================

tf_init() {

    local PROJECT="$1"
    local TF_DIR="$CONFIG_DIR/$PROJECT"

    [ -n "$BUCKET_NAME" ] || get_account_id || return 1

    terraform -chdir="$TF_DIR" init -reconfigure -input=false \
        -backend-config="bucket=$BUCKET_NAME" \
        -backend-config="key=${PROJECT}/terraform.tfstate" \
        -backend-config="region=$AWS_REGION" \
        -backend-config="use_lockfile=true"
}

tf_ensure_init() {

    local PROJECT="$1"
    local TF_DIR="$CONFIG_DIR/$PROJECT"

    if [ -d "$TF_DIR/.terraform/providers" ] && \
       [ -f "$TF_DIR/.terraform/terraform.tfstate" ]; then
        return 0
    fi

    echo ""
    echo ">> Reconstruindo ambiente Terraform"
    echo "   (o CloudShell apaga o /tmp entre sessoes)..."
    echo ""

    tf_init "$PROJECT" >/dev/null 2>&1 && return 0

    # Repete sem silenciar para o erro real aparecer.
    tf_init "$PROJECT"
}


# ============================================================
# INSTANCIAS DO STATE
#
# Le os IDs direto do state. Os scripts antigos rodavam
# "terraform refresh" (deprecado) so para listar IDs -- uma ida
# a AWS de varios segundos para obter dados que nao mudam.
# ============================================================

tf_instance_ids() {

    local PROJECT="$1"
    local TF_DIR="$CONFIG_DIR/$PROJECT"

    terraform -chdir="$TF_DIR" show -json 2>/dev/null |
        jq -r '.. | objects | select(.type? == "aws_instance") | .instances[]? | .attributes.id? // empty' \
        2>/dev/null
}

tf_public_ips() {

    local PROJECT="$1"
    local TF_DIR="$CONFIG_DIR/$PROJECT"

    terraform -chdir="$TF_DIR" output -json 2>/dev/null |
        jq -r '.ip_externo.value? | if type == "string" then . else (.. | strings) end' \
        2>/dev/null
}


# ============================================================
# INVENTARIO ANSIBLE
#
# Monta o inventario a partir dos IPs do state e grava em
# /tmp/fiap/inventory, nunca dentro do clone do config.
#
# Define INVENTORY_FILE com o caminho gerado.
# ============================================================

tf_write_inventory() {

    local PROJECT="$1"
    local DEST="${2:-$INVENTORY_DIR/${PROJECT}.hosts}"
    local IPS I

    # O grep descarta linhas em branco: sem ele um output vazio
    # geraria um host sem endereco no inventario.
    mapfile -t IPS < <(tf_public_ips "$PROJECT" | grep -v '^[[:space:]]*$')

    if [ "${#IPS[@]}" -eq 0 ]; then
        INVENTORY_FILE=""
        return 1
    fi

    mkdir -p "$(dirname "$DEST")" || return 1

    {
        echo "[nodes]"
        for I in "${!IPS[@]}"; do
            printf 'node%s ansible_ssh_host=%s\n' "$I" "${IPS[$I]}"
        done
    } > "$DEST" || return 1

    INVENTORY_FILE="$DEST"

    return 0
}
LIBEOF

chmod 600 "$HOME_DIR/.fiaplab.lib.sh"


# ============================================================
# criar.sh
# ============================================================

cat > "$HOME_DIR/criar.sh" <<'EOF'
#!/bin/bash

source "$HOME/.fiaplab.lib.sh"

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

EOF

chmod +x "$HOME_DIR/criar.sh"


# ============================================================
# destruir.sh
# ============================================================

cat > "$HOME_DIR/destruir.sh" <<'EOF'
#!/bin/bash

source "$HOME/.fiaplab.lib.sh"

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

    cat > "$TF_DIR/backend.tf" <<EOF2
terraform {
  backend "s3" {}
}
EOF2

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

terraform -chdir="$TF_DIR" destroy -auto-approve

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

source "$HOME/.fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/status.sh <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

aws_require || exit 1

tf_ensure_init "$PROJECT" || exit 1

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

source "$HOME/.fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/ip <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

aws_require || exit 1

tf_ensure_init "$PROJECT" || exit 1

echo ""
echo "Atualizando state..."
echo ""

terraform -chdir="$TF_DIR" apply -refresh-only -auto-approve -input=false

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform refresh terminou com erro."
    exit "$RC"
fi

echo ""
echo "IPs externos:"
echo ""

tf_public_ips "$PROJECT"
EOF

chmod +x "$HOME_DIR/ip"


# ============================================================
# ligar.sh
# ============================================================

cat > "$HOME_DIR/ligar.sh" <<'EOF'
#!/bin/bash

source "$HOME/.fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/ligar.sh <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

aws_require || exit 1

tf_ensure_init "$PROJECT" || exit 1

echo ""
echo "========================================"
echo " LIGAR VM(S)"
echo "========================================"
echo ""

# Os IDs de instancia nao mudam: basta ler o state, sem a ida
# a AWS que o "terraform refresh" (deprecado) fazia aqui.
mapfile -t IDS < <(tf_instance_ids "$PROJECT" | grep -v '^[[:space:]]*$')

if [ "${#IDS[@]}" -eq 0 ]; then
    echo "❌ Nenhuma instância encontrada no Terraform."
    echo ""
    echo "Use primeiro a opção:  1) Criar infraestrutura"
    echo ""
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

source "$HOME/.fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/suspender.sh <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado: $PROJECT"
    exit 1
fi

aws_require || exit 1

tf_ensure_init "$PROJECT" || exit 1

echo ""
echo "========================================"
echo " SUSPENDER VM(S)"
echo "========================================"
echo ""

# Os IDs de instancia nao mudam: basta ler o state, sem a ida
# a AWS que o "terraform refresh" (deprecado) fazia aqui.
mapfile -t IDS < <(tf_instance_ids "$PROJECT" | grep -v '^[[:space:]]*$')

if [ "${#IDS[@]}" -eq 0 ]; then
    echo "❌ Nenhuma instância encontrada no Terraform."
    echo ""
    echo "Use primeiro a opção:  1) Criar infraestrutura"
    echo ""
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

source "$HOME/.fiaplab.lib.sh"

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

tf_ensure_init "$PROJECT" || exit 1

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

terraform -chdir="$TF_DIR" apply -refresh-only -auto-approve -input=false

RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "❌ Terraform refresh terminou com erro."
    exit "$RC"
fi

mapfile -t IPS < <(tf_public_ips "$PROJECT" | grep -v '^[[:space:]]*$')

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

if [ -f "$CRED_DIR/config" ]; then
    scp -q -o LogLevel=error -o StrictHostKeyChecking=no -i "$KEY" \
        "$CRED_DIR/config" \
        ubuntu@"$IP":/home/ubuntu/.aws/config
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

source "$HOME/.fiaplab.lib.sh"

PROJECT="$1"

if [ -z "$PROJECT" ]; then
    echo "Uso: ~/ansible.sh <projeto>"
    exit 1
fi

TF_DIR="$CONFIG_DIR/$PROJECT"

if [ ! -d "$TF_DIR" ]; then
    echo "❌ Projeto não encontrado:"
    echo "   $TF_DIR"
    exit 1
fi

# O /tmp pode ter sido apagado pelo CloudShell: a lib reconstroi
# o venv em vez de mandar o aluno reiniciar o menu.
prepare_tmp_environment

ensure_ansible || exit 1

aws_require || exit 1

tf_ensure_init "$PROJECT" || exit 1

echo ""
echo "========================================"
echo " ANSIBLE"
echo "========================================"
echo "Projeto : $PROJECT"
echo ""

# ------------------------------------------------------------
# 1) ajustar.sh do projeto
#
# E o caminho canonico de configuracao: monta o inventario com
# os IPs reais das VMs e roda a sequencia de playbooks correta.
# Antes, esta opcao so procurava *.yml dentro da pasta do projeto
# -- e o ubuntu-vm nao tem nenhum, entao a opcao 5 do menu nunca
# funcionava justamente no projeto principal.
# ------------------------------------------------------------

AJUSTAR="$TF_DIR/ajustar.sh"

if [ -f "$AJUSTAR" ]; then

    echo ">> Executando ajustar.sh do projeto..."
    echo ""

    export FIAPLAB_INVENTORY="$INVENTORY_DIR/${PROJECT}.hosts"

    mkdir -p "$INVENTORY_DIR"

    bash "$AJUSTAR"

    RC=$?

    echo ""

    if [ "$RC" -eq 0 ]; then
        echo "✅ Configuração concluída."
    else
        echo "❌ Configuração terminou com erro."
    fi

    exit "$RC"
fi

# ------------------------------------------------------------
# 2) Playbooks proprios do projeto
#
# O inventario e montado a partir do state, apontando para as
# VMs. Antes usava-se $CONFIG_DIR/hosts, que e o inventario
# local do CloudShell: os playbooks rodariam contra o proprio
# CloudShell, e nao contra a VM do aluno.
# ------------------------------------------------------------

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
    echo "❌ O projeto '$PROJECT' não possui ajustar.sh nem playbooks."
    echo ""
    echo "   $TF_DIR"
    echo ""
    exit 1
fi

if [ "${#PLAYBOOKS[@]}" -eq 1 ]; then

    PLAYBOOK="${PLAYBOOKS[0]}"

else

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

if ! tf_write_inventory "$PROJECT"; then
    echo "❌ Nenhuma VM encontrada no state do projeto."
    echo ""
    echo "Use primeiro a opção:  1) Criar infraestrutura"
    echo ""
    exit 1
fi

KEY="$ENV_DIR/labsuser.pem"

if [ ! -f "$KEY" ]; then
    echo "❌ Chave SSH não encontrada: $KEY"
    exit 1
fi

echo "Playbook: $(basename "$PLAYBOOK")"
echo "Inventário:"
cat "$INVENTORY_FILE"
echo ""

ansible-playbook \
    -i "$INVENTORY_FILE" \
    -u ubuntu \
    --key-file "$KEY" \
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

# A lib traz: credenciais, account id, /tmp, terraform e ansible.
# Antes, estas ~200 linhas viviam duplicadas aqui e nos demais
# scripts, ja com divergencias entre as copias.
source "$HOME/.fiaplab.lib.sh"

CURRENT_PROJECT=""

S3_PROJECTS=()
LOCAL_PROJECTS=()

# ok | expirado | sem_bucket | sem_conta | erro
S3_STATUS="ok"


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
    S3_STATUS="ok"

    if [ -z "$BUCKET_NAME" ]; then
        S3_STATUS="sem_conta"
        return 1
    fi

    local S3_JSON S3_ERR

    # O erro era silenciado com 2>/dev/null e o array vazio fazia o
    # menu dizer "nenhum projeto no S3" -- inclusive quando o motivo
    # era token vencido, mandando o aluno recriar infra que existe.
    S3_ERR=$(aws s3api list-objects-v2 \
        --bucket "$BUCKET_NAME" \
        --output json 2>&1 >"$TMP_APP_DIR/s3.json")

    if [ "$?" -ne 0 ]; then

        case "$S3_ERR" in
            *ExpiredToken*|*InvalidClientTokenId*|*RequestExpired*)
                S3_STATUS="expirado" ;;
            *NoSuchBucket*|*NotFound*|*404*)
                S3_STATUS="sem_bucket" ;;
            *)
                S3_STATUS="erro" ;;
        esac

        return 1
    fi

    S3_JSON=$(cat "$TMP_APP_DIR/s3.json" 2>/dev/null)

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
    echo "Conta AWS     : ${ACCOUNT_ID:-desconhecida}"

    if [ -n "$CURRENT_PROJECT" ]; then
        echo "Projeto atual : $CURRENT_PROJECT"
        echo "State         : s3://$BUCKET_NAME/$CURRENT_PROJECT"
    else
        echo "Projeto atual : nenhum"
        echo "State         : nenhum projeto selecionado"
    fi

    case "$S3_STATUS" in
        expirado)
            echo "----------------------------------------"
            echo "Credencial    : VENCIDA"
            echo ""
            echo "Clique em 'Start Lab' no AWS Academy e"
            echo "reabra o CloudShell. A infraestrutura na"
            echo "AWS continua intacta."
            ;;
        erro)
            echo "----------------------------------------"
            echo "Credencial    : erro ao consultar o S3"
            ;;
    esac

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

    # Renova a credencial na hora da operacao, nao no boot.
    aws_require || return 1

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

prepare_tools || {
    echo ""
    echo "❌ Não foi possível preparar as ferramentas do lab."
    echo ""
    pause_menu
    exit 1
}

aws_require

# O account id vem do cache em ~/.fiaplab quando a chamada online
# falha, entao o menu abre mesmo com credencial vencida: o aluno ve
# o estado do lab e a instrucao do que fazer, em vez de ser expulso.
if ! get_account_id; then

    echo ""
    echo "========================================"
    echo " FIAP LAB"
    echo "========================================"
    echo ""
    echo "Ainda não foi possível identificar a conta AWS."
    echo ""
    echo "Verifique se o laboratório está iniciado no AWS Academy"
    echo "(botão 'Start Lab', círculo verde) e abra o CloudShell"
    echo "novamente."
    echo ""

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

LAST_PROJECT=$(cfg_get LAST_PROJECT)

if [ "${#S3_PROJECTS[@]}" -gt 0 ]; then

    # Retoma o ultimo projeto usado, se ele ainda existir.
    if [ -n "$LAST_PROJECT" ] && \
       project_has_state "$LAST_PROJECT" && \
       project_exists_local "$LAST_PROJECT"; then

        CURRENT_PROJECT="$LAST_PROJECT"

        echo ""
        echo "Projeto retomado: $CURRENT_PROJECT"
        echo ""

    elif ! select_s3_project; then

        echo ""
        echo "⚠️ Existem states no S3, mas nenhum projeto"
        echo "pode ser usado com o código local atual."
        echo ""
        echo "Use a opção 1) Criar infraestrutura."
        echo ""

        CURRENT_PROJECT=""
    fi

elif [ "$S3_STATUS" != "ok" ]; then

    echo ""
    echo "⚠️ Não foi possível listar os projetos no S3."
    echo ""

    CURRENT_PROJECT=""

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

    if [ -n "$CURRENT_PROJECT" ]; then
        cfg_set LAST_PROJECT "$CURRENT_PROJECT"
    fi

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
