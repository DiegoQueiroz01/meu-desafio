# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`. As hipóteses são medidas primeiro isoladas, cada uma sobre a aplicação original (branch `feature/diagnostico`), contra a linha de base. As que têm ganho são juntadas na branch `integracao` e medidas de novo, combinadas, contra a medição acumulada anterior, porque os ganhos não se somam: um gargalo pode esconder o outro.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 01 | Índices B-tree nos filtros e ordenações das rotas | [PostgreSQL 16, cap. 11](https://www.postgresql.org/docs/16/indexes.html) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 19.73 req/s, p95 4102.9 ms | `resultados/20261110-1750*`, `-1752*`, `-1753*` `-01-indices` | Confirmada: mais vazão e menos latência em todas as rotas; o banco segue em ~100% de CPU, agora limitado por N+1, conexões e `top-produtos` |
| 02 | Pool de conexões (`pg.Pool`) na API | [node-postgres, Pooling](https://node-postgres.com/features/pooling) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 5.51 req/s, p95 13922.4 ms | `resultados/20261111-1308*`, `-1309*`, `-1311*` `-02-pool-conexoes` | Confirmada com ganho pequeno: o banco segue preso em `Seq Scan`; rotas rápidas pioraram na mediana (fila de 10 conexões) |
| 01+02 | Índices (01) e pool de conexões (02) juntos | as fontes de 01 e 02 | aplicada e medida | só 01: 19.73 req/s, p95 4102.9 ms | 36.47 req/s, p95 2467.9 ms | `resultados/20261111-1459*`, `-1500*`, `-1502*` `-01-02-indices-pool` | Confirmada: com os índices, o custo de abrir conexões passou a pesar; o pool, que sozinho rendeu pouco, aumentou bastante a vazão sobre os índices |

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
