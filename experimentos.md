# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 01 | Índices B-tree nos filtros e ordenações das rotas | [PostgreSQL 16, cap. 11](https://www.postgresql.org/docs/16/indexes.html) | em medição | — | — | — | — |

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

Ainda não medido.
