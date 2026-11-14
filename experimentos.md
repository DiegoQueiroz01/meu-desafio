# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 05 | Log de acesso sem o corpo da resposta | [Node.js 20, A note on process I/O](https://nodejs.org/docs/latest-v20.x/api/process.html#a-note-on-process-io) | aplicada sem ganho | 4.78 req/s, p95 14401.8 ms | 4.90 req/s, p95 14709.0 ms | `resultados/20261114-1707*`, `-1708*`, `-1710*` `-05-log-sem-corpo` | Sem ganho sozinha, como esperado: o gargalo é o banco (97.9% de CPU) e a API usa 5.5%; precisa ser medida na integração |

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

Medido em 2026-11-14 no commit `e5986af`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes: `resultados/20261104-094609-00-linha-de-base`, `20261104-095227-00-linha-de-base`, `20261104-095420-00-linha-de-base`
- Depois: `resultados/20261114-170723-05-log-sem-corpo`, `20261114-170852-05-log-sem-corpo`, `20261114-171021-05-log-sem-corpo`

**Geral**

| Métrica | Antes | Depois |
|---|---|---|
| Requisições em 60 s | 308 | 317 |
| Requisições/s | 4.78 | 4.90 |
| Tempo de resposta, mediana | 800.1 ms | 792.7 ms |
| Tempo de resposta, p95 | 14401.8 ms | 14709.0 ms |
| Tempo de resposta, p99 | 16990.0 ms | 17747.4 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.8% | 97.9% |
| Memória máxima do banco (limite 512 MiB) | 283.6 MiB | 289.0 MiB |
| CPU média da API | 5.8% | 5.5% |
| Memória máxima da API (limite 256 MiB) | 40.5 MiB | 41.5 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Antes | Depois |
|---|---|---|
| `cliente` | 203.2 / 497.8 | 200.0 / 397.6 |
| `cliente-por-email` | 799.5 / 1401.1 | 803.4 / 1452.7 |
| `pedidos-do-cliente` | 12177.9 / 16231.5 | 12696.9 / 16425.0 |
| `pedidos-por-status` | 4598.7 / 14459.8 | 4345.4 / 8944.7 |
| `busca-produtos` | 494.1 / 732.6 | 401.6 / 730.0 |
| `vendas-por-dia` | 4614.2 / 6529.3 | 4568.0 / 6608.0 |
| `top-produtos` | 9902.8 / 15539.6 | 18456.6 / 20505.6 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **refutada quando medida sozinha: aplicada sem ganho**. A mediana de requisições/s subiu pouco (4.78 → 4.90), mas a faixa das 3 execuções se sobrepõe à da linha de base (4.43 a 4.93 depois, 4.71 a 4.79 antes), e a mediana de p95 geral piorou (14401.8 → 14709.0 ms).

- **Era o esperado.** Na aplicação original o banco está no limite (97.9% de CPU) e a API passa quase todo o tempo esperando por ele. A CPU da API mal mudou (5.8% → 5.5%), porque ela já era pouca.
- **As diferenças por rota são variação, não efeito da mudança.** `top-produtos` teve 4 requisições por execução, e sua mediana (9902.8 → 18456.6 ms) depende de quantas outras rotas pesadas rodavam ao mesmo tempo. O log não toca no banco.
- **A mudança não piorou nada de forma consistente** e não mudou nenhuma resposta (contrato mantido).
- **Custo:** nenhum recurso a mais. O log deixa de guardar o corpo de cada resposta (diagnostico/16: de 206–1983 bytes para 68–115 bytes por requisição).
- **Limites:** a hipótese existe por causa da CPU da API na integração 01+02+03 (46.7% de 50%). Ela precisa ser medida na branch `integracao`; este teste isolado só mostra que, com o banco como gargalo, o log não importa.
