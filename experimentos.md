# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 02 | Pool de conexões (`pg.Pool`) na API | [node-postgres, Pooling](https://node-postgres.com/features/pooling) | em medição | | | | |

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

Ainda não medido.
