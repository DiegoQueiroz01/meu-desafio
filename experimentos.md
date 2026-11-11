# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 02 | Pool de conexões (`pg.Pool`) na API | [node-postgres, Pooling](https://node-postgres.com/features/pooling) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 5.51 req/s, p95 13922.4 ms | `resultados/20261111-1308*`, `-1309*`, `-1311*` `-02-pool-conexoes` | Confirmada com ganho pequeno: o banco segue preso em `Seq Scan`; rotas rápidas pioraram na mediana (fila de 10 conexões) |

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
