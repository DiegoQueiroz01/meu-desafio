# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 08 | Total de pedidos por status pré-calculado numa visão materializada | [PostgreSQL Wiki, Slow Counting](https://wiki.postgresql.org/wiki/Slow_Counting) | em medição | | | | |

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

Ainda não medido.
