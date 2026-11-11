# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 03 | `top-produtos` pré-calculado numa visão materializada | [PostgreSQL 16, Materialized Views](https://www.postgresql.org/docs/16/rules-materializedviews.html) | em medição | | | | |

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

Ainda não medido.
