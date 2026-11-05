#!/bin/bash

# ============================================================
# ansible-config.sh - ambiente Ansible do CloudShell
#
# O Ansible nao e instalado no $HOME: ele vive num virtualenv
# em /tmp/fiap/ansible_venv ($ANSIBLE_VENV), porque o CloudShell
# so preserva o $HOME (cota de 1 GB) e o venv instalado passa de
# 500 MB (sao ~50 MB de download).
# O preco e o /tmp ser apagado entre sessoes -- e ai o venv tem
# de ser recriado, o que a ensure_ansible() da lib faz.
#
# Antes nao havia comando proprio para isso: o venv so era
# recriado de carona (prepare_tools) dentro do init.sh, do
# criar.sh e do ansible.sh. Quando o venv quebrava -- pip
# interrompido, /tmp apagado no meio de um apply -- nao havia
# como consertar sem recriar a infraestrutura inteira.
#
# Uso:
#   ansible-config.sh                  menu interativo
#   ansible-config.sh --status         diagnostico (nao instala nada)
#   ansible-config.sh --garantir       instala se faltar (idempotente)
#   ansible-config.sh --recriar        apaga e recria o venv do zero
#   ansible-config.sh --dump           ansible-config dump --only-changed
#   ansible-config.sh --ping [projeto] ansible -m ping nas VMs do projeto
#   ansible-config.sh --ajuda
# ============================================================

# Localiza o proprio diretorio (bin/) para achar a lib e os
# scripts irmaos, sem depender de copias no $HOME.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

# So o /tmp (rapido): define PATH, ANSIBLE_* e cria os diretorios.
# NAO instala nada -- o --status precisa poder dizer "faltando".
prepare_tmp_environment

PROJETO_DEFAULT="$(cfg_get LAST_PROJECT)"
[ -n "$PROJETO_DEFAULT" ] || PROJETO_DEFAULT="ubuntu-vm"


# ============================================================
# STATUS : diagnostico do ambiente
# ============================================================

ac_status() {

    local VENV_OK=0

    echo ""
    echo "========================================"
    echo " AMBIENTE ANSIBLE"
    echo "========================================"
    echo ""
    echo "Virtualenv : $ANSIBLE_VENV"

    if [ -d "$ANSIBLE_VENV" ]; then
        echo "Tamanho    : $(du -sh "$ANSIBLE_VENV" 2>/dev/null | cut -f1)"
    else
        echo "Tamanho    : (diretório não existe)"
    fi

    echo "Inventários: $INVENTORY_DIR"
    echo ""

    # ------------------------------------------------------------
    # Binarios
    # ------------------------------------------------------------

    if [ -x "$ANSIBLE_VENV/bin/ansible" ] && \
       [ -x "$ANSIBLE_VENV/bin/ansible-playbook" ]; then
        VENV_OK=1
        echo "✅ ansible e ansible-playbook presentes no venv."
    else
        echo "❌ venv incompleto (ansible/ansible-playbook ausentes)."
    fi

    echo ""
    echo "python3    : $(python3 --version 2>&1 | head -1)"

    if [ "$VENV_OK" -eq 1 ]; then
        echo "ansible    : $("$ANSIBLE_VENV/bin/ansible" --version 2>/dev/null | head -1)"
        echo "core       : $("$ANSIBLE_VENV/bin/python" -c \
            'import ansible; print(ansible.__version__)' 2>/dev/null)"
    else
        echo "ansible    : (não instalado)"
    fi

    # ------------------------------------------------------------
    # PATH e variaveis exportadas pela lib
    # ------------------------------------------------------------

    echo ""
    case ":$PATH:" in
        *":$ANSIBLE_VENV/bin:"*) echo "PATH       : venv no PATH ✅" ;;
        *)                       echo "PATH       : venv FORA do PATH ❌" ;;
    esac

    echo "ANSIBLE_HOST_KEY_CHECKING  = ${ANSIBLE_HOST_KEY_CHECKING:-(vazio)}"
    echo "ANSIBLE_PYTHON_INTERPRETER = ${ANSIBLE_PYTHON_INTERPRETER:-(vazio)}"

    # ------------------------------------------------------------
    # Chave SSH usada nos playbooks
    # ------------------------------------------------------------

    echo ""
    if [ -f "$ENV_DIR/labsuser.pem" ]; then
        echo "✅ Chave SSH: $ENV_DIR/labsuser.pem"
    else
        echo "❌ Chave SSH ausente: $ENV_DIR/labsuser.pem"
        echo "   Baixe a labsuser.pem do AWS Academy para ~/environment."
    fi

    # ------------------------------------------------------------
    # Inventarios ja gerados (um por projeto/lote)
    # ------------------------------------------------------------

    echo ""
    if compgen -G "$INVENTORY_DIR/*.hosts" >/dev/null 2>&1; then
        echo "Inventários gerados:"
        local F
        for F in "$INVENTORY_DIR"/*.hosts; do
            printf '   %-28s %s host(s)\n' \
                "$(basename "$F")" \
                "$(grep -c 'ansible_ssh_host' "$F" 2>/dev/null)"
        done
    else
        echo "Nenhum inventário gerado ainda (rode criar.sh/ajustar-varias.sh)."
    fi

    echo ""

    [ "$VENV_OK" -eq 1 ] || return 1
    return 0
}


# ============================================================
# GARANTIR : instala so se faltar (idempotente)
# ============================================================

ac_garantir() {

    echo ""
    echo ">> Verificando o Ansible..."

    ensure_ansible || {
        echo ""
        echo "❌ Não foi possível preparar o Ansible."
        echo ""
        echo "   Verifique a conexão de rede do CloudShell e tente de novo."
        echo ""
        return 1
    }

    echo ""
    echo "✅ Ansible pronto: $("$ANSIBLE_VENV/bin/ansible" --version 2>/dev/null | head -1)"
    echo ""

    return 0
}


# ============================================================
# RECRIAR : apaga o venv e instala do zero
#
# A ensure_ansible() sai na hora se o venv estiver ok, entao a
# recriacao forcada passa por apagar o diretorio antes.
# ============================================================

ac_recriar() {

    echo ""
    echo "========================================"
    echo " RECRIAR AMBIENTE VIRTUAL DO ANSIBLE"
    echo "========================================"
    echo ""
    echo "Vai apagar e reinstalar:"
    echo ""
    echo "   $ANSIBLE_VENV"
    echo ""
    echo "Baixa ~50 MB (pip install ansible), ocupa ~500 MB no /tmp"
    echo "e leva 1-2 minutos."
    echo "Não afeta a infraestrutura na AWS nem o state do Terraform."
    echo ""

    if [ -z "$FIAPLAB_YES" ]; then
        local CONFIRMA
        read -rp "Confirma recriar? (s/N): " CONFIRMA
        [[ "$CONFIRMA" =~ ^[Ss]$ ]] || { echo "Cancelado."; return 0; }
    fi

    rm -rf "$ANSIBLE_VENV"

    # Recria o diretorio e reexporta PATH/ANSIBLE_* apagados com ele.
    prepare_tmp_environment

    ac_garantir
}


# ============================================================
# DUMP : configuracao efetiva do Ansible
# ============================================================

ac_dump() {

    ensure_ansible || return 1

    echo ""
    echo "========================================"
    echo " CONFIGURAÇÃO EFETIVA DO ANSIBLE"
    echo "========================================"
    echo ""
    echo "(apenas o que difere do padrão)"
    echo ""

    "$ANSIBLE_VENV/bin/ansible-config" dump --only-changed

    echo ""

    return 0
}


# ============================================================
# PING : testa a conexao com as VMs do projeto
#
# Usa o mesmo inventario dos playbooks (gerado do state), para
# o teste valer o que o ansible-playbook vai encontrar.
# ============================================================

ac_ping() {

    local PROJETO="${1:-$PROJETO_DEFAULT}"
    local TF_DIR="$CONFIG_DIR/$PROJETO"

    if [ ! -d "$TF_DIR" ]; then
        echo ""
        echo "❌ Projeto não encontrado:"
        echo "   $TF_DIR"
        echo ""
        return 1
    fi

    ensure_ansible || return 1
    ensure_terraform || return 1
    aws_require || return 1
    tf_ensure_init "$PROJETO" || return 1

    local KEY="$ENV_DIR/labsuser.pem"

    if [ ! -f "$KEY" ]; then
        echo ""
        echo "❌ Chave SSH não encontrada: $KEY"
        echo ""
        return 1
    fi

    if ! tf_write_inventory "$PROJETO"; then
        echo ""
        echo "❌ Nenhuma VM no state do projeto '$PROJETO'."
        echo ""
        echo "   Crie a infraestrutura antes (criar.sh / criar-varias.sh)."
        echo ""
        return 1
    fi

    echo ""
    echo "========================================"
    echo " ANSIBLE PING ($PROJETO)"
    echo "========================================"
    echo ""
    cat "$INVENTORY_FILE"
    echo ""

    "$ANSIBLE_VENV/bin/ansible" nodes \
        -i "$INVENTORY_FILE" \
        -u ubuntu \
        --key-file "$KEY" \
        -m ping

    local RC=$?

    echo ""

    if [ "$RC" -eq 0 ]; then
        echo "✅ Todas as VMs responderam."
    else
        echo "❌ Alguma VM não respondeu."
        echo ""
        echo "   Causas comuns: VM suspensa (opção 1 do menu liga),"
        echo "   IP trocado após religar (ajustar-varias.sh atualiza)"
        echo "   ou sshd ainda subindo."
    fi

    echo ""

    return "$RC"
}


# ============================================================
# AJUDA
# ============================================================

ac_ajuda() {
    # Imprime o bloco "Uso:" do cabecalho deste arquivo, sem o "# ",
    # para a ajuda nunca divergir do codigo.
    sed -n '/^# Uso:/,/^# =\{10,\}/p' "${BASH_SOURCE[0]}" |
        grep -v '^# =' |
        sed 's/^# \{0,1\}//'
}


# ============================================================
# LINHA DE COMANDO
# ============================================================

case "$1" in

    --status|-s|status)
        ac_status
        exit $?
        ;;

    --garantir|-g|garantir)
        ac_garantir
        exit $?
        ;;

    --recriar|-r|recriar)
        ac_recriar
        exit $?
        ;;

    --dump|-d|dump)
        ac_dump
        exit $?
        ;;

    --ping|-p|ping)
        ac_ping "$2"
        exit $?
        ;;

    --ajuda|-h|--help|ajuda)
        ac_ajuda
        exit 0
        ;;

    "")
        ;;   # segue para o menu

    *)
        echo ""
        echo "❌ Opção desconhecida: $1"
        echo ""
        ac_ajuda
        exit 1
        ;;
esac


# ============================================================
# MENU INTERATIVO
# ============================================================

while true; do

    # O CloudShell pode ter limpado o /tmp entre as voltas do menu.
    prepare_tmp_environment >/dev/null 2>&1

    echo ""
    echo "========================================"
    echo " ANSIBLE - AMBIENTE"
    echo "========================================"

    if [ -x "$ANSIBLE_VENV/bin/ansible" ]; then
        echo "Status: ✅ instalado  ($("$ANSIBLE_VENV/bin/ansible" --version 2>/dev/null | head -1))"
    else
        echo "Status: ❌ não instalado  ($ANSIBLE_VENV)"
    fi

    echo "========================================"
    echo ""
    echo "1) Diagnóstico completo"
    echo "2) Instalar/garantir o Ansible (idempotente)"
    echo "3) Recriar o ambiente virtual do zero"
    echo "4) Mostrar configuração efetiva (ansible-config dump)"
    echo "5) Testar conexão com as VMs (ansible -m ping)"
    echo "0) Sair"
    echo ""

    read -rp "Escolha uma opção: " OPCAO

    case "$OPCAO" in

        1) ac_status ;;

        2) ac_garantir ;;

        3) ac_recriar ;;

        4) ac_dump ;;

        5)
            echo ""
            read -rp "Projeto [$PROJETO_DEFAULT]: " P
            ac_ping "${P:-$PROJETO_DEFAULT}"
            ;;

        0)
            echo ""
            echo "Saindo..."
            exit 0
            ;;

        *)
            echo ""
            echo "❌ Opção inválida."
            ;;
    esac

    echo ""
    read -rp "Pressione ENTER para continuar..."

done
