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
# Sairam do menu, para simplificar: Criar, Ansible, Mostrar IP e
# Trocar projeto. As opcoes restantes foram renumeradas de 1 a 4:
# 1) Ligar  2) Suspender  3) Conectar  4) Destruir/Refazer.
#
# Os comandos criar/destruir/ansible/status/ip continuam
# instalados e genericos, para uso futuro com as demais subpastas
# do repositorio config.
# ============================================================

# Localiza o proprio diretorio (bin/) para achar a lib e os
# scripts irmaos, sem depender de copias no $HOME.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BIN_DIR/fiaplab.lib.sh"

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

    "$BIN_DIR/$SCRIPT" "$CURRENT_PROJECT"

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
# DESTRUIR OU REFAZER (submenu da opcao 4)
# ============================================================

destruir_ou_refazer() {

    echo ""
    echo "========================================"
    echo " DESTRUIR OU REFAZER AMBIENTE"
    echo "========================================"
    echo ""
    echo " D) Destruir      - remove a VM e a infraestrutura (não recria)"
    echo " R) Refazer       - destrói e recria o ambiente do zero"
    echo " L) Limpeza geral - ⚠️ remove TODOS os recursos do lab na conta"
    echo " C) Cancelar"
    echo ""

    local OP CONFIRMA RC

    read -rp "Escolha [D/R/L/C]: " OP

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
            "$BIN_DIR/destruir.sh" "$CURRENT_PROJECT"

            echo ""
            echo ">> Recriando ambiente..."
            echo ""
            reset_known_hosts
            "$BIN_DIR/criar.sh" "$CURRENT_PROJECT"
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

        [Ll])
            echo ""
            echo "========================================"
            echo " ⚠️  LIMPEZA GERAL"
            echo "========================================"
            echo ""
            echo "Isto REMOVE TODOS os recursos do laboratório na conta"
            echo "${ACCOUNT_ID:-} — inclusive a VM do code-server e QUALQUER"
            echo "outra EC2/VPC não-default em us-east-1 e us-west-2, além"
            echo "do bucket de state e dos arquivos locais."
            echo ""
            echo "Ação IRREVERSÍVEL."
            echo ""
            read -rp "Para confirmar, digite LIMPAR: " CONFIRMA
            [ "$CONFIRMA" = "LIMPAR" ] || { echo "Cancelado."; return 0; }

            aws_require || return 1

            deep_clean
            RC=$?

            cfg_set LAST_PROJECT "" 2>/dev/null

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

# Boot leve: so prepara o /tmp (rapido). Terraform e Ansible sao
# instalados sob demanda pelas acoes que precisam (criar/destruir/
# refazer), para abrir o menu nao esperar download a cada sessao.
prepare_tmp_environment

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

# Limpa host keys antigas de VMs recriadas antes de qualquer conexao.
reset_known_hosts

while true; do

    # O CloudShell pode ter limpado o /tmp entre sessoes (rapido).
    prepare_tmp_environment >/dev/null 2>&1

    echo ""
    echo "========================================"
    echo " FIAP LAB"
    echo "========================================"
    echo "Conta AWS   : ${ACCOUNT_ID:-desconhecida}"
    echo "----------------------------------------"
    # Status ao vivo via AWS CLI (rapido): VM do lab + EC2 ligadas.
    show_vm_status
    echo "========================================"
    echo ""
    echo "1) Ligar VM"
    echo "2) Suspender VM"
    echo "3) Conectar via SSH"
    echo "4) Destruir ou Refazer ambiente"
    echo "0) Sair"
    echo ""

    read -rp "Escolha uma opção: " OPCAO

    case "$OPCAO" in

        1)
            # Liga so a VM do lab, ciente do estado (sem perguntar
            # numero e sem religar o que ja esta ligado).
            if aws_require; then
                echo ""
                echo "========================================"
                echo " LIGAR VM"
                echo "========================================"
                vm_start
            fi
            pause_menu
            ;;

        2)
            if aws_require; then
                echo ""
                echo "========================================"
                echo " SUSPENDER VM"
                echo "========================================"
                vm_stop
            fi
            pause_menu
            ;;

        3)
            if aws_require; then
                echo ""
                "$BIN_DIR/conectar.sh" "$CURRENT_PROJECT" 1
            fi
            pause_menu
            ;;

        4)
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
