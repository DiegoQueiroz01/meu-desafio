# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 08 | Total de pedidos por status pré-calculado numa visão materializada | [PostgreSQL Wiki, Slow Counting](https://wiki.postgresql.org/wiki/Slow_Counting) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 4.92 req/s, p95 14292.9 ms | `resultados/20261114-1730*`, `-1732*`, `-1733*` `-08-contagem-status` | Confirmada só pelas medianas, dentro da variação: `pedidos-por-status` caiu de 4598.7 para 2455.8 ms de mediana, mas o ganho geral não se separa do ruído |

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
