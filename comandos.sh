#!/bin/bash

# ============================================================
# FIAP LAB - INSTALADOR DO LANCADOR
#
# Os comandos do FIAP LAB rodam a partir de bin/, sem copias no
# $HOME: cada script localiza a lib e os irmaos pelo proprio
# diretorio (BIN_DIR).
#
# Este script instala apenas o lancador ~/fiaplab.sh, para o
# aluno continuar digitando "~/fiaplab.sh". O lancador aponta
# para bin/fiaplab.sh deste repositorio.
#
# Historico: antes este script GERAVA cada comando via heredoc;
# depois passou a COPIAR bin/* para o $HOME; agora so instala o
# lancador. bin/ e a unica fonte de verdade.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"

if [ ! -x "$BIN_DIR/fiaplab.sh" ]; then
    echo "❌ Menu não encontrado: $BIN_DIR/fiaplab.sh"
    exit 1
fi

LAUNCHER="$HOME/fiaplab.sh"

# Lancador com o caminho do repo embutido. Regerado a cada init,
# entao acompanha o local do repositorio se ele mudar.
cat > "$LAUNCHER" <<LAUNCH
#!/bin/bash
# Lancador gerado por comandos.sh -- executa o menu a partir do
# repositorio. NAO edite: edite $BIN_DIR/fiaplab.sh.
exec "$BIN_DIR/fiaplab.sh" "\$@"
LAUNCH

chmod +x "$LAUNCHER"

echo ""
echo "========================================"
echo " LANÇADOR INSTALADO"
echo "========================================"
echo ""
echo "Execute:  ~/fiaplab.sh"
echo ""
