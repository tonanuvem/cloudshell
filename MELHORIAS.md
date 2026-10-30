# Revisão do cloudshell — pontos em aberto

Levantado em 2026-10-29, lendo `init.sh`, `comandos.sh`, `credenciais.sh`, a
parte de credenciais de `bin/fiaplab.lib.sh` e os caminhos destrutivos
(`deep_clean`, `vpc_teardown`, todo `rm -rf` do repositório).

**Nada foi alterado.** Esta lista é só o registro, em ordem de consequência.

---

## 1. `credenciais.sh` recria o bug que a lib existe para evitar

`bin/fiaplab.lib.sh`, no comentário de `aws_login` (linhas ~255–280), explica
por que `~/.aws/credentials` no `$HOME` é veneno no CloudShell: o `$HOME`
**persiste** entre *End Lab* / *Start Lab*, e o arquivo no caminho padrão tem
**precedência** sobre o provedor de container. Um token vencido ali ganha da
credencial fresca e produz `ExpiredToken` em toda sessão — inclusive no meio
de um `terraform apply` longo. A defesa da lib é apontar
`AWS_SHARED_CREDENTIALS_FILE` para `/dev/null`.

E o repositório continua entregando `credenciais.sh`, cuja única função é
escrever exatamente esse arquivo. O comentário da lib chega a citá-lo entre os
"scripts antigos" que causavam o problema.

Agravante: a defesa da lib só vale dentro do processo dela. Um `aws s3 ls` que
o aluno digite no CloudShell lê o arquivo velho e falha.

Ninguém chama o script — só há menção no `README.md` ("uso manual") e no
comentário da lib.

**Sugestão:** apagar, ou fazê-lo escrever em `$CRED_DIR`
(`~/environment/credenciais`), como a lib faz.

## 2. `init.sh:36` apaga a pasta do aluno sem avisar

```bash
if [ ! -d "$PASTA_CONFIG/.git" ]; then
    rm -rf "$PASTA_CONFIG"
```

Se o `.git` de `~/environment/config` sumir — clone interrompido, pasta criada
à mão, cópia de arquivos sem o `.git` — a pasta inteira é removida **em
silêncio**, sem mensagem nem confirmação, e o aluno perde edições locais sem
nenhuma pista.

O próprio script, no caminho em que o `git pull` falha (linhas 50–60), tem o
cuidado de dizer "mova-os para fora da pasta e rode de novo". O caminho do
`rm -rf` não tem esse cuidado.

**Sugestão:** avisar e pedir confirmação, ou renomear para
`config.bak-<data>` em vez de apagar.

## 3. A validação da credencial olha só um dos três campos

Em `credenciais.sh:18` e em `aws_write_credentials_file`
(`bin/fiaplab.lib.sh`, linha ~214) o teste é `[ -n "$KEY_ID" ]`:
`SecretAccessKey` e `Token` não são verificados. Uma resposta parcial do
endpoint grava um arquivo com segredo vazio.

Falha seguro — o `_sts_ok` recusa depois — mas o aluno lê **"SESSÃO AWS
EXPIRADA"** quando o problema foi outro, e vai clicar *Start Lab* à toa.

**Sugestão:** exigir os três campos. Uma linha em cada arquivo.

## 4. Não existe `.gitignore`

Havia um `.DS_Store` não rastreado no clone em 2026-10-29. Sem `.gitignore`
ele entra no repositório no próximo `git add` amplo.

**Sugestão:** `.gitignore` com `.DS_Store`, `*.pem` e `.terraform/`.

## 5. 46 linhas de DynamoDB morto no `init.sh`

Linhas 162–207, comentadas, com a nota "mantida apenas como histórico". O git
já é o histórico. Mesmo caso que foi limpo no repositório `dns`.

## 6. Falhas não verificadas no `init.sh`

- linhas 97–98: `cp -f` da chave e o `chmod 400` seguinte, sem checar
- linha 217: `cat > "$CONFIG_DIR/hosts"`, sem checar

Com `$PASTA_ENV` ou `$CONFIG_DIR` ausente, a falha aparece bem depois e em
outro lugar. Note que não há `mkdir -p "$PASTA_ENV"` em nenhum ponto antes da
linha 93: hoje a pasta só existe porque o `git clone` da seção 1 a cria de
passagem.

---

## Uma coisa que talvez seja intencional

`deep_clean` (`bin/fiaplab.lib.sh`, linha ~1450) termina **toda** instância
EC2 em `us-east-1` e `us-west-2` e destrói **toda** VPC não-default, ignorando
o `FIAPLAB_NAME_FILTER` que o próprio repositório define (linha 46) e usa em
`fiaplab_instances`.

Tem confirmação digitada (`LIMPAR`, em `bin/fiaplab.sh:148`) e o nome é
"limpeza geral", então pode ser exatamente o pretendido. Mas a assimetria com
o `FIAPLAB_NAME_FILTER` vai parecer descuido para quem ler depois.

**Sugestão:** se é intencional, um comentário dizendo isso. Se não, filtrar.
