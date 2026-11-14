# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`. As hipóteses são medidas primeiro isoladas, cada uma sobre a aplicação original (branch `feature/diagnostico`), contra a linha de base. As que têm ganho são juntadas na branch `integracao` e medidas de novo, combinadas, contra a medição acumulada anterior, porque os ganhos não se somam: um gargalo pode esconder o outro.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 01 | Índices B-tree nos filtros e ordenações das rotas | [PostgreSQL 16, cap. 11](https://www.postgresql.org/docs/16/indexes.html) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 19.73 req/s, p95 4102.9 ms | `resultados/20261110-1750*`, `-1752*`, `-1753*` `-01-indices` | Confirmada: mais vazão e menos latência em todas as rotas; o banco segue em ~100% de CPU, agora limitado por N+1, conexões e `top-produtos` |
| 02 | Pool de conexões (`pg.Pool`) na API | [node-postgres, Pooling](https://node-postgres.com/features/pooling) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 5.51 req/s, p95 13922.4 ms | `resultados/20261111-1308*`, `-1309*`, `-1311*` `-02-pool-conexoes` | Confirmada com ganho pequeno: o banco segue preso em `Seq Scan`; rotas rápidas pioraram na mediana (fila de 10 conexões) |
| 01+02 | Índices (01) e pool de conexões (02) juntos | as fontes de 01 e 02 | aplicada e medida | só 01: 19.73 req/s, p95 4102.9 ms | 36.47 req/s, p95 2467.9 ms | `resultados/20261111-1459*`, `-1500*`, `-1502*` `-01-02-indices-pool` | Confirmada: com os índices, o custo de abrir conexões passou a pesar; o pool, que sozinho rendeu pouco, aumentou bastante a vazão sobre os índices |
| 03 | `top-produtos` pré-calculado numa visão materializada | [PostgreSQL 16, Materialized Views](https://www.postgresql.org/docs/16/rules-materializedviews.html) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 5.05 req/s, p95 14096.8 ms | `resultados/20261111-1556*`, `-1557*`, `-1559*` `-03-top-produtos` | Confirmada com ganho geral pequeno: a rota caiu de 9902.8 para 251.9 ms de mediana, mas as outras seguem presas em `Seq Scan` |
| 01+02+03 | Índices, pool e `top-produtos` pré-calculado juntos | as fontes de 01, 02 e 03 | aplicada e medida | 01+02: 36.47 req/s, p95 2467.9 ms | 98.09 req/s, p95 788.6 ms | `resultados/20261111-1620*`, `-1622*`, `-1623*` `-01-02-03-indices-pool-top` | Confirmada: todas as rotas melhoraram; o banco saiu do limite (84.9% de CPU) e a API chegou perto do seu (46.7% de 50%) |
| 04 | `/clientes/:id/pedidos` com uma consulta, sem N+1 | [Chen et al., ICSE 2014](https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 7.98 req/s, p95 6472.4 ms | `resultados/20261114-1659*`, `-1700*`, `-1702*` `-04-pedidos-do-cliente` | Confirmada: `pedidos-do-cliente` caiu de 12177.9 para 4366.1 ms de mediana; o banco segue em 94.1% de CPU, preso nas outras leituras de tabela inteira |
| 01+…+04 | Integração 01+02+03 com `pedidos-do-cliente` sem N+1 | as fontes de 01 a 04 | aplicada e medida | 01+02+03: 98.09 req/s, p95 788.6 ms | 101.67 req/s, p95 482.8 ms | `resultados/20261114-1737*`, `-1738*`, `-1740*` `-01-a-04-integracao` | Confirmada: p95 caiu de 788.6 para 482.8 ms, mas a vazão subiu pouco e as rotas rápidas pioraram; a CPU da API (44.1%, máx. 53.5%) passou a limitar |
| 05 | Log de acesso sem o corpo da resposta | [Node.js 20, A note on process I/O](https://nodejs.org/docs/latest-v20.x/api/process.html#a-note-on-process-io) | aplicada sem ganho | 4.78 req/s, p95 14401.8 ms | 4.90 req/s, p95 14709.0 ms | `resultados/20261114-1707*`, `-1708*`, `-1710*` `-05-log-sem-corpo` | Sem ganho sozinha, como esperado: o gargalo é o banco (97.9% de CPU) e a API usa 5.5%; precisa ser medida na integração |
| 01+…+05 | Integração 01 a 04 com o log sem o corpo | as fontes de 01 a 05 | aplicada sem ganho | 01 a 04: 101.67 req/s, p95 482.8 ms | 98.90 req/s, p95 566.8 ms | `resultados/20261114-1743*`, `-1744*`, `-1746*` `-01-a-05-integracao` | Refutada: a CPU da API não caiu (44.1% → 45.4%); o log não é o custo da API. Mudança desfeita na `integracao` |
| 06 | `vendas-por-dia` somando no banco, sem trazer `observacoes` | [PostgreSQL 16, Aggregate Functions](https://www.postgresql.org/docs/16/tutorial-agg.html) | aplicada sem ganho | 4.78 req/s, p95 14401.8 ms | 4.49 req/s, p95 15030.4 ms | `resultados/20261114-1715*`, `-1716*`, `-1718*` `-06-vendas-por-dia-sql` | Sem ganho sozinha: a CPU da API caiu de 5.8% para 2.0%, mas o gargalo é o banco (98.3%), que passou a fazer a soma; precisa ser medida na integração |
| 01+…+04+06 | Integração 01 a 04 com `vendas-por-dia` somando no banco | as fontes de 01 a 04 e 06 | aplicada e medida | 01 a 04: 101.67 req/s, p95 482.8 ms | 110.23 req/s, p95 497.8 ms | `resultados/20261114-1749*`, `-1751*`, `-1752*` `-01-a-04-06-integracao` | Confirmada em parte: a CPU da API caiu de 44.1% para 5.6% e a vazão subiu, mas o p95 subiu um pouco; o banco voltou ao limite (99.2%) e a cauda é `pedidos-por-status` |
| 07 | Índice de cobertura (`INCLUDE`) para a página de `/pedidos?status=` | [PostgreSQL 16, CREATE INDEX](https://www.postgresql.org/docs/16/sql-createindex.html) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 5.31 req/s, p95 14592.6 ms | `resultados/20261114-1723*`, `-1724*`, `-1726*` `-07-status-indice-cobertura` | Não confirmada sozinha: req/s subiu e `pedidos-por-status` caiu de 4598.7 para 704.3 ms de mediana, mas o p95 geral não caiu (preso em `pedidos-do-cliente` e `top-produtos`) |
| 01+…+04+06+07 | Integração 01 a 04 + 06 com o índice de cobertura por status | as fontes de 01 a 04, 06 e 07 | aplicada e medida | 01 a 04 + 06: 110.23 req/s, p95 497.8 ms | 161.25 req/s, p95 482.9 ms | `resultados/20261114-1756*`, `-1757*`, `-1758*` `-01-a-04-06-07-integracao` | Confirmada: maior aumento de vazão da rodada; `pedidos-por-status` caiu de 305.7 para 109.0 ms de mediana; agora `vendas-por-dia` concentra o tempo |
| 08 | Total de pedidos por status pré-calculado numa visão materializada | [PostgreSQL Wiki, Slow Counting](https://wiki.postgresql.org/wiki/Slow_Counting) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 4.92 req/s, p95 14292.9 ms | `resultados/20261114-1730*`, `-1732*`, `-1733*` `-08-contagem-status` | Confirmada só pelas medianas, dentro da variação: `pedidos-por-status` caiu de 4598.7 para 2455.8 ms de mediana, mas o ganho geral não se separa do ruído |

---

## 01 — Índices B-tree nos filtros das rotas

Branch: `hipotese/indices`. Mudança: [banco/03-indices.sql](banco/03-indices.sql).

### Hipótese

O banco é o gargalo: ficou em 99,2% de CPU na linha de base ([recursos.txt](resultados/20261104-095227-00-linha-de-base/recursos.txt)). As consultas de 5 das 7 rotas leem a tabela inteira (`Seq Scan`), porque só existem as chaves primárias ([diagnostico/README.md](diagnostico/README.md), item 2).

**Se** criarmos índices que sigam o filtro e a ordenação de cada consulta, **então** o banco deixa de ler tabelas inteiras, gasta menos CPU por requisição e atende mais requisições por segundo com tempo de resposta menor, sem mudar nenhuma resposta da API.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Esperado sem ganho direto:** `/relatorios/top-produtos`, que soma todos os itens a cada chamada, e `/produtos/busca`, cujo `ILIKE '%termo%'` não usa B-tree e a tabela é pequena. Essas rotas podem melhorar só de forma indireta, se o banco ficar menos ocupado com as outras.

### O que mudou

Um arquivo novo, `banco/03-indices.sql`, que roda quando o banco é criado do zero. Nenhuma linha da API mudou.

| Índice | Rota | Por quê |
|---|---|---|
| `clientes (lower(email))` | `/clientes?email=` | a consulta filtra por `lower(email)`; o índice tem que ser sobre a mesma expressão |
| `pedidos (cliente_id, criado_em DESC, id DESC)` | `/clientes/:id/pedidos` | filtro e ordenação no mesmo índice: não precisa ordenar depois |
| `itens_pedido (pedido_id)` | `/clientes/:id/pedidos` e os dois relatórios | busca dos itens de cada pedido e `JOIN` com `pedidos` |
| `pedidos (status, criado_em DESC, id DESC)` | `/pedidos?status=` | `ORDER BY ... LIMIT` sai do índice já ordenado, sem a ordenação em disco |
| `pedidos ((criado_em::date))` | `/relatorios/vendas-por-dia` | a consulta filtra por `criado_em::date`; um índice só em `criado_em` não seria usado |

No fim, o arquivo roda `VACUUM (ANALYZE)` para que o planejador tenha estatísticas da expressão `criado_em::date` e para que o mapa de visibilidade permita `Index Only Scan` no `count(*)`.

### Fontes

- PostgreSQL 16, [cap. 11 — Indexes](https://www.postgresql.org/docs/16/indexes.html): "An index allows the database server to find and retrieve specific rows much faster than it could do without an index. But indexes also add overhead to the database system as a whole, so they should be used sensibly."
- PostgreSQL 16, [11.7 — Indexes on Expressions](https://www.postgresql.org/docs/16/indexes-expressional.html): o exemplo usa exatamente `lower(col1)`, e o texto avisa que índices sobre expressões são "relatively expensive to maintain" na inserção e atualização, e úteis "when retrieval speed is more important than insertion and update speed".
- PostgreSQL 16, [11.4 — Indexes and ORDER BY](https://www.postgresql.org/docs/16/indexes-ordering.html): com `ORDER BY` + `LIMIT n` e um índice que bate com a ordenação, "the first n rows can be retrieved directly, without scanning the remainder at all"; só o B-tree produz saída ordenada.
- PostgreSQL 16, [11.9 — Index-Only Scans](https://www.postgresql.org/docs/16/indexes-index-only-scans.html): o `Index Only Scan` só compensa quando boa parte das páginas está marcada como visível no mapa de visibilidade.

### Evidência antes de medir

[diagnostico/10-explain-com-indices.txt](diagnostico/10-explain-com-indices.txt) repete as consultas de 02 a 08 com os índices. Uma consulta por vez, sem carga:

| Consulta | Antes (arquivos 03–08) | Depois (arquivo 10) |
|---|---|---|
| cliente por e-mail | 21,293 ms | 0,057 ms |
| pedidos do cliente | 19,281 ms | 0,043 ms |
| itens de um pedido | 44,699 ms | 0,059 ms |
| contagem por status | 27,751 ms | 11,704 ms |
| página por status | 114,112 ms | 3,835 ms |
| busca de produtos | 6,891 ms | 6,740 ms |
| vendas por dia | 196,862 ms | 7,420 ms |
| top produtos | 731,535 ms | 743,363 ms |

Esses tempos não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- **Disco:** os 5 índices novos ocupam 70 MB ([arquivo 10](diagnostico/10-explain-com-indices.txt)).
- **Memória:** os índices disputam os 128 MB de `shared_buffers` com as tabelas.
- **Escrita:** cada `INSERT`/`UPDATE` em `pedidos` passa a atualizar 3 índices a mais. A carga do desafio só faz leituras, então esse custo não aparece na medição.

### Resultado

Medido em 2026-11-10 no commit `ce77210`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes: `resultados/20261104-094609-00-linha-de-base`, `20261104-095227-00-linha-de-base`, `20261104-095420-00-linha-de-base`
- Depois: `resultados/20261110-175053-01-indices`, `20261110-175215-01-indices`, `20261110-175337-01-indices`

**Geral**

| Métrica | Antes | Depois |
|---|---|---|
| Requisições em 60 s | 308 | 1220 |
| Requisições/s | 4.78 | 19.73 |
| Tempo de resposta, mediana | 800.1 ms | 204.5 ms |
| Tempo de resposta, p95 | 14401.8 ms | 4102.9 ms |
| Tempo de resposta, p99 | 16990.0 ms | 10061.1 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.8% | 98.7% |
| Memória máxima do banco (limite 512 MiB) | 283.6 MiB | 403.3 MiB |
| CPU média da API | 5.8% | 15.8% |
| Memória máxima da API (limite 256 MiB) | 40.5 MiB | 70.6 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Antes | Depois |
|---|---|---|
| `cliente` | 203.2 / 497.8 | 99.3 / 206.8 |
| `cliente-por-email` | 799.5 / 1401.1 | 100.8 / 212.6 |
| `pedidos-do-cliente` | 12177.9 / 16231.5 | 1843.7 / 4084.1 |
| `pedidos-por-status` | 4598.7 / 14459.8 | 575.3 / 9586.8 |
| `busca-produtos` | 494.1 / 732.6 | 199.8 / 395.4 |
| `vendas-por-dia` | 4614.2 / 6529.3 | 1252.7 / 4921.9 |
| `top-produtos` | 9902.8 / 15539.6 | 7169.8 / 10950.6 |

### Conclusão

A hipótese foi **confirmada**: com os mesmos `VUS`, `DURACAO` e `SEMENTE`, a mediana de requisições/s subiu e a de p95 geral caiu, com o contrato mantido.

- **O banco continua no limite de CPU**, mas agora atende muito mais requisições com a mesma CPU. O gasto de CPU por requisição caiu; o banco não ficou ocioso.
- **`busca-produtos` e `top-produtos` melhoraram sem índice próprio.** O `EXPLAIN` delas não mudou (arquivo 10). Elas ganharam porque passaram menos tempo na fila atrás das rotas pesadas, como a hipótese previa.
- **O que ainda pesa:**
  - `pedidos-do-cliente` (p95 4084.1 ms) ainda faz uma consulta por pedido e por item, cada uma com conexão nova (N+1, diagnóstico itens 3 e 4).
  - `pedidos-por-status` tem p95 alto: o `count(*)` de `pago` ainda percorre 60% da tabela, e o `OFFSET` de páginas altas percorre milhares de entradas.
  - `top-produtos` continua somando 1,5 milhão de itens a cada chamada.
- **Custo:**
  - 70 MB de disco em índices.
  - A memória máxima do banco subiu de 283.6 para 403.3 MiB, mais perto do limite de 512 MiB. Os índices ocupam cache, e o banco atende mais requisições ao mesmo tempo.
  - A API subiu de 5.8% para 15.8% de CPU, porque atende mais requisições.
  - O custo de escrita dos índices não foi medido, porque a carga só faz leituras.
- **Limites:** é uma só mudança medida contra uma só linha de base. A variação entre execuções aparece nas pastas (p95 de 3813.2 a 4196.4 ms nas 3 execuções com índices).

---

## 02 — Pool de conexões na API

Branch: `hipotese/pool_conexao`, criada a partir de `feature/diagnostico` (aplicação original, sem os índices da hipótese 01). Mudança: [api/src/db.js](api/src/db.js).

### Hipótese

A API abre e fecha uma conexão com o banco a cada consulta ([diagnostico/README.md](diagnostico/README.md), item 3). No PostgreSQL, cada conexão nova cria um processo novo no servidor. Em `/clientes/:id/pedidos`, por causa do N+1, uma só requisição abriu 17 conexões ([09-conexoes-por-requisicao.txt](diagnostico/09-conexoes-por-requisicao.txt)).

**Se** a API mantiver um pool de conexões abertas e reaproveitá-las, **então** o banco deixa de criar e encerrar um processo por consulta, gasta essa CPU com as consultas e atende mais requisições por segundo, com tempo de resposta menor, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** ganho pequeno quando medido sozinho. Na linha de base, o banco gasta a CPU lendo tabelas inteiras (`Seq Scan`, diagnóstico item 2), e esse custo é muito maior que o de abrir conexões. O maior ganho deve aparecer em `/clientes/:id/pedidos`, a rota que mais abre conexões. Por isso, mesmo sem ganho isolado, a hipótese será medida de novo junto com os índices.

### O que mudou

Em [api/src/db.js](api/src/db.js), o `Client` criado a cada consulta virou um `Pool` criado uma vez, quando a API sobe. A função `consultar` chama `pool.query`, que pega uma conexão livre, consulta e devolve a conexão ao pool. As rotas não mudaram.

- **Tamanho do pool:** `max: 10`, o padrão do node-postgres. Com 20 usuários virtuais, no máximo 10 consultas rodam ao mesmo tempo no banco; as outras esperam a vez na própria API. A fórmula da wiki do PostgreSQL daria um pool menor para 1 CPU (`núcleos × 2 + discos`), mas ela é um ponto de partida, não uma regra. Testar outros tamanhos fica para um teste futuro, para mudar uma coisa de cada vez.
- **Conexões ociosas:** o pool fecha uma conexão parada há mais de 10 s (`idleTimeoutMillis`, padrão).
- **Erro em conexão ociosa:** um `pool.on('error')` registra o erro no log em vez de derrubar a API, como a documentação do node-postgres recomenda.

### Fontes

- PostgreSQL 16, [52.2 — How Connections Are Established](https://www.postgresql.org/docs/16/connect-estab.html): o PostgreSQL usa um processo por usuário; a cada conexão, o postmaster "spawns a new backend process".
- node-postgres, [Pooling](https://node-postgres.com/features/pooling): conectar exige um handshake que "can take 20-30 milliseconds"; o pool é a forma mais comum de usar a biblioteca, e `pool.query` devolve a conexão ao pool sozinho.
- node-postgres, [API do Pool](https://node-postgres.com/apis/pool): padrões `max` 10 e `idleTimeoutMillis` 10000.
- Hellerstein, Stonebraker e Hamilton, [Architecture of a Database System](https://courses.cs.washington.edu/courses/cse544/20wi/papers/DBArchitecture.pdf), Foundations and Trends in Databases 1(2), 2007, seções 2.1.1 e 2.1.3 (p. 153–155): o modelo de um processo por conexão, usado pelo PostgreSQL, não é o mais atraente com muitas conexões; um pool de processos é uma das variantes que evitam isso.
- PostgreSQL Wiki, [Number Of Database Connections](https://wiki.postgresql.org/wiki/Number_Of_Database_Connections) e HikariCP, [About Pool Sizing](https://github.com/brettwooldridge/HikariCP/wiki/About-Pool-Sizing): pools pequenos costumam render mais que pools grandes; a fórmula `(núcleos × 2) + discos` é um ponto de partida.
- Moreira, [Connection pooling em PostgreSQL: caracterização empírica do ponto de equilíbrio entre sobrecarga e contenção](https://repositorio.ufu.br/handle/123456789/49993), TCC, UFU, 2026 (lido só o resumo): com pouca concorrência, o pooler só adiciona latência. Diferença do nosso caso: lá a conexão direta já era persistente; aqui a API abria uma conexão por consulta.

### Evidência antes de medir

[diagnostico/11-conexoes-com-pool.txt](diagnostico/11-conexoes-com-pool.txt) repete o método do arquivo 09 com o pool. Uma requisição por vez, sem carga, depois de uma requisição de aquecimento:

| URL | Conexões novas antes (arquivo 09) | Com pool (arquivo 11) |
|---|---|---|
| `/clientes/4242` | 1 | 0 |
| `/clientes?email=...` | 1 | 0 |
| `/clientes/4242/pedidos` | 17 | 0 |
| `/clientes/77/pedidos` | 17 | 0 |
| `/pedidos?status=pago&pagina=500` | 2 | 0 |
| `/produtos/busca?q=cadeira` | 1 | 0 |
| `/relatorios/vendas-por-dia?...` | 1 | 0 |
| `/relatorios/top-produtos?limite=10` | 1 | 0 |

Os tempos desse arquivo não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- **Conexões abertas:** até 10 processos do PostgreSQL ficam abertos enquanto há uso, e cada um ocupa memória no banco.
- **Fila na API:** se as 10 conexões estiverem ocupadas, a consulta espera na API. Com `connectionTimeoutMillis` no padrão (0), a espera não tem limite.
- Nenhum serviço novo e nenhuma mudança de CPU ou memória nos limites do compose.

### Resultado

Medido em 2026-11-11 no commit `856e1b1`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes: `resultados/20261104-094609-00-linha-de-base`, `20261104-095227-00-linha-de-base`, `20261104-095420-00-linha-de-base`
- Depois: `resultados/20261111-130807-02-pool-conexoes`, `20261111-130934-02-pool-conexoes`, `20261111-131102-02-pool-conexoes`

**Geral**

| Métrica | Antes | Depois |
|---|---|---|
| Requisições em 60 s | 308 | 349 |
| Requisições/s | 4.78 | 5.51 |
| Tempo de resposta, mediana | 800.1 ms | 920.5 ms |
| Tempo de resposta, p95 | 14401.8 ms | 13922.4 ms |
| Tempo de resposta, p99 | 16990.0 ms | 15948.3 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.8% | 98.5% |
| Memória máxima do banco (limite 512 MiB) | 283.6 MiB | 295.0 MiB |
| CPU média da API | 5.8% | 4.5% |
| Memória máxima da API (limite 256 MiB) | 40.5 MiB | 40.1 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Antes | Depois |
|---|---|---|
| `cliente` | 203.2 / 497.8 | 372.4 / 872.1 |
| `cliente-por-email` | 799.5 / 1401.1 | 703.7 / 1499.4 |
| `pedidos-do-cliente` | 12177.9 / 16231.5 | 11199.1 / 15829.6 |
| `pedidos-por-status` | 4598.7 / 14459.8 | 2712.4 / 8016.4 |
| `busca-produtos` | 494.1 / 732.6 | 497.9 / 826.0 |
| `vendas-por-dia` | 4614.2 / 6529.3 | 2897.9 / 4114.7 |
| `top-produtos` | 9902.8 / 15539.6 | 6514.0 / 12672.9 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **confirmada, com ganho pequeno**: a mediana de requisições/s subiu (4.78 → 5.51) e a de p95 geral caiu (14401.8 → 13922.4 ms), com o contrato mantido. Nas 3 execuções de cada lado, os valores não se sobrepõem: requisições/s de 4.71 a 4.79 antes e de 5.44 a 5.65 depois; p95 de 14260.1 a 15731.8 ms antes e de 13897.1 a 13992.4 ms depois.

- **O ganho foi pequeno, como esperado.** O banco continua em ~100% de CPU, porque o custo principal é ler tabelas inteiras (`Seq Scan`), não abrir conexões.
- **`pedidos-do-cliente` quase não mudou** (mediana 12177.9 → 11199.1 ms), mesmo sendo a rota que deixou de abrir 17 conexões. Cada uma das suas consultas de itens ainda lê a `itens_pedido` inteira; o custo de conexão é pequeno perto disso.
- **As rotas pesadas melhoraram** (`pedidos-por-status`, `vendas-por-dia`, `top-produtos`), e as rápidas pioraram: a mediana de `cliente` foi de 203.2 para 372.4 ms, e a mediana geral subiu de 800.1 para 920.5 ms. Uma explicação provável, ainda não testada: com no máximo 10 conexões, uma consulta rápida espera na fila da API enquanto consultas lentas ocupam as conexões. Antes, cada requisição abria a sua e disputava a CPU direto no banco.
- **Custo:** nenhum serviço novo e nenhum limite alterado. A memória máxima do banco ficou em 295.0 MiB (antes 283.6 MiB), com até 10 processos abertos o tempo todo durante a carga.
- **Limites:** medido sozinho, sobre a aplicação original. Segundo o plano, a mudança deve ser medida de novo junto com os índices (hipótese 01), quando o custo das consultas cai e o custo de conexão passa a pesar mais. O tamanho do pool (`max: 10`) não foi variado.

---

## 01+02 — Índices e pool de conexões juntos

Branch: `integracao`, criada a partir de `hipotese/indices` e com o merge de `hipotese/pool_conexao`. Não há código novo: é a soma das mudanças [banco/03-indices.sql](banco/03-indices.sql) e [api/src/db.js](api/src/db.js).

### Hipótese

Medido sozinho, o pool teve ganho pequeno porque o banco gastava quase toda a CPU lendo tabelas inteiras (seção 02). Com os índices, cada consulta fica muito mais barata (seção 01), então o custo de abrir uma conexão por consulta passa a ser uma parte maior do trabalho do banco. Em `/clientes/:id/pedidos`, que ainda faz 17 consultas por requisição, isso deve pesar mais.

**Se** juntarmos o pool aos índices, **então** a aplicação atende mais requisições por segundo, com p95 menor, do que com os índices sozinhos, sem mudar nenhuma resposta.

- **Comparação:** contra a hipótese 01 (`resultados/*-01-indices`), não contra a linha de base.
- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à hipótese 01, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Atenção:** na medição isolada do pool, a mediana das rotas rápidas piorou, provavelmente pela fila de 10 conexões. Com consultas mais rápidas, as conexões ficam ocupadas por menos tempo, e essa fila deve diminuir.

### Resultado

Medido em 2026-11-11 no commit `66fe7e4`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes (só índices): `resultados/20261110-175053-01-indices`, `20261110-175215-01-indices`, `20261110-175337-01-indices`
- Depois (índices + pool): `resultados/20261111-145918-01-02-indices-pool`, `20261111-150047-01-02-indices-pool`, `20261111-150210-01-02-indices-pool`

**Geral**

| Métrica | Só índices (01) | Índices + pool (01+02) |
|---|---|---|
| Requisições em 60 s | 1220 | 2274 |
| Requisições/s | 19.73 | 36.47 |
| Tempo de resposta, mediana | 204.5 ms | 129.8 ms |
| Tempo de resposta, p95 | 4102.9 ms | 2467.9 ms |
| Tempo de resposta, p99 | 10061.1 ms | 4696.5 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 98.7% | 98.4% |
| Memória máxima do banco (limite 512 MiB) | 403.3 MiB | 378.5 MiB |
| CPU média da API | 15.8% | 21.8% |
| Memória máxima da API (limite 256 MiB) | 70.6 MiB | 55.4 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Só índices (01) | Índices + pool (01+02) |
|---|---|---|
| `cliente` | 99.3 / 206.8 | 44.1 / 228.3 |
| `cliente-por-email` | 100.8 / 212.6 | 40.5 / 203.7 |
| `pedidos-do-cliente` | 1843.7 / 4084.1 | 882.7 / 2706.3 |
| `pedidos-por-status` | 575.3 / 9586.8 | 302.2 / 4432.9 |
| `busca-produtos` | 199.8 / 395.4 | 94.6 / 261.8 |
| `vendas-por-dia` | 1252.7 / 4921.9 | 594.4 / 2053.5 |
| `top-produtos` | 7169.8 / 10950.6 | 3153.1 / 5361.1 |

### Conclusão

A hipótese foi **confirmada**: contra os índices sozinhos, a mediana de requisições/s subiu (19.73 → 36.47) e a de p95 geral caiu (4102.9 → 2467.9 ms), com o contrato mantido. Nas 3 execuções de cada lado, os valores não se sobrepõem: requisições/s de 18.96 a 19.97 antes e de 36.37 a 37.22 depois; p95 de 3813.2 a 4196.4 ms antes e de 2309.1 a 2525.9 ms depois.

- **Um gargalo escondia o outro.** Sozinho, sobre a aplicação original, o pool levou as requisições/s de 4.78 para 5.51 (seção 02). Sobre os índices, levou de 19.73 para 36.47. Com o `Seq Scan`, abrir conexões era uma parte pequena do trabalho do banco; com as consultas baratas, passou a ser uma parte grande. Por isso a medição combinada era necessária.
- **A fila do pool não apareceu como na medição isolada.** A mediana de `cliente` caiu de 99.3 para 44.1 ms, em vez de piorar. O p95 de `cliente` subiu um pouco (206.8 → 228.3 ms); as outras rotas melhoraram em mediana e em p95.
- **O banco continua perto de 100% de CPU**, mas atende quase o dobro de requisições com a mesma CPU.
- **Custo:** nenhum serviço novo e nenhum limite alterado. A CPU média da API subiu de 15.8% para 21.8%, porque atende mais requisições; a memória máxima do banco ficou em 378.5 MiB (antes 403.3 MiB).
- **O que ainda pesa:** `top-produtos` (p95 5361.1 ms), `pedidos-por-status` (p95 4432.9 ms, `count(*)` de `pago` e `OFFSET`) e `pedidos-do-cliente` (p95 2706.3 ms, N+1: ainda são 17 consultas por requisição, agora sem abrir conexões).
- **Limites:** o tamanho do pool (`max: 10`) não foi variado.

---

## 03 — `top-produtos` pré-calculado

Branch: `hipotese/top-produtos`, criada a partir de `feature/diagnostico` (aplicação original, sem índices e sem pool). Mudanças: [banco/04-top-produtos.sql](banco/04-top-produtos.sql) e a consulta da rota em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

`/relatorios/top-produtos` soma os 1,5 milhão de itens de pedido a cada chamada: 731,535 ms por consulta sozinha, sem carga ([diagnostico/08](diagnostico/08-explain-top-produtos.txt)). Com índices e pool, essa consulta ficou com 61.2% do tempo do banco, mesmo sendo 2% das requisições ([diagnostico/12](diagnostico/12-consumo-por-consulta.txt), na branch `feature/diagnostico-consumo`). O resultado é o mesmo em todas as chamadas, porque a carga só faz leituras.

**Se** o resultado da soma for calculado uma vez e guardado numa visão materializada, **então** a rota passa a ler poucas linhas prontas, o banco libera a CPU que gastava nessa soma, e a aplicação atende mais requisições por segundo, com tempo de resposta menor, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** `top-produtos` deve ficar muito mais rápida. As outras rotas devem melhorar só de forma indireta, por esperarem menos pela CPU. Na aplicação original, as outras consultas também leem tabelas inteiras, então o ganho geral pode ser menor do que sobre os índices. Por isso a mudança será medida também na branch `integracao`.

### O que mudou

- **`banco/04-top-produtos.sql`:** cria a visão materializada `top_produtos` com a mesma consulta da rota, sem o `LIMIT`. Fica uma linha por produto vendido (19206), com `unidades` e `receita_centavos` já somadas. Cria também um índice em `(receita_centavos DESC, id)`, a mesma ordem da rota, e um índice único em `id`, exigido pelo `REFRESH ... CONCURRENTLY`. O número 04 evita conflito com o `banco/03-indices.sql` da hipótese 01.
- **`api/src/rotas.js`:** a rota lê `top_produtos` com `ORDER BY receita_centavos DESC, id LIMIT $1`. Validação do `limite`, campos e conversões ficaram iguais.

### Fontes

- PostgreSQL 16, [41.3 — Materialized Views](https://www.postgresql.org/docs/16/rules-materializedviews.html): o acesso aos dados de uma visão materializada "is often much faster than accessing the underlying tables directly or through a view, the data is not always current". O exemplo da página é um resumo de vendas atualizado uma vez por noite com `REFRESH MATERIALIZED VIEW`.
- PostgreSQL 16, [REFRESH MATERIALIZED VIEW](https://www.postgresql.org/docs/16/sql-refreshmaterializedview.html): o refresh "completely replaces the contents of a materialized view"; com `CONCURRENTLY`, não bloqueia as leituras, e exige um índice `UNIQUE` só com colunas.
- Almeida e Lifschitz, [(Auto) Sintonia-fina em Sistemas de Bancos de Dados nas Organizações](https://books-sol.sbc.org.br/index.php/sbc/catalog/download/7/12/38-1), cap. 4 em V Escola Regional de Sistemas de Informação do Rio de Janeiro, SBC, 2018, p. 119: visões materializadas "são réplicas dos dados originais em formatos mais adequados para a realização de consulta"; a cada atualização dos dados originais, também precisam ser atualizadas, "gerando mais atividade na base de dados".
- Formiga, [Atualização eficiente de visões materializadas em data warehousing](https://dspace.sti.ufcg.edu.br/handle/riufcg/6732), dissertação de mestrado, UFPB, 1999: visões materializadas são "cálculos pré-computados, fisicamente armazenados", e atualizá-las pode ser muito custoso.
- Agner, [T-SVM: uma abordagem para manutenção de visões materializadas em ambientes data warehouse](https://revistas.unicentro.br/index.php/RECEN/article/download/386/538), Revista Ciências Exatas e Naturais, v. 7, n. 1, 2005, p. 35–52: compara o reprocessamento da visão inteira (o que o `REFRESH` faz), que consome tempo e recursos, com a manutenção incremental, que altera só a parte da visão afetada por cada mudança.
- Carvalho, [Criação automática de visões materializadas em SGBDs relacionais](http://doi.org/10.17771/PUCRio.acad.18628), PUC-Rio, 2011 (lido só o resumo): define a visão materializada como um objeto que "armazena um conjunto de dados pré-calculados" e propõe métricas de custo e benefício para decidir quando criá-la.

### Evidência antes de medir

[diagnostico/13-explain-top-produtos-pre-calculado.txt](diagnostico/13-explain-top-produtos-pre-calculado.txt), uma consulta por vez, sem carga:

| Consulta | Antes ([arquivo 08](diagnostico/08-explain-top-produtos.txt)) | Depois (arquivo 13) |
|---|---|---|
| top produtos, `limite=10` | 731,535 ms | 0,032 ms |
| top produtos, `limite=50` | — | 0,067 ms |

Esses tempos não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- **Dados defasados:** a visão é uma foto do momento em que foi criada. Numa loja com pedidos novos, o relatório ficaria desatualizado até o próximo refresh. Na carga do desafio, que só lê, isso não aparece.
- **Custo de cada refresh:** 704.293 ms (normal) e 743.291 ms (`CONCURRENTLY`), sem carga (arquivo 13). É mais ou menos o custo de uma chamada da rota antiga. Um refresh por hora custaria isso uma vez por hora, em vez de a cada chamada.
- **Disco:** 2048 kB da visão, mais 440 kB e 608 kB dos dois índices (arquivo 13).
- **Manutenção:** quem mantém o sistema precisa agendar o refresh (por exemplo, com um job no banco ou na aplicação) e decidir quanto atraso o relatório pode ter.

### Resultado

Medido em 2026-11-11 no commit `b8236f7`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes: `resultados/20261104-094609-00-linha-de-base`, `20261104-095227-00-linha-de-base`, `20261104-095420-00-linha-de-base`
- Depois: `resultados/20261111-155609-03-top-produtos`, `20261111-155735-03-top-produtos`, `20261111-155901-03-top-produtos`

**Geral**

| Métrica | Antes | Depois |
|---|---|---|
| Requisições em 60 s | 308 | 324 |
| Requisições/s | 4.78 | 5.05 |
| Tempo de resposta, mediana | 800.1 ms | 816.4 ms |
| Tempo de resposta, p95 | 14401.8 ms | 14096.8 ms |
| Tempo de resposta, p99 | 16990.0 ms | 16521.1 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.8% | 98.3% |
| Memória máxima do banco (limite 512 MiB) | 283.6 MiB | 236.9 MiB |
| CPU média da API | 5.8% | 5.5% |
| Memória máxima da API (limite 256 MiB) | 40.5 MiB | 42.5 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Antes | Depois |
|---|---|---|
| `cliente` | 203.2 / 497.8 | 200.4 / 398.8 |
| `cliente-por-email` | 799.5 / 1401.1 | 896.3 / 1348.2 |
| `pedidos-do-cliente` | 12177.9 / 16231.5 | 12598.3 / 15851.2 |
| `pedidos-por-status` | 4598.7 / 14459.8 | 4701.5 / 11166.0 |
| `busca-produtos` | 494.1 / 732.6 | 403.6 / 801.3 |
| `vendas-por-dia` | 4614.2 / 6529.3 | 4627.5 / 6344.0 |
| `top-produtos` | 9902.8 / 15539.6 | 251.9 / 467.3 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **confirmada, com ganho geral pequeno**: a mediana de requisições/s subiu (4.78 → 5.05) e a de p95 geral caiu (14401.8 → 14096.8 ms), com o contrato mantido. Nas 3 execuções de cada lado, os valores não se sobrepõem, mas por pouco: requisições/s de 4.71 a 4.79 antes e de 4.85 a 5.10 depois; p95 de 14260.1 a 15731.8 ms antes e de 13283.3 a 14163.7 ms depois.

- **A rota mudou muito; a aplicação, pouco.** A mediana de `top-produtos` caiu de 9902.8 para 251.9 ms. As outras rotas ficaram parecidas com a linha de base, dentro da variação entre execuções.
- **Por que o ganho geral foi pequeno:** na aplicação original, `top-produtos` teve só 4 requisições por execução (de 308 a 324 no total). As outras rotas leem tabelas inteiras (`Seq Scan`) e continuam ocupando a CPU do banco, que ficou em 98.3%. Os 61.2% do diagnóstico 12 foram medidos sobre índices e pool, quando as outras consultas já eram baratas. É o mesmo efeito visto com o pool (seção 02): um gargalo esconde o outro.
- **A memória máxima do banco caiu** de 283.6 para 236.9 MiB (de 282.2–287.1 MiB antes para 221.9–238.6 MiB depois, sem sobreposição). Uma explicação provável, não testada: a soma de 1,5 milhão de itens usava memória para agrupar e processos paralelos (diagnóstico 08), e ela não roda mais durante a carga.
- **Custo:** dados defasados até o próximo refresh, ~0,7 s de banco por refresh e 3 MB de disco (seção Custo).
- **Limites:** medido sozinho, sobre a aplicação original. A mudança precisa ser medida também na branch `integracao`, onde o diagnóstico 12 indica que o ganho deve ser maior.

---

## 01+02+03 — Índices, pool e `top-produtos` pré-calculado juntos

Branch: `integracao`, com o merge de `hipotese/top-produtos` sobre a integração 01+02. Não há código novo: é a soma de [banco/03-indices.sql](banco/03-indices.sql), [api/src/db.js](api/src/db.js), [banco/04-top-produtos.sql](banco/04-top-produtos.sql) e da consulta nova de `top-produtos` em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

Com índices e pool, a consulta de `top-produtos` ficou com 61.2% do tempo do banco numa rodada de carga, sendo só 2% das requisições ([diagnostico/12](diagnostico/12-consumo-por-consulta.txt), na branch `feature/diagnostico-consumo`). Medida sozinha, sobre a aplicação original, a hipótese 03 teve ganho geral pequeno, porque as outras rotas ainda liam tabelas inteiras (seção 03).

**Se** a visão materializada for somada aos índices e ao pool, **então** o banco deixa de gastar a maior parte do tempo nessa soma e atende mais requisições por segundo, com p95 menor, do que a integração 01+02, sem mudar nenhuma resposta.

- **Comparação:** contra a integração 01+02 (`resultados/*-01-02-indices-pool`), não contra a linha de base.
- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à integração 01+02, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Atenção:** o tempo do diagnóstico 12 inclui a espera pela CPU, então os 61.2% não significam que a vazão vai crescer na mesma proporção. O que libera CPU é só o trabalho que a soma fazia.

### Resultado

Medido em 2026-11-11 no commit `e5ba40e`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes (01+02): `resultados/20261111-145918-01-02-indices-pool`, `20261111-150047-01-02-indices-pool`, `20261111-150210-01-02-indices-pool`
- Depois (01+02+03): `resultados/20261111-162052-01-02-03-indices-pool-top`, `20261111-162210-01-02-03-indices-pool-top`, `20261111-162329-01-02-03-indices-pool-top`

**Geral**

| Métrica | 01+02 | 01+02+03 |
|---|---|---|
| Requisições em 60 s | 2274 | 5925 |
| Requisições/s | 36.47 | 98.09 |
| Tempo de resposta, mediana | 129.8 ms | 105.7 ms |
| Tempo de resposta, p95 | 2467.9 ms | 788.6 ms |
| Tempo de resposta, p99 | 4696.5 ms | 1134.0 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 98.4% | 84.9% |
| Memória máxima do banco (limite 512 MiB) | 378.5 MiB | 240.0 MiB |
| CPU média da API (limite 50%) | 21.8% | 46.7% |
| Memória máxima da API (limite 256 MiB) | 55.4 MiB | 45.0 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | 01+02 | 01+02+03 |
|---|---|---|
| `cliente` | 44.1 / 228.3 | 12.5 / 190.3 |
| `cliente-por-email` | 40.5 / 203.7 | 13.4 / 189.3 |
| `pedidos-do-cliente` | 882.7 / 2706.3 | 532.7 / 1106.2 |
| `pedidos-por-status` | 302.2 / 4432.9 | 190.0 / 459.4 |
| `busca-produtos` | 94.6 / 261.8 | 97.9 / 213.1 |
| `vendas-por-dia` | 594.4 / 2053.5 | 204.0 / 408.8 |
| `top-produtos` | 3153.1 / 5361.1 | 14.1 / 181.7 |

### Conclusão

A hipótese foi **confirmada**: contra a integração 01+02, a mediana de requisições/s subiu (36.47 → 98.09) e a de p95 geral caiu (2467.9 → 788.6 ms), com o contrato mantido. Nas 3 execuções de cada lado, os valores não se sobrepõem: requisições/s de 36.37 a 37.22 antes e de 93.89 a 99.39 depois; p95 de 2309.1 a 2525.9 ms antes e de 782.6 a 800.0 ms depois.

- **De novo, um gargalo escondia o outro.** Sozinha, sobre a aplicação original, a hipótese 03 levou as requisições/s de 4.78 para 5.05 (seção 03). Sobre índices e pool, levou de 36.47 para 98.09, como o diagnóstico 12 indicava.
- **Todas as rotas melhoraram, não só `top-produtos`.** A CPU que a soma ocupava passou a atender as outras rotas. O p95 de `pedidos-por-status` caiu de 4432.9 para 459.4 ms, e o de `vendas-por-dia`, de 2053.5 para 408.8 ms. A exceção é a mediana de `busca-produtos` (94.6 → 97.9 ms), que ficou parecida.
- **O gargalo mudou de lugar.** Pela primeira vez, o banco não ficou no limite: CPU média de 84.9% (de 82.7% a 85.1% nas 3 execuções). Já a API ficou com 46.7% de CPU média, perto do seu limite de 0,5 CPU (50%), com máximas de 52.3% a 55.7% nas amostras. A próxima melhoria provavelmente está na API, não no banco. Isso ainda precisa de diagnóstico.
- **Custo:** nenhum serviço novo e nenhum limite alterado. A API passou a usar quase toda a CPU que tem, porque atende 98.09 requisições/s. A memória máxima do banco caiu de 378.5 para 240.0 MiB. Continua valendo o custo da visão: dados defasados até o próximo refresh (seção 03).
- **Limites:** a carga só faz leituras, então o refresh da visão não foi medido sob carga. Numa loja real, cada refresh custaria cerca de 0,7 s de banco (arquivo 13).

---

## 04 — `/clientes/:id/pedidos` com uma consulta (sem N+1)

Branch: `hipotese/pedidos-do-cliente`, criada a partir de `feature/diagnostico` (aplicação original, sem índices, sem pool e sem a visão de `top-produtos`). Mudança: a rota `/clientes/:id/pedidos` em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

A rota busca os pedidos do cliente e, dentro de um laço, faz uma consulta para os itens de cada pedido e outra para o produto de cada item ([diagnostico/README.md](diagnostico/README.md), item 4). Todo cliente tem 5 pedidos e, em média, 3 itens por pedido, então uma requisição faz em média 22 comandos SQL, um depois do outro ([diagnostico/15](diagnostico/15-pedidos-do-cliente-uma-consulta.txt)). Na aplicação original, cada consulta de itens lê a `itens_pedido` inteira (44,699 ms sozinha, [diagnostico/04](diagnostico/04-explain-pedidos-do-cliente.txt)) e abre uma conexão nova. Na integração 01+02+03, com índices e pool, a rota ainda tinha a maior mediana (532.7 ms) e o maior p95 (1106.2 ms) de todas (branch `integracao`).

**Se** a rota buscar pedidos, itens e nomes de produto numa consulta só, com `JOIN`, **então** cada requisição deixa de esperar 22 idas e voltas ao banco, o banco faz menos trabalho repetido, e a aplicação atende mais requisições por segundo, com tempo de resposta menor, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** sobre a aplicação original, o ganho deve aparecer principalmente porque a `itens_pedido` deixa de ser lida inteira 5 vezes por requisição (passa a ser lida uma vez). As outras rotas continuam lendo tabelas inteiras, então o banco deve seguir perto de 100% de CPU. Como nas hipóteses 02 e 03, a mudança também será medida na branch `integracao`, onde o efeito das idas e voltas deve pesar mais.

### O que mudou

Em [api/src/rotas.js](api/src/rotas.js), o laço com uma consulta por pedido e por item virou uma consulta:

```sql
SELECT p.id, p.status, p.criado_em,
       i.id AS item_id, i.produto_id, i.quantidade, i.preco_unitario_centavos,
       pr.nome AS produto_nome
  FROM pedidos p
  LEFT JOIN itens_pedido i ON i.pedido_id = p.id
  LEFT JOIN produtos pr ON pr.id = i.produto_id
 WHERE p.cliente_id = $1
 ORDER BY p.criado_em DESC, p.id DESC, i.id
```

- **Mesma ordem:** pedidos por `criado_em DESC, id DESC` e itens de cada pedido por `id`, como nas consultas antigas.
- **Mesmo cálculo:** o `total_centavos` continua sendo somado em JavaScript, item por item, como antes.
- **`LEFT JOIN`:** um pedido sem itens continuaria aparecendo, com `itens: []` e total 0, como no código original. Nos dados atuais não há pedido sem itens (diagnostico/15, parte 2).
- **404 igual:** a consulta do cliente continua antes, para devolver `cliente nao encontrado`.
- **Também deixou de trazer colunas não usadas:** a consulta antiga de pedidos trazia `observacoes` (`SELECT *`), que a resposta não usa.

### Fontes

- Chen, Shang, Jiang, Hassan, Nasser e Flora, [Detecting Performance Anti-patterns for Applications Developed using Object-Relational Mapping](https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf), ICSE 2014, p. 1001–1012, seção 2.2 "One-by-one Processing" (p. 1003): o anti-padrão em que a aplicação percorre uma lista e gera um `select` para cada elemento. A correção busca os elementos em lote e "reduces the number of SQL statements significantly". A seção 2.1 "Excessive Data" descreve o problema de trazer dados que a aplicação não usa.
- Ruby on Rails Guides, [Active Record Query Interface, "N + 1 Queries Problem"](https://guides.rubyonrails.org/active_record_querying.html): o exemplo de 10 livros e seus autores "executes 1 (to find 10 books) + 10 (one per each book to load the author) = 11 queries in total".

### Evidência antes de medir

[diagnostico/15-pedidos-do-cliente-uma-consulta.txt](diagnostico/15-pedidos-do-cliente-uma-consulta.txt), uma requisição por vez, sem carga:

| URL | Comandos SQL antes | Depois |
|---|---|---|
| `/clientes/4242/pedidos` | 17 | 2 |
| `/clientes/77/pedidos` | 17 | 2 |
| `/clientes/31337/pedidos` | 17 | 2 |

- **Mesma resposta:** para 300 clientes sorteados, a resposta nova é idêntica, em texto, à montada pela lógica antiga. O `verificar-contrato.sh comparar` terminou em "Contrato mantido".
- **Sem índices:** a consulta nova levou 200,168 ms sozinha (lê `pedidos` e `itens_pedido` inteiras uma vez). A antiga somava 19,281 ms dos pedidos e 44,699 ms por pedido, com a `itens_pedido` lida 5 vezes (diagnostico/04).

Esses tempos não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- Nenhum serviço novo, nenhum limite alterado, nenhum índice novo.
- **Memória da API:** a resposta continua sendo montada inteira na memória, como antes; a consulta traz uma linha por item (em média 15), com os dados do pedido repetidos em cada linha.
- **Manutenção:** a montagem da resposta passou a depender da ordem do `ORDER BY` (agrupa linhas seguidas do mesmo pedido). Quem mudar a consulta precisa manter essa ordem.

### Resultado

Medido em 2026-11-14 no commit `243f623`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes: `resultados/20261104-094609-00-linha-de-base`, `20261104-095227-00-linha-de-base`, `20261104-095420-00-linha-de-base`
- Depois: `resultados/20261114-165932-04-pedidos-do-cliente`, `20261114-170058-04-pedidos-do-cliente`, `20261114-170227-04-pedidos-do-cliente`

**Geral**

| Métrica | Antes | Depois |
|---|---|---|
| Requisições em 60 s | 308 | 511 |
| Requisições/s | 4.78 | 7.98 |
| Tempo de resposta, mediana | 800.1 ms | 686.0 ms |
| Tempo de resposta, p95 | 14401.8 ms | 6472.4 ms |
| Tempo de resposta, p99 | 16990.0 ms | 13487.7 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.8% | 94.1% |
| Memória máxima do banco (limite 512 MiB) | 283.6 MiB | 330.7 MiB |
| CPU média da API | 5.8% | 6.2% |
| Memória máxima da API (limite 256 MiB) | 40.5 MiB | 47.2 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Antes | Depois |
|---|---|---|
| `cliente` | 203.2 / 497.8 | 197.5 / 394.7 |
| `cliente-por-email` | 799.5 / 1401.1 | 611.7 / 1195.9 |
| `pedidos-do-cliente` | 12177.9 / 16231.5 | 4366.1 / 6306.9 |
| `pedidos-por-status` | 4598.7 / 14459.8 | 5440.9 / 15617.5 |
| `busca-produtos` | 494.1 / 732.6 | 301.0 / 613.5 |
| `vendas-por-dia` | 4614.2 / 6529.3 | 4618.1 / 6876.5 |
| `top-produtos` | 9902.8 / 15539.6 | 8896.7 / 10945.5 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **confirmada**: a mediana de requisições/s subiu (4.78 → 7.98) e a de p95 geral caiu (14401.8 → 6472.4 ms), com o contrato mantido. Nas 3 execuções de cada lado, os valores não se sobrepõem: requisições/s de 4.71 a 4.79 antes e de 7.68 a 8.24 depois; p95 de 14260.1 a 15731.8 ms antes e de 6390.9 a 7251.5 ms depois.

- **A rota mudou muito.** A mediana de `pedidos-do-cliente` caiu de 12177.9 para 4366.1 ms. Sem índices, a `itens_pedido` passou a ser lida uma vez por requisição, em vez de uma vez por pedido.
- **É o maior ganho isolado até aqui sobre a aplicação original** (01 sozinha levou a 19.73 req/s, mas 02 a 5.51 e 03 a 5.05). Como `pedidos-do-cliente` é 20% da carga e era a rota mais cara, sobrou CPU do banco para as outras rotas: `cliente-por-email` e `busca-produtos` também melhoraram.
- **`pedidos-por-status` e `vendas-por-dia` não melhoraram** (mediana 4598.7 → 5440.9 ms e 4614.2 → 4618.1 ms). O banco continua perto do limite (94.1% de CPU) e essas rotas continuam lendo e ordenando tabelas inteiras; com mais requisições por segundo, disputam a CPU com mais requisições das outras rotas. São poucas amostras por execução (72 e 35), então a diferença pode ser variação.
- **Custo:** nenhum serviço novo, nenhum limite e nenhum índice alterado. A memória máxima do banco subiu de 283.6 para 330.7 MiB; uma explicação provável, não testada, é a consulta nova usar `Parallel Hash` com mais processos ao mesmo tempo (diagnostico/15).
- **Limites:** medido sozinho, sobre a aplicação original. A mudança precisa ser medida na branch `integracao`, onde as consultas já são baratas e o custo que sobra é o das idas e voltas.

---

## 01+02+03+04 — Integração com `pedidos-do-cliente` sem N+1

Branch: `integracao`, com o merge de `hipotese/pedidos-do-cliente` sobre a integração 01+02+03. Não há código novo: é a soma das mudanças anteriores com a consulta única de [api/src/rotas.js](api/src/rotas.js) (seção 04).

### Hipótese

Na integração 01+02+03, `/clientes/:id/pedidos` ficou com 57.9% a 60.0% do tempo de espera dos usuários virtuais nas 3 execuções, sendo 20% das requisições ([diagnostico/14](diagnostico/14-tempo-por-rota.txt)). Quase nada disso é trabalho do banco: as consultas do N+1 somam 1.7% do tempo do banco ([diagnostico/12](diagnostico/12-consumo-por-consulta.txt), na branch `feature/diagnostico-consumo`). O tempo está nas ~22 idas e voltas por requisição, cada uma esperando uma das 10 conexões do pool e a CPU da API, que estava em 46.7% de um limite de 50%. Medida sozinha, a hipótese 04 já foi confirmada (seção 04).

**Se** a consulta única for somada a índices, pool e `top-produtos` pré-calculado, **então** `pedidos-do-cliente` deixa de segurar os usuários virtuais, e a aplicação atende mais requisições por segundo, com p95 menor, do que a integração 01+02+03, sem mudar nenhuma resposta.

- **Comparação:** contra a integração 01+02+03 (`resultados/*-01-02-03-indices-pool-top`), não contra a linha de base.
- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à integração 01+02+03, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Atenção:** com mais requisições por segundo, a CPU da API (já perto do limite) e a do banco (84.9%) devem subir. Se uma delas chegar ao limite, o ganho fica menor do que o tempo que a rota deixou de gastar.

### Resultado

Medido em 2026-11-14 no commit `6890de6`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes (01+02+03): `resultados/20261111-162052-01-02-03-indices-pool-top`, `20261111-162210-01-02-03-indices-pool-top`, `20261111-162329-01-02-03-indices-pool-top`
- Depois (01+02+03+04): `resultados/20261114-173736-01-a-04-integracao`, `20261114-173854-01-a-04-integracao`, `20261114-174013-01-a-04-integracao`

**Geral**

| Métrica | 01+02+03 | 01+02+03+04 |
|---|---|---|
| Requisições em 60 s | 5925 | 6142 |
| Requisições/s | 98.09 | 101.67 |
| Tempo de resposta, mediana | 105.7 ms | 181.6 ms |
| Tempo de resposta, p95 | 788.6 ms | 482.8 ms |
| Tempo de resposta, p99 | 1134.0 ms | 695.0 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 84.9% | 83.7% |
| Memória máxima do banco (limite 512 MiB) | 240.0 MiB | 251.6 MiB |
| CPU média da API (limite 50%) | 46.7% | 44.1% |
| Memória máxima da API (limite 256 MiB) | 45.0 MiB | 48.7 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | 01+02+03 | 01+02+03+04 |
|---|---|---|
| `cliente` | 12.5 / 190.3 | 100.2 / 299.2 |
| `cliente-por-email` | 13.4 / 189.3 | 101.7 / 313.4 |
| `pedidos-do-cliente` | 532.7 / 1106.2 | 192.7 / 423.3 |
| `pedidos-por-status` | 190.0 / 459.4 | 299.4 / 682.6 |
| `busca-produtos` | 97.9 / 213.1 | 181.9 / 364.2 |
| `vendas-por-dia` | 204.0 / 408.8 | 305.5 / 607.2 |
| `top-produtos` | 14.1 / 181.7 | 102.7 / 301.6 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **confirmada**: contra a integração 01+02+03, a mediana de requisições/s subiu (98.09 → 101.67) e a de p95 geral caiu (788.6 → 482.8 ms), com o contrato mantido. Nas 3 execuções de cada lado, os valores não se sobrepõem: requisições/s de 93.89 a 99.39 antes e de 101.23 a 102.25 depois; p95 de 782.6 a 800.0 ms antes e de 479.3 a 484.1 ms depois.

- **A cauda caiu, a vazão quase não subiu.** `pedidos-do-cliente` caiu de 532.7 para 192.7 ms de mediana, o p95 geral caiu de 788.6 para 482.8 ms e o p99, de 1134.0 para 695.0 ms. Mas as requisições/s subiram só de 98.09 para 101.67, bem menos do que a parte do tempo que essa rota ocupava (57.9% a 60.0%, diagnostico/14) faria esperar.
- **O tempo foi redistribuído entre as rotas.** As rotas rápidas pioraram: `cliente` foi de 12.5 para 100.2 ms de mediana, e a mediana geral subiu de 105.7 para 181.6 ms. Sem o N+1, o tempo de espera ficou espalhado: `pedidos-por-status` passou a ser a maior parte (24.8% a 25.6%), seguida de `pedidos-do-cliente` (21.8% a 22.1%) (diagnostico/14, parte nova).
- **Explicação provável: o limite agora é a CPU da API.** A CPU média da API ficou em 44.1% (44.0% a 48.0%), com máximas de 51.4% a 53.5% nas amostras, no limite de 0,5 CPU. O banco ficou com folga (83.7%). Com a API sem CPU sobrando, liberar tempo numa rota não aumenta muito a vazão: as outras requisições passam a esperar a API. Isso ainda é uma explicação, não medida diretamente; as hipóteses 05 e 06 tiram trabalho da API e vão testá-la.
- **Custo:** nenhum serviço novo, nenhum limite e nenhum índice alterado. Memória máxima da API 48.7 MiB (antes 45.0) e do banco 251.6 MiB (antes 240.0).
- **Limites:** o ganho em vazão é pequeno, mas fora da variação; a queda de p95 e p99 é maior. A piora da mediana geral e das rotas rápidas é real (faixas sem sobreposição: mediana geral de 181.4 a 181.8 ms, contra 104.6 a 109.6 ms antes).

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

---

## 01+…+05 — Integração com o log sem o corpo da resposta

Branch: `integracao`, com o merge de `hipotese/log-resposta` sobre a integração 01 a 04. Não há código novo: é a soma das mudanças anteriores com o log de [api/src/server.js](api/src/server.js) (seção 05).

### Hipótese

Na integração 01 a 04, a CPU da API ficou em 44.1% de média, com máximas de 51.4% a 53.5%, no limite de 0,5 CPU, e o banco ficou com folga (83.7%). A vazão quase não subiu ao tirar o N+1, e as rotas rápidas passaram a esperar mais (seção 01+…+04). Medida sozinha, a hipótese 05 não teve ganho, porque lá a API usava 5.5% de CPU (seção 05). Cada requisição ainda converte o corpo inteiro da resposta para JSON uma vez a mais, só para o log, e escreve no log de 206 a 1983 bytes ([diagnostico/16](diagnostico/16-log-sem-corpo.txt)).

**Se** o log deixar de levar o corpo da resposta, **então** a API gasta menos CPU por requisição e atende mais requisições por segundo, com p95 menor, do que a integração 01 a 04, sem mudar nenhuma resposta.

- **Comparação:** contra a integração 01 a 04 (`resultados/*-01-a-04-integracao`).
- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à integração 01 a 04, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Atenção:** se a CPU da API cair e a vazão subir, a CPU do banco deve subir junto; o banco pode voltar a ser o limite.

### Resultado

Medido em 2026-11-14 no commit `b995852`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes (01 a 04): `resultados/20261114-173736-01-a-04-integracao`, `20261114-173854-01-a-04-integracao`, `20261114-174013-01-a-04-integracao`
- Depois (01 a 05): `resultados/20261114-174333-01-a-05-integracao`, `20261114-174452-01-a-05-integracao`, `20261114-174611-01-a-05-integracao`

**Geral**

| Métrica | 01 a 04 | 01 a 05 |
|---|---|---|
| Requisições em 60 s | 6142 | 5951 |
| Requisições/s | 101.67 | 98.90 |
| Tempo de resposta, mediana | 181.6 ms | 131.2 ms |
| Tempo de resposta, p95 | 482.8 ms | 566.8 ms |
| Tempo de resposta, p99 | 695.0 ms | 1112.3 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 83.7% | 80.0% |
| Memória máxima do banco (limite 512 MiB) | 251.6 MiB | 247.8 MiB |
| CPU média da API (limite 50%) | 44.1% | 45.4% |
| Memória máxima da API (limite 256 MiB) | 48.7 MiB | 60.9 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | 01 a 04 | 01 a 05 |
|---|---|---|
| `cliente` | 100.2 / 299.2 | 87.0 / 311.7 |
| `cliente-por-email` | 101.7 / 313.4 | 89.6 / 319.6 |
| `pedidos-do-cliente` | 192.7 / 423.3 | 173.5 / 447.4 |
| `pedidos-por-status` | 299.4 / 682.6 | 296.6 / 1245.6 |
| `busca-produtos` | 181.9 / 364.2 | 110.2 / 354.0 |
| `vendas-por-dia` | 305.5 / 607.2 | 408.1 / 815.9 |
| `top-produtos` | 102.7 / 301.6 | 94.3 / 343.7 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **refutada**: contra a integração 01 a 04, a mediana de requisições/s caiu (101.67 → 98.90) e a de p95 geral subiu (482.8 → 566.8 ms). Nas 3 execuções de cada lado, os valores não se sobrepõem: requisições/s de 101.23 a 102.25 antes e de 95.23 a 100.84 depois; p95 de 479.3 a 484.1 ms antes e de 507.2 a 605.6 ms depois.

- **A CPU da API não caiu** (44.1% → 45.4%; de 44.4% a 45.9% nas 3 execuções, com máximas de 50.6% a 52.6%). Converter o corpo para o log e escrevê-lo não era o que ocupava a CPU da API. A hipótese de que o log fosse o custo principal da API (diagnóstico item 9) não se sustenta.
- **A piora provavelmente não é efeito do log.** Tirar o corpo do log só tira trabalho da API, e as 3 execuções variaram mais entre si do que as da integração 01 a 04 (mediana geral de 126.9 a 176.8 ms; p99 de 727.7 a 1387.9 ms). Uma explicação provável, não testada, é variação do ambiente entre as rodadas. Mesmo assim, pelo critério, não há ganho para mostrar.
- **Pista para a próxima hipótese:** na medição isolada da hipótese 06, a CPU da API caiu de 5.8% para 2.0% só por somar `vendas-por-dia` no banco. Isso indica que a soma de ~13 mil linhas por chamada pesa mais na API do que o log.
- **Decisão:** sem ganho, a mudança de [api/src/server.js](api/src/server.js) foi desfeita na branch `integracao` (commit seguinte a este), para a hipótese 06 ser medida sobre a integração 01 a 04. As medições e esta seção ficam como registro. O log sem o corpo continua sendo uma boa prática (diagnostico/16: 68 a 115 bytes por requisição, em vez de 206 a 1983), mas não tem ganho de desempenho medido.
- **Custo:** nenhum recurso a mais.

---

## 06 — `vendas-por-dia` somando no banco

Branch: `hipotese/vendas-por-dia-sql`, criada a partir de `feature/diagnostico` (aplicação original, sem índices, sem pool e sem a visão de `top-produtos`). Mudança: a rota `/relatorios/vendas-por-dia` em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

A rota busca uma linha por item vendido no período, com a coluna `observacoes`, e soma por dia em JavaScript ([diagnostico/README.md](diagnostico/README.md), item 6). Num período de 7 dias, o tamanho que a carga usa, são 12951 linhas por requisição, com 3555995 caracteres só de `observacoes`, que a resposta não usa ([diagnostico/17](diagnostico/17-vendas-por-dia-soma-no-banco.txt)). Na integração 01+02+03 essa rota ficou com 9.1% do tempo total de espera dos usuários virtuais e a API ficou perto do limite de CPU (branch `integracao`).

**Se** o banco fizer a soma por dia (`GROUP BY`) e devolver só uma linha por dia, **então** a API deixa de receber, converter e somar milhares de linhas por requisição, e a aplicação atende mais requisições por segundo, com tempo de resposta menor, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** ganho pequeno ou nenhum medido sozinho. Sem índices, o banco ainda lê `pedidos` e `itens_pedido` inteiras nas duas versões (212,288 ms contra 221,655 ms, diagnostico/17), e o gargalo da aplicação original é a CPU do banco. O efeito esperado é na branch `integracao`, onde a API está perto do limite de CPU.

### O que mudou

Em [api/src/rotas.js](api/src/rotas.js), a rota passou a pedir a soma pronta:

```sql
SELECT to_char(p.criado_em::date, 'YYYY-MM-DD') AS dia,
       count(DISTINCT p.id) AS pedidos,
       sum(i.quantidade) AS itens,
       sum(i.quantidade::bigint * i.preco_unitario_centavos) AS receita_centavos
  FROM pedidos p
  JOIN itens_pedido i ON i.pedido_id = p.id
 WHERE p.criado_em::date BETWEEN $1 AND $2
   AND p.status <> 'cancelado'
 GROUP BY p.criado_em::date
 ORDER BY p.criado_em::date
```

- **Mesmo filtro:** `criado_em::date BETWEEN` e `status <> 'cancelado'` ficaram iguais, para a mudança ser só onde a soma acontece. O índice `pedidos((criado_em::date))` da hipótese 01 continua servindo na integração.
- **Mesmas contas:** `pedidos` conta pedidos distintos (antes, um `Set` de ids); `itens` soma quantidades; `receita_centavos` soma `quantidade × preço`. A multiplicação é feita em `bigint` para não estourar o tipo `integer` do PostgreSQL.
- **Mesmo formato:** `count` e `sum` voltam como texto no node-postgres (são `bigint`/`numeric`); `Number()` devolve os mesmos números que a soma em JavaScript dava. A ordem é por dia, como o `sort` antigo.
- **Sem `observacoes`:** a coluna não é mais lida pela rota.

### Fontes

- PostgreSQL 16, [2.7 — Aggregate Functions](https://www.postgresql.org/docs/16/tutorial-agg.html): "An aggregate function computes a single result from multiple input rows"; com `GROUP BY`, a consulta devolve "one output row per" grupo.
- Chen et al., [Detecting Performance Anti-patterns for Applications Developed using Object-Relational Mapping](https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf), ICSE 2014, seção 2.1 "Excessive Data" (p. 1002–1003): trazer do banco dados que a aplicação não usa é um anti-padrão de desempenho; no exemplo do artigo, corrigir isso reduziu o tempo de resposta de 1,68 s para 0,48 s.

### Evidência antes de medir

[diagnostico/17-vendas-por-dia-soma-no-banco.txt](diagnostico/17-vendas-por-dia-soma-no-banco.txt), período de 2024-03-01 a 2024-03-07, uma consulta por vez, sem carga:

| | Antes | Depois |
|---|---|---|
| Linhas enviadas do banco para a API | 12951 | 7 |
| Caracteres de `observacoes` enviados | 3555995 | 0 |
| Tempo da consulta no banco, sem índices | 221,655 ms | 212,288 ms |
| Corpo da resposta HTTP | 540 B | 540 B |

- **Mesma resposta:** em 68 períodos (60 sorteados de 7 dias, os extremos, períodos de 1 e de 31 dias e 2 sem vendas), a resposta nova é idêntica, em texto, à montada pela lógica antiga. O `verificar-contrato.sh comparar` terminou em "Contrato mantido".

Esses tempos não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- Nenhum serviço novo, nenhum limite e nenhum índice alterado.
- **CPU do banco:** o banco passa a fazer a soma e a ordenação por dia (um `GroupAggregate` sobre ~13 mil linhas, em memória, diagnostico/17). Em troca, deixa de enviar as 12951 linhas pela rede.

### Resultado

Medido em 2026-11-14 no commit `403c8ad`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes: `resultados/20261104-094609-00-linha-de-base`, `20261104-095227-00-linha-de-base`, `20261104-095420-00-linha-de-base`
- Depois: `resultados/20261114-171517-06-vendas-por-dia-sql`, `20261114-171647-06-vendas-por-dia-sql`, `20261114-171816-06-vendas-por-dia-sql`

**Geral**

| Métrica | Antes | Depois |
|---|---|---|
| Requisições em 60 s | 308 | 295 |
| Requisições/s | 4.78 | 4.49 |
| Tempo de resposta, mediana | 800.1 ms | 897.9 ms |
| Tempo de resposta, p95 | 14401.8 ms | 15030.4 ms |
| Tempo de resposta, p99 | 16990.0 ms | 20863.1 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.8% | 98.3% |
| Memória máxima do banco (limite 512 MiB) | 283.6 MiB | 307.2 MiB |
| CPU média da API | 5.8% | 2.0% |
| Memória máxima da API (limite 256 MiB) | 40.5 MiB | 28.5 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Antes | Depois |
|---|---|---|
| `cliente` | 203.2 / 497.8 | 197.8 / 391.8 |
| `cliente-por-email` | 799.5 / 1401.1 | 801.8 / 1495.2 |
| `pedidos-do-cliente` | 12177.9 / 16231.5 | 12800.2 / 15973.0 |
| `pedidos-por-status` | 4598.7 / 14459.8 | 4652.3 / 12257.8 |
| `busca-produtos` | 494.1 / 732.6 | 399.8 / 764.4 |
| `vendas-por-dia` | 4614.2 / 6529.3 | 4800.3 / 6685.4 |
| `top-produtos` | 9902.8 / 15539.6 | 18069.4 / 21163.9 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **refutada quando medida sozinha: aplicada sem ganho**. A mediana de requisições/s caiu (4.78 → 4.49) e a de p95 geral subiu (14401.8 → 15030.4 ms). Nas 3 execuções de cada lado, as requisições/s não se sobrepõem (4.71 a 4.79 antes, 4.40 a 4.53 depois); o p95 se sobrepõe (14260.1 a 15731.8 ms antes, 14444.7 a 15494.9 ms depois).

- **A CPU da API caiu para cerca de um terço** (5.8% → 2.0%, de 2.0% a 2.4% nas 3 execuções) e a memória máxima da API caiu de 40.5 para 28.5 MiB. Receber e somar ~13 mil linhas por chamada de `vendas-por-dia` era a maior parte do trabalho da API na aplicação original, mesmo com essa rota sendo 8% da carga.
- **Mas o gargalo aqui é o banco** (98.3% de CPU). A mudança tirou trabalho de quem tinha folga (a API) e passou a soma e a ordenação por dia para quem não tinha (o banco). A rota `vendas-por-dia` ficou parecida (mediana 4614.2 → 4800.3 ms), porque o tempo dela é a leitura das duas tabelas inteiras, que não mudou.
- **Uma explicação provável para a pequena piora, não testada:** o `GroupAggregate` com ordenação, que antes rodava na API, agora usa CPU do banco, e as outras rotas esperam mais por ela.
- **Custo:** nenhum recurso a mais. O banco passa a somar e ordenar por dia; a rede deixa de levar ~13 mil linhas e ~3,5 milhões de caracteres de `observacoes` por chamada.
- **Limites:** a hipótese existe pelo estado da integração 01+02+03, em que a API está perto do limite e o banco tem folga (84.9%). Lá, com o índice em `criado_em::date`, a leitura fica barata e o efeito na CPU da API deve aparecer. Precisa ser medida na branch `integracao`.

---

## 01+…+04+06 — Integração com `vendas-por-dia` somando no banco

Branch: `integracao`, com o merge de `hipotese/vendas-por-dia-sql` sobre a integração 01 a 04 (a hipótese 05 foi desfeita, seção 01+…+05). Não há código novo: é a soma das mudanças anteriores com a consulta de `vendas-por-dia` de [api/src/rotas.js](api/src/rotas.js) (seção 06).

### Hipótese

Na integração 01 a 04, a CPU da API está no limite (44.1% de média, máximas de 51.4% a 53.5%) e o banco tem folga (83.7%). Tirar o corpo do log não reduziu a CPU da API (seção 01+…+05). Já a hipótese 06, medida sozinha, reduziu a CPU da API de 5.8% para 2.0% (seção 06): receber e somar ~13 mil linhas por chamada de `vendas-por-dia` era a maior parte do trabalho da API na aplicação original. Com os índices da hipótese 01, as duas versões da consulta são baratas no banco (10,577 ms a antiga, 13,512 ms a nova); a diferença é que a antiga manda 12951 linhas para a API e a nova, 7 ([diagnostico/20](diagnostico/20-vendas-por-dia-na-integracao.txt)).

**Se** `vendas-por-dia` somar no banco, **então** a API, que agora é o limite, gasta menos CPU por requisição e atende mais requisições por segundo, com p95 menor, do que a integração 01 a 04, sem mudar nenhuma resposta.

- **Comparação:** contra a integração 01 a 04 (`resultados/*-01-a-04-integracao`).
- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à integração 01 a 04, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Atenção:** o banco passa a fazer a soma; com mais vazão, a CPU do banco deve subir e ele pode voltar a ser o limite.

### Resultado

Medido em 2026-11-14 no commit `fd4732b`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes (01 a 04): `resultados/20261114-173736-01-a-04-integracao`, `20261114-173854-01-a-04-integracao`, `20261114-174013-01-a-04-integracao`
- Depois (01 a 04 + 06): `resultados/20261114-174941-01-a-04-06-integracao`, `20261114-175100-01-a-04-06-integracao`, `20261114-175218-01-a-04-06-integracao`

**Geral**

| Métrica | 01 a 04 | 01 a 04 + 06 |
|---|---|---|
| Requisições em 60 s | 6142 | 6661 |
| Requisições/s | 101.67 | 110.23 |
| Tempo de resposta, mediana | 181.6 ms | 105.1 ms |
| Tempo de resposta, p95 | 482.8 ms | 497.8 ms |
| Tempo de resposta, p99 | 695.0 ms | 1005.7 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 83.7% | 99.2% |
| Memória máxima do banco (limite 512 MiB) | 251.6 MiB | 272.4 MiB |
| CPU média da API (limite 50%) | 44.1% | 5.6% |
| Memória máxima da API (limite 256 MiB) | 48.7 MiB | 29.1 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | 01 a 04 | 01 a 04 + 06 |
|---|---|---|
| `cliente` | 100.2 / 299.2 | 94.9 / 193.0 |
| `cliente-por-email` | 101.7 / 313.4 | 95.6 / 194.0 |
| `pedidos-do-cliente` | 192.7 / 423.3 | 119.1 / 294.1 |
| `pedidos-por-status` | 299.4 / 682.6 | 305.7 / 1097.3 |
| `busca-produtos` | 181.9 / 364.2 | 188.7 / 295.6 |
| `vendas-por-dia` | 305.5 / 607.2 | 307.4 / 692.5 |
| `top-produtos` | 102.7 / 301.6 | 94.5 / 193.8 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **confirmada só em parte**: contra a integração 01 a 04, a mediana de requisições/s subiu (101.67 → 110.23; de 101.23 a 102.25 antes e de 108.16 a 112.03 depois, sem sobreposição), mas a de p95 geral subiu um pouco (482.8 → 497.8 ms; de 479.3 a 484.1 ms antes e de 496.7 a 499.4 ms depois, sem sobreposição). O critério exigia as duas coisas.

- **A CPU da API caiu de 44.1% para 5.6%** (de 5.4% a 5.9% nas 3 execuções, com máximas de 7.8% a 9.5%), atendendo mais requisições por segundo. A memória máxima da API caiu de 48.7 para 29.1 MiB. Era a soma de `vendas-por-dia` em JavaScript que ocupava a API, não o log (seção 01+…+05). Isso explica o resultado da integração 01 a 04: a API estava no limite por causa dessa rota, que é só 8% das requisições.
- **O gargalo voltou para o banco**, que foi de 83.7% para 99.2% de CPU. Com a API livre, as requisições chegam mais rápido ao banco, e o que ele faz por requisição passou a decidir a vazão.
- **A cauda agora é `pedidos-por-status`.** Ela foi a única rota cujo p95 subiu muito (682.6 → 1097.3 ms) e passou a ter de 31.5% a 34.9% do tempo de espera dos usuários virtuais ([diagnostico/14](diagnostico/14-tempo-por-rota.txt), parte nova). É ela que puxa o p95 e o p99 gerais para cima. As outras rotas melhoraram ou ficaram iguais na mediana, e todas, menos `pedidos-por-status` e `vendas-por-dia`, tiveram p95 menor.
- **Decisão:** apesar do p95 geral um pouco maior, a mudança **fica na branch `integracao`**. Ela reduziu a CPU média da API de 44.1% para 5.6%, aumentou a vazão e a mediana geral caiu de 181.6 para 105.1 ms; e o que subiu o p95 é a rota que as hipóteses 07 e 08 atacam. Essa decisão é discutível pelo critério escrito antes de medir, e fica registrada aqui para revisão.
- **Custo:** nenhum serviço novo e nenhum limite alterado. O banco passou a usar quase toda a sua CPU (99.2%). A API passou a usar pouco do 0,5 CPU que tem; numa próxima rodada, o limite de CPU da API poderia ser reduzido para economizar recurso (não testado).

---

## 07 — Índice de cobertura para `/pedidos?status=`

Branch: `hipotese/status-indice-cobertura`, criada a partir de `feature/diagnostico` (aplicação original, sem os índices da hipótese 01, sem pool e sem a visão de `top-produtos`). Mudanças: [banco/05-indice-status-cobertura.sql](banco/05-indice-status-cobertura.sql) e a consulta da página em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

A rota `/pedidos?status=&pagina=` faz duas consultas: um `count(*)` do status e uma página com `ORDER BY criado_em DESC, id DESC LIMIT 20 OFFSET (pagina-1)*20`, com páginas de 1 a 1000 na carga. A página pede `SELECT *`, mas a resposta usa só `id`, `cliente_id`, `status` e `criado_em`. Na aplicação original, a página 1000 de `pago` ordena 300 mil linhas em disco (~90 MB nos 3 processos) e leva 166,325 ms sozinha ([diagnostico/18](diagnostico/18-status-indice-cobertura.txt)). Mesmo com o índice `(status, criado_em DESC, id DESC)` da hipótese 01, a página ainda gravava arquivos temporários sob carga (17792 blocos, [diagnostico/12](diagnostico/12-consumo-por-consulta.txt), na branch `feature/diagnostico-consumo`). Uma explicação provável, a confirmar na integração: com `SELECT *`, cada linha pulada pelo `OFFSET` precisa ser buscada na tabela, e para páginas fundas o planejador prefere ler e ordenar tudo.

**Se** a página pedir só as 4 colunas da resposta e existir um índice que tenha todas elas (`(status, criado_em DESC, id DESC) INCLUDE (cliente_id)`), **então** o `OFFSET` pula as linhas lendo só o índice (`Index Only Scan`), sem ordenar e sem visitar a tabela, e a aplicação atende mais requisições por segundo, com tempo de resposta menor, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** medida sozinha, o índice também serve ao `count(*)` (de `Seq Scan` para `Index Only Scan`, 87,107 → 15,510 ms, diagnostico/18), então `pedidos-por-status` deve melhorar bastante. As outras rotas continuam lendo tabelas inteiras e devem melhorar pouco.

### O que mudou

- **`banco/05-indice-status-cobertura.sql`:** cria `pedidos (status, criado_em DESC, id DESC) INCLUDE (cliente_id)` e roda `VACUUM (ANALYZE) pedidos`, para o mapa de visibilidade permitir `Index Only Scan` sem visitar a tabela. O arquivo também apaga o índice `pedidos_status_criado_idx` da hipótese 01, se ele existir (`DROP INDEX IF EXISTS`): o índice novo tem as mesmas colunas de busca e ordenação, mais o `cliente_id`, então o antigo fica redundante. Nesta branch, sem a hipótese 01, o `DROP` não faz nada.
- **`api/src/rotas.js`:** a consulta da página troca `SELECT *` por `SELECT id, cliente_id, status, criado_em`. Filtro, ordem, `LIMIT` e `OFFSET` ficaram iguais; o `count(*)` não mudou.

### Fontes

- PostgreSQL 16, [CREATE INDEX, parâmetro `INCLUDE`](https://www.postgresql.org/docs/16/sql-createindex.html): colunas não-chave permitem que "an index-only scan can return the contents of non-key columns without having to visit the index's table"; a página também avisa que essas colunas "duplicate data from the index's table and bloat the size of the index".
- PostgreSQL 16, [7.6 — LIMIT and OFFSET](https://www.postgresql.org/docs/16/queries-limit.html): "The rows skipped by an OFFSET clause still have to be computed inside the server; therefore a large OFFSET might be inefficient."
- PostgreSQL 16, [11.9 — Index-Only Scans](https://www.postgresql.org/docs/16/indexes-index-only-scans.html): o `Index Only Scan` só evita a tabela para páginas marcadas como visíveis no mapa de visibilidade (já citada na hipótese 01).
- Chen et al., [ICSE 2014](https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf), seção 2.1 "Excessive Data": trazer colunas que a aplicação não usa é um anti-padrão de desempenho. Aqui, o `SELECT *` também impede o `Index Only Scan`, porque `observacoes` não está no índice.

### Evidência antes de medir

[diagnostico/18-status-indice-cobertura.txt](diagnostico/18-status-indice-cobertura.txt), status `pago`, uma consulta por vez, sem carga:

| Consulta | Antes | Depois |
|---|---|---|
| Página 1000 (`OFFSET 19980`) | 166,325 ms, `Seq Scan` + ordenação em disco | 2,548 ms, `Index Only Scan`, `Heap Fetches: 0` |
| `count(*)` | 87,107 ms, `Seq Scan` | 15,510 ms, `Index Only Scan` |

- **Mesma resposta:** em 216 páginas (200 sorteadas e as páginas 1, 1000, 1251 e 99999 de cada status), a resposta nova é idêntica, em texto, à montada com a consulta antiga. O `verificar-contrato.sh comparar` terminou em "Contrato mantido".

Esses tempos não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- **Disco:** 21 MB do índice novo (diagnostico/18). Na integração, o índice da hipótese 01 que ele substitui deixa de existir.
- **Escrita:** cada `INSERT` em `pedidos` e cada `UPDATE` de `status` atualizam mais um índice (nesta branch) ou o mesmo número de índices (na integração, porque substitui o da hipótese 01). A carga só faz leituras, então esse custo não aparece na medição.
- **Manutenção:** o `Index Only Scan` depende do mapa de visibilidade em dia; numa tabela com muitas escritas, o autovacuum precisa acompanhar.
- **Acoplamento:** se alguém voltar a pedir `SELECT *` na página, o índice deixa de cobrir a consulta.

### Resultado

Medido em 2026-11-14 no commit `eb35522`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes: `resultados/20261104-094609-00-linha-de-base`, `20261104-095227-00-linha-de-base`, `20261104-095420-00-linha-de-base`
- Depois: `resultados/20261114-172308-07-status-indice-cobertura`, `20261114-172435-07-status-indice-cobertura`, `20261114-172603-07-status-indice-cobertura`

**Geral**

| Métrica | Antes | Depois |
|---|---|---|
| Requisições em 60 s | 308 | 341 |
| Requisições/s | 4.78 | 5.31 |
| Tempo de resposta, mediana | 800.1 ms | 787.4 ms |
| Tempo de resposta, p95 | 14401.8 ms | 14592.6 ms |
| Tempo de resposta, p99 | 16990.0 ms | 17245.4 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.8% | 99.9% |
| Memória máxima do banco (limite 512 MiB) | 283.6 MiB | 294.1 MiB |
| CPU média da API | 5.8% | 5.4% |
| Memória máxima da API (limite 256 MiB) | 40.5 MiB | 42.3 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Antes | Depois |
|---|---|---|
| `cliente` | 203.2 / 497.8 | 293.6 / 502.7 |
| `cliente-por-email` | 799.5 / 1401.1 | 996.9 / 1540.2 |
| `pedidos-do-cliente` | 12177.9 / 16231.5 | 12794.8 / 16873.0 |
| `pedidos-por-status` | 4598.7 / 14459.8 | 704.3 / 1382.2 |
| `busca-produtos` | 494.1 / 732.6 | 498.2 / 831.0 |
| `vendas-por-dia` | 4614.2 / 6529.3 | 4111.9 / 7368.7 |
| `top-produtos` | 9902.8 / 15539.6 | 16112.6 / 17581.4 |

### Conclusão

Pelo critério definido antes de medir, a hipótese **não foi confirmada quando medida sozinha**: a mediana de requisições/s subiu (4.78 → 5.31, sem sobreposição: 4.71 a 4.79 antes, 5.10 a 5.40 depois), mas a de p95 geral não caiu (14401.8 → 14592.6 ms, com sobreposição: 14260.1 a 15731.8 ms antes, 14398.9 a 15426.0 ms depois). O critério exigia as duas coisas.

- **A rota mudou muito.** `pedidos-por-status` caiu de 4598.7 para 704.3 ms de mediana e de 14459.8 para 1382.2 ms de p95, como o `EXPLAIN` indicava (diagnostico/18): a página e a contagem deixaram de ler a tabela inteira.
- **Por que o p95 geral não caiu:** o p95 geral é formado pelas requisições mais lentas, e elas são de `pedidos-do-cliente` (p95 16873.0 ms) e `top-produtos` (17581.4 ms), que continuam lendo tabelas inteiras. O banco continua em 99.9% de CPU; a CPU que a rota liberou foi usada para atender mais requisições (341 contra 308), não para atender mais rápido as outras.
- **As rotas rápidas pioraram um pouco na mediana** (`cliente` 203.2 → 293.6 ms, `cliente-por-email` 799.5 → 996.9 ms). Uma explicação provável, não testada: com mais requisições por segundo e o banco ainda no limite, há mais consultas disputando a mesma CPU.
- **Custo:** 21 MB de disco do índice (diagnostico/18); nenhum serviço novo e nenhum limite alterado. O custo de escrita não foi medido, porque a carga só faz leituras.
- **Limites:** medida sozinha, sobre a aplicação original. A comparação que interessa é na branch `integracao`, contra o índice da hipótese 01, que o arquivo novo substitui.

---

## 01+…+04+06+07 — Integração com o índice de cobertura por status

Branch: `integracao`, com o merge de `hipotese/status-indice-cobertura` sobre a integração 01 a 04 + 06. Mudanças da hipótese 07: [banco/05-indice-status-cobertura.sql](banco/05-indice-status-cobertura.sql) e a consulta da página em [api/src/rotas.js](api/src/rotas.js). Aqui o arquivo novo apaga o índice `pedidos_status_criado_idx` da hipótese 01, que fica redundante.

### Hipótese

Na integração 01 a 04 + 06, o banco voltou ao limite (99.2% de CPU) e `pedidos-por-status` passou a ter de 31.5% a 34.9% do tempo de espera dos usuários virtuais, com p95 de 1097.3 ms ([diagnostico/14](diagnostico/14-tempo-por-rota.txt)). Com o índice da hipótese 01, a página 1000 ainda busca ~20 mil linhas na tabela (`Index Scan`, 11,387 a 14,876 ms) e, para `pendente`, o planejador troca para `Bitmap Heap Scan` com ordenação de ~4 MB (115,023 ms) ([diagnostico/21](diagnostico/21-status-cobertura-na-integracao.txt)). Com o índice de cobertura e só as 4 colunas da resposta, as 4 páginas ficam entre 1,928 e 2,028 ms, sem visitar a tabela (`Heap Fetches: 0`).

**Se** a página for lida só do índice, **então** o banco gasta menos CPU em `pedidos-por-status`, e a aplicação atende mais requisições por segundo, com p95 menor, do que a integração 01 a 04 + 06, sem mudar nenhuma resposta.

- **Comparação:** contra a integração 01 a 04 + 06 (`resultados/*-01-a-04-06-integracao`).
- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à integração 01 a 04 + 06, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Atenção:** o `count(*)` da mesma rota quase não muda (13,982 → 12,598 ms, diagnostico/21); ele é o alvo da hipótese 08.

### Resultado

Medido em 2026-11-14 no commit `89254ec`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes (01 a 04 + 06): `resultados/20261114-174941-01-a-04-06-integracao`, `20261114-175100-01-a-04-06-integracao`, `20261114-175218-01-a-04-06-integracao`
- Depois (01 a 04 + 06 + 07): `resultados/20261114-175616-01-a-04-06-07-integracao`, `20261114-175733-01-a-04-06-07-integracao`, `20261114-175851-01-a-04-06-07-integracao`

**Geral**

| Métrica | 01 a 04 + 06 | 01 a 04 + 06 + 07 |
|---|---|---|
| Requisições em 60 s | 6661 | 9720 |
| Requisições/s | 110.23 | 161.25 |
| Tempo de resposta, mediana | 105.1 ms | 88.3 ms |
| Tempo de resposta, p95 | 497.8 ms | 482.9 ms |
| Tempo de resposta, p99 | 1005.7 ms | 1010.5 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.2% | 98.4% |
| Memória máxima do banco (limite 512 MiB) | 272.4 MiB | 225.3 MiB |
| CPU média da API (limite 50%) | 5.6% | 6.6% |
| Memória máxima da API (limite 256 MiB) | 29.1 MiB | 31.4 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | 01 a 04 + 06 | 01 a 04 + 06 + 07 |
|---|---|---|
| `cliente` | 94.9 / 193.0 | 36.9 / 104.7 |
| `cliente-por-email` | 95.6 / 194.0 | 34.4 / 103.8 |
| `pedidos-do-cliente` | 119.1 / 294.1 | 100.1 / 198.1 |
| `pedidos-por-status` | 305.7 / 1097.3 | 109.0 / 225.4 |
| `busca-produtos` | 188.7 / 295.6 | 84.0 / 156.7 |
| `vendas-por-dia` | 307.4 / 692.5 | 550.8 / 1226.2 |
| `top-produtos` | 94.5 / 193.8 | 30.6 / 117.6 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **confirmada**: contra a integração 01 a 04 + 06, a mediana de requisições/s subiu (110.23 → 161.25) e a de p95 geral caiu (497.8 → 482.9 ms), com o contrato mantido. Nas 3 execuções de cada lado, os valores não se sobrepõem: requisições/s de 108.16 a 112.03 antes e de 160.51 a 161.52 depois; p95 de 496.7 a 499.4 ms antes e de 480.5 a 483.9 ms depois.

- **É o maior aumento de vazão desta rodada** (6661 → 9720 requisições em 60 s). Medida sozinha, sobre a aplicação original, a hipótese 07 não tinha sido confirmada (seção 07); sobre as outras, foi. De novo, um gargalo escondia o outro: lá o banco estava preso nas leituras de tabela inteira das outras rotas; aqui, `pedidos-por-status` era a rota que mais ocupava o banco.
- **`pedidos-por-status` caiu de 305.7 para 109.0 ms de mediana e de 1097.3 para 225.4 ms de p95.** Com a CPU do banco liberada, quase todas as outras rotas também melhoraram: `cliente` foi de 94.9 para 36.9 ms de mediana, e `top-produtos`, de 94.5 para 30.6 ms.
- **A exceção é `vendas-por-dia`**, que piorou (307.4 → 550.8 ms de mediana; 692.5 → 1226.2 ms de p95) e passou a ter 41.5% a 41.8% do tempo de espera dos usuários virtuais ([diagnostico/14](diagnostico/14-tempo-por-rota.txt), parte nova). Ela é a rota que mais trabalha no banco por requisição (lê ~13 mil itens e soma), e com o banco atendendo mais requisições por segundo ela disputa a CPU com mais consultas. É ela que mantém o p95 e o p99 gerais altos.
- **O banco continua no limite** (98.4% de CPU) e a API continua com folga (6.6%).
- **Custo:** nenhum serviço novo e nenhum limite alterado. O índice novo tem 21 MB, o mesmo tamanho do índice da hipótese 01 que ele substitui (diagnostico/10 e 21), então o disco ficou igual. A memória máxima do banco caiu de 272.4 para 225.3 MiB. O custo de escrita não foi medido.

---

## 08 — Total de pedidos por status pré-calculado

Branch: `hipotese/contagem-status`, criada a partir de `feature/diagnostico` (aplicação original, sem índices, sem pool e sem a visão de `top-produtos`). Mudanças: [banco/06-contagem-status.sql](banco/06-contagem-status.sql) e a contagem da rota `/pedidos` em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

A rota `/pedidos?status=&pagina=` devolve o `total` de pedidos do status, calculado com `count(*)` a cada chamada ([diagnostico/README.md](diagnostico/README.md), item 5). Para `pago`, são 300 mil linhas contadas por requisição. Na aplicação original, a contagem lê a tabela inteira ([diagnostico/19](diagnostico/19-contagem-por-status-pre-calculada.txt)). Com o índice da hipótese 01, essa contagem ainda ficou com 9.2% do tempo do banco numa rodada de carga ([diagnostico/12](diagnostico/12-consumo-por-consulta.txt), na branch `feature/diagnostico-consumo`). Como a carga só lê, o total de cada status é sempre o mesmo.

**Se** os 4 totais forem calculados uma vez e guardados numa visão materializada, **então** a rota lê um número pronto em vez de contar centenas de milhares de linhas, o banco gasta menos CPU por requisição, e a aplicação atende mais requisições por segundo, com tempo de resposta menor, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** ganho pequeno medido sozinho. Na aplicação original, a página da mesma rota ainda ordena 300 mil linhas em disco (diagnostico/18, na branch `hipotese/status-indice-cobertura`), e as outras rotas leem tabelas inteiras. A contagem é a parte mais barata da rota.

### O que mudou

- **`banco/06-contagem-status.sql`:** cria a visão materializada `contagem_pedidos_status` (`SELECT status, count(*) AS total FROM pedidos GROUP BY status`, 4 linhas) e um índice único em `status`, que serve para a busca e é exigido pelo `REFRESH ... CONCURRENTLY`. O número 06 evita conflito com o `banco/05-indice-status-cobertura.sql` da hipótese 07.
- **`api/src/rotas.js`:** a contagem passou a ser `SELECT coalesce((SELECT total FROM contagem_pedidos_status WHERE status = $1), 0) AS total`. O `coalesce` mantém o comportamento do `count(*)` para um status sem pedidos (não teria linha na visão): devolve 0, do mesmo tipo `bigint` (diagnostico/19, parte 7). A página não mudou.

### Fontes

- PostgreSQL Wiki, [Slow Counting](https://wiki.postgresql.org/wiki/Slow_Counting): o `count(*)` é lento por causa do MVCC; como transações diferentes podem ver dados diferentes, o PostgreSQL "must walk through all rows to determine visibility".
- PostgreSQL 16, [41.3 — Materialized Views](https://www.postgresql.org/docs/16/rules-materializedviews.html) e [REFRESH MATERIALIZED VIEW](https://www.postgresql.org/docs/16/sql-refreshmaterializedview.html): a visão materializada é mais rápida de ler, mas "the data is not always current"; o refresh substitui todo o conteúdo e, com `CONCURRENTLY`, não bloqueia as leituras (já citadas na hipótese 03).
- Almeida e Lifschitz, [(Auto) Sintonia-fina em Sistemas de Bancos de Dados nas Organizações](https://books-sol.sbc.org.br/index.php/sbc/catalog/download/7/12/38-1), SBC, 2018, p. 119: visões materializadas precisam ser atualizadas a cada mudança dos dados originais, "gerando mais atividade na base de dados" (já citada na hipótese 03).

### Evidência antes de medir

[diagnostico/19-contagem-por-status-pre-calculada.txt](diagnostico/19-contagem-por-status-pre-calculada.txt), uma consulta por vez, sem carga:

| Consulta | Antes (`count(*)`) | Depois (visão) |
|---|---|---|
| total de `pago` | 27,860 ms | 0,026 ms |
| total de `pendente` | 21,556 ms | 0,024 ms |

- **Mesma resposta:** o total que a API devolve para cada um dos 4 status é igual ao `count(*)` direto na tabela, e o `verificar-contrato.sh comparar` terminou em "Contrato mantido".

Esses tempos não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- **Dados defasados:** o total fica parado até o próximo refresh. Numa loja com pedidos novos, a página mostraria pedidos novos (a página continua lendo a tabela) com um total antigo. Na carga do desafio, que só lê, isso não aparece. É o mesmo dilema da visão de `top-produtos` (hipótese 03), mas aqui a inconsistência fica visível na mesma resposta.
- **Custo de cada refresh:** 83,626 ms (normal) e 97,318 ms (`CONCURRENTLY`), sem carga (diagnostico/19).
- **Disco:** 40 kB da visão com o índice.
- **Alternativa sem defasagem, não testada:** uma tabela de contagens mantida por trigger a cada `INSERT`/`UPDATE`/`DELETE` em `pedidos`. Fica sempre certa, mas deixa cada escrita mais lenta e concentra as escritas numa mesma linha por status.

### Resultado

Medido em 2026-11-14 no commit `a70acbe`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes: `resultados/20261104-094609-00-linha-de-base`, `20261104-095227-00-linha-de-base`, `20261104-095420-00-linha-de-base`
- Depois: `resultados/20261114-173053-08-contagem-status`, `20261114-173221-08-contagem-status`, `20261114-173351-08-contagem-status`

**Geral**

| Métrica | Antes | Depois |
|---|---|---|
| Requisições em 60 s | 308 | 321 |
| Requisições/s | 4.78 | 4.92 |
| Tempo de resposta, mediana | 800.1 ms | 897.9 ms |
| Tempo de resposta, p95 | 14401.8 ms | 14292.9 ms |
| Tempo de resposta, p99 | 16990.0 ms | 17882.2 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.8% | 98.9% |
| Memória máxima do banco (limite 512 MiB) | 283.6 MiB | 291.8 MiB |
| CPU média da API | 5.8% | 5.4% |
| Memória máxima da API (limite 256 MiB) | 40.5 MiB | 41.0 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Antes | Depois |
|---|---|---|
| `cliente` | 203.2 / 497.8 | 199.4 / 399.8 |
| `cliente-por-email` | 799.5 / 1401.1 | 850.8 / 1403.7 |
| `pedidos-do-cliente` | 12177.9 / 16231.5 | 13098.7 / 16911.1 |
| `pedidos-por-status` | 4598.7 / 14459.8 | 2455.8 / 5573.3 |
| `busca-produtos` | 494.1 / 732.6 | 495.2 / 804.2 |
| `vendas-por-dia` | 4614.2 / 6529.3 | 5317.7 / 6745.7 |
| `top-produtos` | 9902.8 / 15539.6 | 16402.5 / 17995.7 |

### Conclusão

Pelo critério definido antes de medir, a hipótese foi **confirmada só pelas medianas, com ganho dentro da variação**: a mediana de requisições/s subiu (4.78 → 4.92) e a de p95 geral caiu (14401.8 → 14292.9 ms), mas as faixas das 3 execuções se sobrepõem nas duas métricas (requisições/s de 4.71 a 4.79 antes e de 4.71 a 4.98 depois; p95 de 14260.1 a 15731.8 ms antes e de 13697.3 a 15392.1 ms depois). Não dá para separar o ganho geral da variação entre execuções.

- **A rota melhorou:** `pedidos-por-status` caiu de 4598.7 para 2455.8 ms de mediana e de 14459.8 para 5573.3 ms de p95. O que sobrou nela é a página, que na aplicação original ainda ordena 300 mil linhas em disco (hipótese 07).
- **O ganho geral é pequeno, como esperado:** a contagem era a parte mais barata da rota, a rota é 15% da carga, e o banco continua em 98.9% de CPU por causa das outras leituras de tabela inteira. A mediana geral subiu (800.1 → 897.9 ms), também dentro do que a variação explica.
- **Custo:** total defasado até o próximo refresh (83,626 ms por refresh, sem carga) e 40 kB de disco (diagnostico/19). Numa loja real, o total poderia não bater com a página.
- **Limites:** medida sozinha, sobre a aplicação original. Na integração, com índices e a página já barata, a contagem passa a ser uma parte maior do custo da rota (9.2% do tempo do banco no diagnostico/12); lá o efeito deve ficar mais claro.

---

## 01+…+04+06+07+08 — Integração com o total por status pré-calculado

Branch: `integracao`, com o merge de `hipotese/contagem-status` sobre a integração 01 a 04 + 06 + 07. Mudanças da hipótese 08: [banco/06-contagem-status.sql](banco/06-contagem-status.sql) e a contagem da rota `/pedidos` em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

Na integração 01 a 04 + 06 + 07, o banco está no limite (98.4% de CPU). Com o índice de cobertura, a página de `pedidos-por-status` ficou em ~2 ms, mas o `count(*)` de `pago` ainda percorre 300 mil entradas do índice a cada requisição: 12,598 ms sozinho ([diagnostico/21](diagnostico/21-status-cobertura-na-integracao.txt)), contra 0,026 ms lendo a visão ([diagnostico/19](diagnostico/19-contagem-por-status-pre-calculada.txt), na aplicação original). Agora a contagem é a parte mais cara da rota.

**Se** o total vier da visão materializada, **então** o banco libera a CPU que gastava contando, e a aplicação atende mais requisições por segundo, com p95 menor, do que a integração 01 a 04 + 06 + 07, sem mudar nenhuma resposta.

- **Comparação:** contra a integração 01 a 04 + 06 + 07 (`resultados/*-01-a-04-06-07-integracao`).
- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à integração 01 a 04 + 06 + 07, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Atenção:** o p95 geral é puxado por `vendas-por-dia` (41.5% a 41.8% do tempo de espera, diagnostico/14), que esta mudança não toca. Ela só deve melhorar de forma indireta, se o banco ficar menos ocupado.

### Resultado

Ainda não medido.
