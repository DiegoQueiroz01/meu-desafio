# Próximos testes

Ideias pesquisadas e ainda não medidas. Cada tópíco diz de onde vem a ideia (fonte com link), por que ela faz sentido neste projeto, o ganho esperado e como testar seguindo o mesmo fluxo do [experimentos.md](experimentos.md): mudança commitada, contrato conferido, 3 medições com o mesmo rótulo e comparação pela mediana.

O ponto de partida de todas é a integração final (hipóteses 01 a 04 e 06 a 08), rótulo 01-a-04-06-a-08-integracao: **203.17 req/s, p95 291.1 ms**, banco em 98.4% de CPU (limite 1 CPU) e API em 8.5% (limite 0,5 CPU, ou seja, 50% na escala do recursos.txt). O banco continua sendo o gargalo, e o tempo de espera está espalhado entre busca-produtos (23.4% a 24.8%), vendas-por-dia (21.3% a 23.5%) e pedidos-do-cliente (18.9% a 19.1%) ([diagnostico/14](diagnostico/14-tempo-por-rota.txt)).

O "ganho esperado" é uma expectativa qualitativa, não um número: nenhum número de resultado é escrito antes de medir.

| # | Ideia | Alvo | Tipo | Prioridade |
|---|---|---|---|---|
| T1 | Índice trigram (GIN pg_trgm) na busca de produtos | busca-produtos | desempenho | alta |
| T2 | Vendas por dia pré-calculadas numa visão materializada | vendas-por-dia | desempenho | alta |
| T3 | Investigar os degraus de ~100 ms (limite de CPU do container) | todas | diagnóstico | alta |
| T4 | Custo do refresh das visões materializadas sob carga | top-produtos, pedidos-por-status | validade | alta |
| T5 | Tamanho do pool de conexões | todas | desempenho | média |
| T6 | Reduzir o limite de CPU da API | custo | economia | média |
| T7 | Mais CPU para o banco | todas | desempenho com custo | média |
| T8 | Prepared statements (consultas nomeadas) no node-postgres | todas | desempenho | baixa |

---

## T1 — Índice trigram (GIN pg_trgm) na busca de produtos

**Fontes**
- [PostgreSQL 16, F.35 pg_trgm, seção F.35.4 Index Support](https://www.postgresql.org/docs/16/pgtrgm.html): índices GiST e GIN com gin_trgm_ops "also support index searches for LIKE and ILIKE". Aviso da mesma seção: "a pattern with no extractable trigrams will degenerate to a full-index scan".
- [TabNews, johnmaicon, "Achei que era só um filtro de busca. O PostgreSQL me mostrou que não."](https://www.tabnews.com.br/johnmaicon/um-filtro-de-busca-simples-me-ensinou-como-o-postgres-decide-nao-usar-um-indice): caso real em que ILIKE '%termo%' só passou a usar índice com GIN pg_trgm, e em que o planner ignorou o índice de propósito para um termo pouco seletivo.

**Por que aqui.** A rota faz nome ILIKE '%' || $1 || '%', que um B-tree não atende: na aplicação original, a consulta lê as 20 mil linhas de produtos e descarta 19 mil para o termo cadeira (6.891 ms sem carga, [diagnostico/06](diagnostico/06-explain-busca-produtos.txt)). Isso era barato perto das outras rotas, mas agora busca-produtos é a rota com a maior ou a segunda maior parte do tempo de espera (diagnostico/14). Com o banco em 98.4% de CPU, cada leitura de tabela inteira tira CPU de todas as outras rotas.

**Ganho esperado.** Menos CPU do banco por busca e menor tempo da rota; ganho indireto nas outras rotas, como aconteceu com a hipótese 08. O ganho pode ser pequeno ou nenhum para termos que aparecem em muitos produtos, porque o planner pode preferir ler a tabela (o mesmo efeito do caso do TabNews). Custo: espaço do índice e escrita mais lenta em produtos (a carga só lê).

**Como testar**
1. Branch hipotese/busca-trigram. Conferir que a extensão existe na imagem: SELECT name FROM pg_available_extensions WHERE name = 'pg_trgm'.
2. banco/07-busca-trigram.sql: CREATE EXTENSION IF NOT EXISTS pg_trgm; e CREATE INDEX ... ON produtos USING GIN (nome gin_trgm_ops); seguido de ANALYZE produtos.
3. Salvar em diagnostico/22-... o EXPLAIN (ANALYZE, BUFFERS) dos **12 termos** que a carga usa (carga/teste-carga.js: cadeira, mesa, lumin, teclado, monitor, ergo, sem fio, portatil, modelo 12, slim, reforcada, webcam), antes e depois, e o tamanho do índice. Isso mostra para quais termos o planner usa o índice.
4. verificar-contrato.sh comparar (a ordem ORDER BY nome, id não muda), medir isolada e na integração.
- **Confirma:** na integração, a mediana de req/s sobe e a de p95 geral cai em relação a 01-a-04-06-a-08-integracao.
- **Refuta:** não melhora, ou o planner não usa o índice para a maioria dos termos.

---

## T2 — Vendas por dia pré-calculadas numa visão materializada

**Fontes**
- [PostgreSQL 16, 41.3 Materialized Views](https://www.postgresql.org/docs/16/rules-materializedviews.html): o exemplo da documentação é justamente um resumo de vendas (sales_summary) atualizado de tempos em tempos, com acesso "often much faster", mas com dados que "not always current".
- Almeida, A. C. B.; Lifschitz, S. ["(Auto) Sintonia-fina em Sistemas de Bancos de Dados nas Organizações"](https://books-sol.sbc.org.br/index.php/sbc/catalog/download/7/12/38-1). SBC, 2018, p. 119: visões materializadas são "réplicas dos dados originais em formatos mais adequados para a realização de consulta", com o custo de atualizá-las.

**Por que aqui.** Mesmo somando no banco (hipótese 06), cada chamada junta pedidos e itens_pedido de até 31 dias e agrega. Na integração final, a rota tem mediana de 292.2 ms e p95 de 394.2 ms, e 21.3% a 23.5% do tempo de espera. A resposta tem uma linha por dia, e cada pedido pertence a um único dia, então uma visão com uma linha por dia (dia, pedidos, itens, receita_centavos, só pedidos não cancelados) devolve exatamente os mesmos valores: a rota passaria a ler no máximo 31 linhas prontas. É o mesmo padrão que funcionou nas hipóteses 03 e 08.

**Ganho esperado.** A rota deve ficar perto do custo de ler poucas linhas por índice, e o banco libera CPU para as outras rotas. Custo: a mesma defasagem das hipóteses 03 e 08 (o relatório só muda depois de um refresh) e o tempo de refresh, que precisa ser medido (ver T4).

**Como testar**
1. Branch hipotese/vendas-por-dia-pre-calculada. banco/07-vendas-por-dia.sql com a visão, um índice único em dia (necessário para REFRESH ... CONCURRENTLY) e ANALYZE.
2. Rota lendo a visão por dia BETWEEN $1 AND $2 ORDER BY dia, mantendo o formato YYYY-MM-DD e as conversões Number() atuais.
3. Salvar em diagnostico/ a comparação da visão com a consulta atual para vários intervalos (inclusive dias sem venda, que hoje não aparecem na resposta), o EXPLAIN e o tempo de refresh.
4. Contrato, 3 medições isolada e na integração. Mesmo critério da T1.

---

## T3 — Investigar os degraus de ~100 ms

**Fontes**
- [Linux kernel, CFS Bandwidth Control](https://docs.kernel.org/scheduler/sched-bwc.html): o limite de CPU de um grupo é dado por uma cota e um período, com período padrão cpu.cfs_period_us=100ms. Quando a cota acaba, as threads do grupo são "throttled" e "will not be able to run again until the next period when the quota is replenished". O arquivo cpu.stat expõe nr_periods, nr_throttled e throttled_time.
- [Docker, Resource constraints](https://docs.docker.com/engine/containers/resource_constraints/): --cpus equivale a configurar --cpu-period e --cpu-quota, e o período "Defaults to 100000 microseconds (100 milliseconds)".

**Por que aqui.** Na integração final, as medianas por rota ficaram perto de múltiplos de ~100 ms (8.6, 88.6, 98.0, 98.2, 191.3, 292.2 ms; seção 01+…+08 do experimentos.md). Com o banco em 98.4% de 1 CPU, a explicação candidata é: o container gasta a cota do período, fica parado até o próximo, e uma consulta que não termina num período espera o seguinte. As duas fontes descrevem esse mecanismo, mas não há medição que o confirme neste projeto.

**Ganho esperado.** Este teste é de diagnóstico: o objetivo é explicar as medianas, não melhorar números. Se a explicação se confirmar, ela muda a leitura de todos os resultados por rota da integração e sugere um teste seguinte: manter a mesma cota proporcional (mesmo custo, 1 CPU) com um período menor.

**Como testar**
1. Ler o cpu.stat do cgroup do banco antes e depois de uma rodada de carga, sem gerar resultados/ (comando de diagnóstico do k6 já usado no projeto). Em cgroup v2, por exemplo docker compose exec -T banco cat /sys/fs/cgroup/cpu.stat; confirmar antes qual versão de cgroup a máquina usa.
2. Salvar as duas leituras e a diferença de nr_throttled e throttled_time em diagnostico/.
- **Confirma:** nr_throttled cresce numa fração grande dos períodos da rodada.
- **Refuta:** nr_throttled fica perto de zero. Nesse caso, procurar outra causa para os degraus.

---

## T4 — Custo do refresh das visões materializadas sob carga

**Fontes**
- [PostgreSQL 16, REFRESH MATERIALIZED VIEW](https://www.postgresql.org/docs/16/sql-refreshmaterializedview.html): o refresh substitui todo o conteúdo da visão; com CONCURRENTLY, não bloqueia as leituras, mas exige um índice único.
- Agner, L. T. W. ["T-SVM: uma abordagem para manutenção de visões materializadas em ambientes data warehouse"](https://revistas.unicentro.br/index.php/RECEN/article/download/386/538). Revista Ciências Exatas e Naturais, v. 7, n. 1, 2005, p. 36–37: o reprocessamento completo da visão consome tempo e recursos.

**Por que aqui.** As hipóteses 03 e 08 tiraram trabalho do banco trocando-o por visões materializadas, mas as medições não incluíram nenhum refresh: a carga só lê e as visões foram criadas uma vez. Numa loja real, elas precisariam ser atualizadas. Sem carga, o refresh de top_produtos levou 704.293 ms e 743.291 ms com CONCURRENTLY ([diagnostico/13](diagnostico/13-explain-top-produtos-pre-calculado.txt)) e o da contagem por status 83.626 ms ([diagnostico/19](diagnostico/19-contagem-por-status-pre-calculada.txt)), num banco que já está no limite de CPU.

**Ganho esperado.** Nenhum: é um teste de **validade** dos ganhos já medidos. O resultado esperado é uma perda de desempenho, que mostra quanto do ganho das hipóteses 03 e 08 sobrevive a um intervalo de refresh realista.

**Como testar**
1. Sem mudar a régua: enquanto scripts/medir.sh roda, outro terminal executa REFRESH MATERIALIZED VIEW CONCURRENTLY das duas visões num intervalo fixo (por exemplo, a cada 10 s), com rótulo próprio (...-com-refresh-10s).
2. Medir 3 vezes e comparar com 01-a-04-06-a-08-integracao. Repetir com outro intervalo para ver a tendência.
3. Registrar no experimentos.md como teste de validade, não como hipótese de ganho.

---

## T5 — Tamanho do pool de conexões

**Fontes**
- [PostgreSQL Wiki, Number Of Database Connections](https://wiki.postgresql.org/wiki/Number_Of_Database_Connections): ponto de partida (core_count * 2) + effective_spindle_count; além do ponto de saturação, a vazão cai por contenção.
- [HikariCP, About Pool Sizing](https://github.com/brettwooldridge/HikariCP/wiki/About-Pool-Sizing): a mesma fórmula, e o argumento de que um pool pequeno costuma ser melhor que um grande.
- [node-postgres, API do Pool](https://node-postgres.com/apis/pool): max padrão 10.

**Por que aqui.** O pool usa max: 10 ([api/src/db.js](api/src/db.js)), o padrão do node-postgres, escolhido na hipótese 02 sem variar o valor. O banco tem 1 CPU, para a qual a fórmula dá um ponto de partida bem menor que 10. Na hipótese 02 isolada, a mediana de cliente subiu de 203.2 para 372.4 ms, o que pode ser fila no pool (não testado).

**Ganho esperado.** Incerto nos dois sentidos: um pool menor pode reduzir a troca de contexto entre processos do PostgreSQL numa CPU só, mas também pode criar fila na API. Por isso o teste é uma varredura, não uma mudança.

**Como testar**
1. Branch hipotese/tamanho-pool, com o max vindo de variável de ambiente para não precisar editar o código a cada valor (um commit por valor, já que o contexto.txt registra o commit).
2. Medir 3 vezes com max 2, 4, 10 e 20, rótulos ...-pool-2, ...-pool-4 etc.
- **Confirma:** algum valor diferente de 10 melhora req/s e p95 além da faixa das 3 execuções de max 10.

---

## T6 — Reduzir o limite de CPU da API

**Fonte.** [Docker, Resource constraints](https://docs.docker.com/engine/containers/resource_constraints/) (--cpus); no Compose, deploy.resources.limits.cpus, já usado em [docker-compose.yml](docker-compose.yml).

**Por que aqui.** Desde a hipótese 06, a API usa pouco do que tem: na integração final, CPU média de 8.1% a 8.8% e máxima de 9.7% a 9.9%, com limite de 50% (0,5 CPU) (recursos.txt das 3 pastas -01-a-04-06-a-08-integracao). O desafio pede a aplicação mais rápida e mais barata; até aqui, nenhuma hipótese reduziu recurso.

**Ganho esperado.** Economia de recurso sem perda de desempenho, enquanto o limite novo ficar acima do uso. Abaixo disso, a API volta a ser gargalo, como na integração 01 a 04 (44.1% de CPU).

**Como testar.** Branch hipotese/api-menos-cpu; cpus: "0.25" no serviço api (um commit), docker compose up -d --build, 3 medições. Se não houver perda, tentar 0.15.
- **Confirma:** req/s e p95 ficam dentro da faixa das 3 execuções da integração final, com metade da CPU reservada.

---

## T7 — Mais CPU para o banco

**Fontes**
- [Docker, Resource constraints](https://docs.docker.com/engine/containers/resource_constraints/) (--cpus).
- [PostgreSQL 16, 52.2 How Connections Are Established](https://www.postgresql.org/docs/16/connect-estab.html): um processo por conexão; com 1 CPU, as consultas das conexões do pool disputam uma CPU só.

**Por que aqui.** O banco está em 98.4% de CPU em todas as medições desde a integração 01+…+04+06. É o gargalo, e a regra 6 do AGENTS.md permite aumentar recurso, desde que o ganho venha junto com o custo.

**Ganho esperado.** Mais vazão, porque mais processos do PostgreSQL rodam ao mesmo tempo. Custo: o dobro da CPU reservada para o banco. A comparação justa é ganho por CPU, para mostrar se as otimizações de 01 a 08 foram mais baratas que simplesmente comprar máquina.

**Como testar.** Branch hipotese/banco-2-cpus; cpus: "2.0" no serviço banco, 3 medições contra a integração final. Opcional: medir também a aplicação original com 2 CPUs, para comparar "otimizar" com "comprar CPU" a partir do mesmo ponto.

---

## T8 — Prepared statements (consultas nomeadas) no node-postgres

**Fonte.** [node-postgres, Queries, Prepared Statements](https://node-postgres.com/features/queries): com um name na consulta, o PostgreSQL faz o parse e o plano uma vez por conexão. A própria documentação avisa: "Most of your queries will likely not benefit much, if at all, from using prepared statements."

**Por que aqui.** As rotas mais frequentes (cliente 25%, pedidos-do-cliente 20%) fazem consultas simples, repetidas milhares de vezes por medição. Com o pool, as conexões ficam abertas, então o plano poderia ser reaproveitado.

**Ganho esperado.** Pequeno ou nenhum, pela própria fonte. Prioridade baixa: só vale testar se um diagnóstico mostrar que o planejamento pesa. No EXPLAIN original da busca, o planejamento levou 0.270 ms contra 6.891 ms de execução ([diagnostico/06](diagnostico/06-explain-busca-produtos.txt)), mas isso ainda não foi medido nas consultas por índice, que são muito mais curtas.

**Como testar.** Primeiro, um diagnóstico: comparar Planning Time e Execution Time das consultas de cliente, cliente-por-email e pedidos-do-cliente na integração final e salvar em diagnostico/. Só se o planejamento for uma parte relevante: dar name a essas consultas, conferir o contrato e medir 3 vezes.

---

## Ideias descartadas

- **Índice BRIN em criado_em:** criado_em está embaralhado em relação à ordem física das linhas, e o BRIN depende dessa correlação.
- **Paginação por chave (keyset) em /pedidos?status=:** exige trocar o parâmetro pagina por um cursor, o que muda o contrato.
- **Particionamento e sharding:** as maiores tabelas têm 174 MB (pedidos) e 107 MB (itens_pedido) ([diagnostico/01](diagnostico/01-banco-ambiente.txt)), e as leituras de tabela inteira que existiam já foram trocadas por índices e pré-cálculo. Não há evidência de que o tamanho das tabelas seja o problema; o limite medido é a CPU do banco. A complexidade não se justifica neste tamanho.
