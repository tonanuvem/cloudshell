#!/bin/bash

# ============================================================
# FIAP LAB - MENU (simplificado)
#
# Foco: manter a VM do code-server sempre disponivel ao aluno.
#
# A infraestrutura ja e criada pelo init.sh, entao este menu nao
# recria nem lista/troca projetos. O projeto e fixo (ubuntu-vm,
# retomado do cache ~/.fiaplab).
#
# Sairam do menu, para simplificar: 1) Criar, 5) Ansible,
# 6) Mostrar IP e 8) Trocar projeto. A numeracao das opcoes
# restantes foi mantida (2/3/4/7) para nao confundir quem ja
# conhece o menu antigo.
#
# Os comandos criar/destruir/ansible/status/ip continuam
# instalados e genericos, para uso futuro com as demais subpastas
# do repositorio config.
# ============================================================

source "$HOME/.fiaplab.lib.sh"

# Projeto unico: retomado do cache, com default ubuntu-vm.
CURRENT_PROJECT="$(cfg_get LAST_PROJECT)"
[ -n "$CURRENT_PROJECT" ] || CURRENT_PROJECT="ubuntu-vm"


pause_menu() {
    echo ""
    read -rp "Pressione ENTER para continuar..."
}


# ============================================================
# EXECUTAR UM COMANDO DO PROJETO
# ============================================================

run_operation() {

    local SCRIPT="$1"

    aws_require || return 1

    echo ""

    "$HOME/$SCRIPT" "$CURRENT_PROJECT"

    local RC=$?

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
# DESTRUIR OU REFAZER (submenu da opcao 7)
# ============================================================

destruir_ou_refazer() {

    echo ""
    echo "========================================"
    echo " DESTRUIR OU REFAZER AMBIENTE"
    echo "========================================"
    echo ""
    echo " D) Destruir  - remove a VM e a infraestrutura (não recria)"
    echo " R) Refazer   - destrói e recria o ambiente do zero"
    echo " C) Cancelar"
    echo ""

    local OP CONFIRMA RC

    read -rp "Escolha [D/R/C]: " OP

    case "$OP" in

        [Dd])
            read -rp "Confirma DESTRUIR tudo? (s/N): " CONFIRMA
            [[ "$CONFIRMA" =~ ^[Ss]$ ]] || { echo "Cancelado."; return 0; }

            run_operation "destruir.sh"
            ;;

        [Rr])
            echo ""
            echo "Refazer vai DESTRUIR a VM atual e criar uma nova do zero."
            read -rp "Confirma REFAZER? (s/N): " CONFIRMA
            [[ "$CONFIRMA" =~ ^[Ss]$ ]] || { echo "Cancelado."; return 0; }

            aws_require || return 1

            echo ""
            echo ">> Destruindo ambiente atual..."
            echo ""
            "$HOME/destruir.sh" "$CURRENT_PROJECT"

            echo ""
            echo ">> Recriando ambiente..."
            echo ""
            "$HOME/criar.sh" "$CURRENT_PROJECT"
            RC=$?

            echo ""
            if [ "$RC" -eq 0 ]; then
                cfg_set LAST_PROJECT "$CURRENT_PROJECT"
                echo "========================================"
                echo " ✅ Ambiente recriado."
                echo "========================================"
            else
                echo "========================================"
                echo " ❌ Falha ao recriar o ambiente."
                echo "========================================"
            fi

            return "$RC"
            ;;

        *)
            echo "Cancelado."
            ;;
    esac
}


# ============================================================
# INICIALIZACAO
# ============================================================

prepare_tools || {
    echo ""
    echo "❌ Não foi possível preparar as ferramentas do lab."
    echo ""
    pause_menu
    exit 1
}

aws_require

if ! get_account_id; then
    echo ""
    echo "❌ Não foi possível identificar a conta AWS."
    echo ""
    echo "Verifique se o laboratório está iniciado no AWS Academy"
    echo "('Start Lab', círculo verde) e reabra o CloudShell."
    echo ""
    pause_menu
    exit 1
fi


# ============================================================
# MENU PRINCIPAL
# ============================================================

while true; do

    # O CloudShell pode ter limpado o /tmp entre sessoes.
    prepare_tools >/dev/null 2>&1

    echo ""
    echo "========================================"
    echo " FIAP LAB"
    echo "========================================"
    echo "Conta AWS   : ${ACCOUNT_ID:-desconhecida}"
    echo "Projeto     : $CURRENT_PROJECT"
    echo "----------------------------------------"
    # Status ao vivo via AWS CLI (rapido).
    show_vm_status
    echo "========================================"
    echo ""
    echo "2) Ligar VM"
    echo "3) Suspender VM"
    echo "4) Conectar via SSH"
    echo "7) Destruir ou Refazer ambiente"
    echo "0) Sair"
    echo ""

    read -rp "Escolha uma opção: " OPCAO

    case "$OPCAO" in

        2)
            run_operation "ligar.sh"
            pause_menu
            ;;

        3)
            run_operation "suspender.sh"
            pause_menu
            ;;

        4)
            if aws_require; then
                echo ""
                "$HOME/conectar.sh" "$CURRENT_PROJECT" 1
            fi
            pause_menu
            ;;

        7)
            destruir_ou_refazer
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
