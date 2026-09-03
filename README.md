# cloudshell

Ambiente FIAP LAB para o AWS CloudShell: prepara Terraform + Ansible e
cria a VM (code-server) a partir do repositório
[tonanuvem/config](https://github.com/tonanuvem/config).

## Uso

```bash
bash init.sh      # prepara o ambiente e cria a ubuntu-vm
~/fiaplab.sh      # menu: ligar, suspender, conectar, ansible, destruir...
```

## Estrutura

| Arquivo            | Papel |
|--------------------|-------|
| `init.sh`          | Bootstrap: clona o config, instala os comandos, prepara credenciais/Terraform/Ansible e cria a VM. |
| `comandos.sh`      | Instala o lançador `~/fiaplab.sh` (aponta para `bin/fiaplab.sh`). |
| `bin/`             | Comandos reais, executados a partir daqui (sem cópias no `$HOME`). **Edite aqui.** |
| `bin/fiaplab.lib.sh` | Biblioteca comum: credenciais, account id, `/tmp`, Terraform, Ansible. Carregada direto do `bin/`. |
| `credenciais.sh`   | Gera `~/.aws/credentials` avulso (uso manual). |
| `remove.sh`        | Destrói a infraestrutura e limpa o ambiente. |

Para alterar um comando (`fiaplab.sh`, `criar.sh`, etc.), edite o
arquivo em `bin/` — a mudança já vale na próxima execução, sem
reinstalar. O `$HOME` guarda apenas o lançador `~/fiaplab.sh`.

> **Clone em local persistente.** O CloudShell só preserva o `$HOME`
> entre sessões. Clone este repositório sob o `$HOME` (ex.:
> `~/cloudshell`) para que `bin/` sobreviva à troca de sessão.
