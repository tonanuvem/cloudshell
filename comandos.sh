#!/bin/bash

# ============================================================
# FIAP LAB - INSTALADOR DE COMANDOS
#
# Copia os comandos do FIAP LAB para o $HOME.
#
# Historico: ate a migracao, este script GERAVA cada comando via
# heredoc (eram ~2000 linhas de shell dentro de shell). Agora os
# comandos sao arquivos reais em bin/ -- versionaveis, com
# highlight, verificaveis por shellcheck e com git diff legivel.
# Este script apenas os instala.
#
# Instala:
#
#   bin/fiaplab.lib.sh -> $HOME/.fiaplab.lib.sh   (biblioteca comum)
#   bin/fiaplab.sh     -> $HOME/fiaplab.sh        (menu principal)
#   bin/criar.sh       -> $HOME/criar.sh
#   bin/destruir.sh    -> $HOME/destruir.sh
#   bin/status.sh      -> $HOME/status.sh
#   bin/ligar.sh       -> $HOME/ligar.sh
#   bin/suspender.sh   -> $HOME/suspender.sh
#   bin/conectar.sh    -> $HOME/conectar.sh
#   bin/ansible.sh     -> $HOME/ansible.sh
#   bin/ip             -> $HOME/ip
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

if [ ! -d "$BIN_DIR" ]; then
    echo "❌ Diretório de comandos não encontrado: $BIN_DIR"
    exit 1
fi

# Executaveis instalados no $HOME (a lib e tratada a parte).
COMANDOS=(
    fiaplab.sh
    criar.sh
    destruir.sh
    status.sh
    ligar.sh
    suspender.sh
    conectar.sh
    ansible.sh
    ip
)

# ------------------------------------------------------------
# Biblioteca comum (dotfile, so leitura do dono)
# ------------------------------------------------------------

if [ ! -f "$BIN_DIR/fiaplab.lib.sh" ]; then
    echo "❌ Biblioteca não encontrada: $BIN_DIR/fiaplab.lib.sh"
    exit 1
fi

cp -f "$BIN_DIR/fiaplab.lib.sh" "$HOME/.fiaplab.lib.sh" || {
    echo "❌ Não foi possível instalar a biblioteca."
    exit 1
}
chmod 600 "$HOME/.fiaplab.lib.sh"

# ------------------------------------------------------------
# Comandos
# ------------------------------------------------------------

for CMD in "${COMANDOS[@]}"; do

    if [ ! -f "$BIN_DIR/$CMD" ]; then
        echo "❌ Comando não encontrado: $BIN_DIR/$CMD"
        exit 1
    fi

    cp -f "$BIN_DIR/$CMD" "$HOME/$CMD" || {
        echo "❌ Não foi possível instalar: $CMD"
        exit 1
    }
    chmod +x "$HOME/$CMD"

done

echo ""
echo "========================================"
echo " COMANDOS INSTALADOS"
echo "========================================"
echo ""
