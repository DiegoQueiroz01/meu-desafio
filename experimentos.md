# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 07 | Índice de cobertura (`INCLUDE`) para a página de `/pedidos?status=` | [PostgreSQL 16, CREATE INDEX](https://www.postgresql.org/docs/16/sql-createindex.html) | aplicada e medida | 4.78 req/s, p95 14401.8 ms | 5.31 req/s, p95 14592.6 ms | `resultados/20261114-1723*`, `-1724*`, `-1726*` `-07-status-indice-cobertura` | Não confirmada sozinha: req/s subiu e `pedidos-por-status` caiu de 4598.7 para 704.3 ms de mediana, mas o p95 geral não caiu (preso em `pedidos-do-cliente` e `top-produtos`) |

---

## 07 — Índice de cobertura para `/pedidos?status=`

Branch: `hipotese/status-indice-cobertura`, criada a partir de `feature/diagnostico` (aplicação original, sem os índices da hipótese 01, sem pool e sem a visão de `top-produtos`). Mudanças: [banco/05-indice-status-cobertura.sql](banco/05-indice-status-cobertura.sql) e a consulta da página em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

A rota `/pedidos?status=&pagina=` faz duas consultas: um `count(*)` do status e uma página com `ORDER BY criado_em DESC, id DESC LIMIT 20 OFFSET (pagina-1)*20`, com páginas de 1 a 1000 na carga. A página pede `SELECT *`, mas a resposta usa só `id`, `cliente_id`, `status` e `criado_em`. Na aplicação original, a página 1000 de `pago` ordena 300 mil linhas em disco (~90 MB nos 3 processos) e leva 166,325 ms sozinha ([diagnostico/18](diagnostico/18-status-indice-cobertura.txt)). Mesmo com o índice `(status, criado_em DESC, id DESC)` da hipótese 01, a página ainda gravava arquivos temporários sob carga (17792 blocos, [diagnostico/12](diagnostico/12-consumo-por-consulta.txt), na branch `feature/diagnostico-consumo`). Uma explicação provável, a confirmar na integração: com `SELECT *`, cada linha pulada pelo `OFFSET` precisa ser buscada na tabela, e para páginas fundas o planejador prefere ler e ordenar tudo.

**Se** a página pedir só as 4 colunas da resposta e existir um índice que tenha todas elas (`(status, criado_em DESC, id DESC) INCLUDE (cliente_id)`), **então** o `OFFSET` pula as linhas lendo só o índice (`Index Only Scan`), sem ordenar e sem visitar a tabela, e a aplicação atende mais requisições por segundo, com tempo de resposta menor, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** medida sozinha, o índice também serve ao `count(*)` (de `Seq Scan` para `Index Only Scan`, 87,107 → 15,510 ms, diagnostico/18), então `pedidos-por-status` deve melhorar bastante. As outras rotas continuam lendo tabelas inteiras e devem melhorar pouco.

### O que mudou

- **`banco/05-indice-status-cobertura.sql`:** cria `pedidos (status, criado_em DESC, id DESC) INCLUDE (cliente_id)` e roda `VACUUM (ANALYZE) pedidos`, para o mapa de visibilidade permitir `Index Only Scan` sem visitar a tabela. O arquivo também apaga o índice `pedidos_status_criado_idx` da hipótese 01, se ele existir (`DROP INDEX IF EXISTS`): o índice novo tem as mesmas colunas de busca e ordenação, mais o `cliente_id`, então o antigo fica redundante. Nesta branch, sem a hipótese 01, o `DROP` não faz nada.
- **`api/src/rotas.js`:** a consulta da página troca `SELECT *` por `SELECT id, cliente_id, status, criado_em`. Filtro, ordem, `LIMIT` e `OFFSET` ficaram iguais; o `count(*)` não mudou.

### Fontes

- PostgreSQL 16, [CREATE INDEX, parâmetro `INCLUDE`](https://www.postgresql.org/docs/16/sql-createindex.html): colunas não-chave permitem que "an index-only scan can return the contents of non-key columns without having to visit the index's table"; a página também avisa que essas colunas "duplicate data from the index's table and bloat the size of the index".
- PostgreSQL 16, [7.6 — LIMIT and OFFSET](https://www.postgresql.org/docs/16/queries-limit.html): "The rows skipped by an OFFSET clause still have to be computed inside the server; therefore a large OFFSET might be inefficient."
- PostgreSQL 16, [11.9 — Index-Only Scans](https://www.postgresql.org/docs/16/indexes-index-only-scans.html): o `Index Only Scan` só evita a tabela para páginas marcadas como visíveis no mapa de visibilidade (já citada na hipótese 01).
- Chen et al., [ICSE 2014](https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf), seção 2.1 "Excessive Data": trazer colunas que a aplicação não usa é um anti-padrão de desempenho. Aqui, o `SELECT *` também impede o `Index Only Scan`, porque `observacoes` não está no índice.

### Evidência antes de medir

[diagnostico/18-status-indice-cobertura.txt](diagnostico/18-status-indice-cobertura.txt), status `pago`, uma consulta por vez, sem carga:

| Consulta | Antes | Depois |
|---|---|---|
| Página 1000 (`OFFSET 19980`) | 166,325 ms, `Seq Scan` + ordenação em disco | 2,548 ms, `Index Only Scan`, `Heap Fetches: 0` |
| `count(*)` | 87,107 ms, `Seq Scan` | 15,510 ms, `Index Only Scan` |

- **Mesma resposta:** em 216 páginas (200 sorteadas e as páginas 1, 1000, 1251 e 99999 de cada status), a resposta nova é idêntica, em texto, à montada com a consulta antiga. O `verificar-contrato.sh comparar` terminou em "Contrato mantido".

Esses tempos não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- **Disco:** 21 MB do índice novo (diagnostico/18). Na integração, o índice da hipótese 01 que ele substitui deixa de existir.
- **Escrita:** cada `INSERT` em `pedidos` e cada `UPDATE` de `status` atualizam mais um índice (nesta branch) ou o mesmo número de índices (na integração, porque substitui o da hipótese 01). A carga só faz leituras, então esse custo não aparece na medição.
- **Manutenção:** o `Index Only Scan` depende do mapa de visibilidade em dia; numa tabela com muitas escritas, o autovacuum precisa acompanhar.
- **Acoplamento:** se alguém voltar a pedir `SELECT *` na página, o índice deixa de cobrir a consulta.

### Resultado

Medido em 2026-11-14 no commit `eb35522`, banco recriado do zero, contrato mantido nas 3 execuções. Cada valor é a mediana (o valor do meio) das 3 execuções, tirado dos `resumo.txt` e `recursos.txt` das pastas:

- Antes: `resultados/20261104-094609-00-linha-de-base`, `20261104-095227-00-linha-de-base`, `20261104-095420-00-linha-de-base`
- Depois: `resultados/20261114-172308-07-status-indice-cobertura`, `20261114-172435-07-status-indice-cobertura`, `20261114-172603-07-status-indice-cobertura`

**Geral**

| Métrica | Antes | Depois |
|---|---|---|
| Requisições em 60 s | 308 | 341 |
| Requisições/s | 4.78 | 5.31 |
| Tempo de resposta, mediana | 800.1 ms | 787.4 ms |
| Tempo de resposta, p95 | 14401.8 ms | 14592.6 ms |
| Tempo de resposta, p99 | 16990.0 ms | 17245.4 ms |
| Erros | 0.00% | 0.00% |
| CPU média do banco | 99.8% | 99.9% |
| Memória máxima do banco (limite 512 MiB) | 283.6 MiB | 294.1 MiB |
| CPU média da API | 5.8% | 5.4% |
| Memória máxima da API (limite 256 MiB) | 40.5 MiB | 42.3 MiB |

**Por rota** (mediana / p95, em ms)

| Rota | Antes | Depois |
|---|---|---|
| `cliente` | 203.2 / 497.8 | 293.6 / 502.7 |
| `cliente-por-email` | 799.5 / 1401.1 | 996.9 / 1540.2 |
| `pedidos-do-cliente` | 12177.9 / 16231.5 | 12794.8 / 16873.0 |
| `pedidos-por-status` | 4598.7 / 14459.8 | 704.3 / 1382.2 |
| `busca-produtos` | 494.1 / 732.6 | 498.2 / 831.0 |
| `vendas-por-dia` | 4614.2 / 6529.3 | 4111.9 / 7368.7 |
| `top-produtos` | 9902.8 / 15539.6 | 16112.6 / 17581.4 |

### Conclusão

Pelo critério definido antes de medir, a hipótese **não foi confirmada quando medida sozinha**: a mediana de requisições/s subiu (4.78 → 5.31, sem sobreposição: 4.71 a 4.79 antes, 5.10 a 5.40 depois), mas a de p95 geral não caiu (14401.8 → 14592.6 ms, com sobreposição: 14260.1 a 15731.8 ms antes, 14398.9 a 15426.0 ms depois). O critério exigia as duas coisas.

- **A rota mudou muito.** `pedidos-por-status` caiu de 4598.7 para 704.3 ms de mediana e de 14459.8 para 1382.2 ms de p95, como o `EXPLAIN` indicava (diagnostico/18): a página e a contagem deixaram de ler a tabela inteira.
- **Por que o p95 geral não caiu:** o p95 geral é formado pelas requisições mais lentas, e elas são de `pedidos-do-cliente` (p95 16873.0 ms) e `top-produtos` (17581.4 ms), que continuam lendo tabelas inteiras. O banco continua em 99.9% de CPU; a CPU que a rota liberou foi usada para atender mais requisições (341 contra 308), não para atender mais rápido as outras.
- **As rotas rápidas pioraram um pouco na mediana** (`cliente` 203.2 → 293.6 ms, `cliente-por-email` 799.5 → 996.9 ms). Uma explicação provável, não testada: com mais requisições por segundo e o banco ainda no limite, há mais consultas disputando a mesma CPU.
- **Custo:** 21 MB de disco do índice (diagnostico/18); nenhum serviço novo e nenhum limite alterado. O custo de escrita não foi medido, porque a carga só faz leituras.
- **Limites:** medida sozinha, sobre a aplicação original. A comparação que interessa é na branch `integracao`, contra o índice da hipótese 01, que o arquivo novo substitui.
