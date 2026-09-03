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
