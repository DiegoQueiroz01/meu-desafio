# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 01 | Índices B-tree nos filtros e ordenações das rotas | [PostgreSQL 16, cap. 11](https://www.postgresql.org/docs/16/indexes.html) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 19.73 req/s, p95 4102.9 ms | `resultados/20261110-1750*`, `-1752*`, `-1753*` `-01-indices` | Confirmada: mais vazão e menos latência em todas as rotas; o banco segue em ~100% de CPU, agora limitado por N+1, conexões e `top-produtos` |

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
