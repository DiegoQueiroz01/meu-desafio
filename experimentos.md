# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 03 | `top-produtos` pré-calculado numa visão materializada | [PostgreSQL 16, Materialized Views](https://www.postgresql.org/docs/16/rules-materializedviews.html) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 5.05 req/s, p95 14096.8 ms | `resultados/20261111-1556*`, `-1557*`, `-1559*` `-03-top-produtos` | Confirmada com ganho geral pequeno: a rota caiu de 9902.8 para 251.9 ms de mediana, mas as outras seguem presas em `Seq Scan` |

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
