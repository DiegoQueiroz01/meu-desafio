# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 05 | Log de acesso sem o corpo da resposta | [Node.js 20, A note on process I/O](https://nodejs.org/docs/latest-v20.x/api/process.html#a-note-on-process-io) | em medição | | | | |

---

## 05 — Log de acesso sem o corpo da resposta

Branch: `hipotese/log-resposta`, criada a partir de `feature/diagnostico` (aplicação original, sem índices, sem pool e sem a visão de `top-produtos`). Mudança: o middleware de log em [api/src/server.js](api/src/server.js).

### Hipótese

A API escreve no log, para cada requisição, o corpo inteiro da resposta ([diagnostico/README.md](diagnostico/README.md), item 9). Para isso, converte o corpo para JSON uma vez só para o log, além da conversão que o Express faz para enviar a resposta. Na aplicação original isso não pesa, porque a API usa ~6% de CPU. Mas na integração 01+02+03 a API ficou com 46.7% de CPU média, perto do limite de 0,5 CPU (50%), atendendo 98.09 requisições/s (branch `integracao`).

**Se** o log de acesso registrar só método, URL, status e duração, sem o corpo, **então** a API gasta menos CPU e escreve menos bytes por requisição, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** **sem ganho** medida sozinha. Na aplicação original o gargalo é o banco (99.8% de CPU), e a API passa a maior parte do tempo esperando por ele. O teste isolado serve para mostrar que a mudança não piora nada; o efeito esperado é na branch `integracao`, onde a CPU da API está perto do limite.

### O que mudou

Em [api/src/server.js](api/src/server.js), o campo `resposta` saiu da linha de log. A linha continua sendo escrita uma vez por requisição, com `metodo`, `url`, `status` e `duracao_ms`, no mesmo formato JSON. As rotas não mudaram.

### Fontes

- Node.js 20, [process, "A note on process I/O"](https://nodejs.org/docs/latest-v20.x/api/process.html#a-note-on-process-io): `console.log()` escreve em `process.stdout`; em pipes, a escrita é síncrona no Windows e assíncrona em POSIX (Linux), e escritas síncronas "block the event loop until the write has completed". A página recomenda cuidado "when doing production logging to the process output streams".
- Docker, [Configure logging drivers](https://docs.docker.com/engine/logging/configure/): o driver padrão é o `json-file`, e a entrega das mensagens do container para o driver é, por padrão, "direct, blocking delivery".

Ou seja: no Linux o `console.log` da API não trava o laço de eventos esperando o disco, mas cada linha ainda custa CPU para ser convertida em JSON e escrita, e o Docker grava cada byte no arquivo de log do container.

### Evidência antes de medir

[diagnostico/16-log-sem-corpo.txt](diagnostico/16-log-sem-corpo.txt), uma requisição por vez, sem carga:

| URL | Corpo da resposta | Log antes | Log depois |
|---|---|---|---|
| `/clientes/4242` | 125 B | 206 B | 68 B |
| `/clientes?email=...` | 127 B | 235 B | 96 B |
| `/clientes/4242/pedidos` | 1622 B | 1712 B | 78 B |
| `/pedidos?status=pago&pagina=500` | 1814 B | 1913 B | 87 B |
| `/produtos/busca?q=cadeira` | 1891 B | 1983 B | 80 B |
| `/relatorios/vendas-por-dia?...` | 540 B | 667 B | 115 B |
| `/relatorios/top-produtos?limite=10` | 1257 B | 1359 B | 90 B |

O contrato foi mantido: o log não faz parte da resposta HTTP.

### Custo

- Nenhum serviço novo e nenhum limite alterado.
- **Perda de informação:** o log deixa de guardar o que cada requisição devolveu. Para investigar um erro, quem mantém o sistema terá que reproduzir a requisição. Método, URL, status e duração continuam no log.

### Resultado

Ainda não medido.
