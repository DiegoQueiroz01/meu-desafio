# Experimentos

Cada ideia testada vira uma linha na tabela e uma seção abaixo. Os números de desempenho vêm só de `resultados/` (mediana de 3 execuções do `scripts/medir.sh`, com `VUS=20`, `DURACAO=60s`, `SEMENTE=42`). A linha de base são as 3 pastas `resultados/*-00-linha-de-base/`.

| # | Ideia | Fonte | Status | Antes | Depois | Pastas | Conclusão |
|---|---|---|---|---|---|---|---|
| 06 | `vendas-por-dia` somando no banco, sem trazer `observacoes` | [PostgreSQL 16, Aggregate Functions](https://www.postgresql.org/docs/16/tutorial-agg.html) | em medição | | | | |

---

## 06 — `vendas-por-dia` somando no banco

Branch: `hipotese/vendas-por-dia-sql`, criada a partir de `feature/diagnostico` (aplicação original, sem índices, sem pool e sem a visão de `top-produtos`). Mudança: a rota `/relatorios/vendas-por-dia` em [api/src/rotas.js](api/src/rotas.js).

### Hipótese

A rota busca uma linha por item vendido no período, com a coluna `observacoes`, e soma por dia em JavaScript ([diagnostico/README.md](diagnostico/README.md), item 6). Num período de 7 dias, o tamanho que a carga usa, são 12951 linhas por requisição, com 3555995 caracteres só de `observacoes`, que a resposta não usa ([diagnostico/17](diagnostico/17-vendas-por-dia-soma-no-banco.txt)). Na integração 01+02+03 essa rota ficou com 9.1% do tempo total de espera dos usuários virtuais e a API ficou perto do limite de CPU (branch `integracao`).

**Se** o banco fizer a soma por dia (`GROUP BY`) e devolver só uma linha por dia, **então** a API deixa de receber, converter e somar milhares de linhas por requisição, e a aplicação atende mais requisições por segundo, com tempo de resposta menor, sem mudar nenhuma resposta.

- **Confirma:** a mediana das 3 execuções melhora em requisições/s e em p95 geral em relação à linha de base, com o contrato mantido.
- **Refuta:** a mediana não melhora, ou o contrato quebra.
- **Expectativa:** ganho pequeno ou nenhum medido sozinho. Sem índices, o banco ainda lê `pedidos` e `itens_pedido` inteiras nas duas versões (212,288 ms contra 221,655 ms, diagnostico/17), e o gargalo da aplicação original é a CPU do banco. O efeito esperado é na branch `integracao`, onde a API está perto do limite de CPU.

### O que mudou

Em [api/src/rotas.js](api/src/rotas.js), a rota passou a pedir a soma pronta:

```sql
SELECT to_char(p.criado_em::date, 'YYYY-MM-DD') AS dia,
       count(DISTINCT p.id) AS pedidos,
       sum(i.quantidade) AS itens,
       sum(i.quantidade::bigint * i.preco_unitario_centavos) AS receita_centavos
  FROM pedidos p
  JOIN itens_pedido i ON i.pedido_id = p.id
 WHERE p.criado_em::date BETWEEN $1 AND $2
   AND p.status <> 'cancelado'
 GROUP BY p.criado_em::date
 ORDER BY p.criado_em::date
```

- **Mesmo filtro:** `criado_em::date BETWEEN` e `status <> 'cancelado'` ficaram iguais, para a mudança ser só onde a soma acontece. O índice `pedidos((criado_em::date))` da hipótese 01 continua servindo na integração.
- **Mesmas contas:** `pedidos` conta pedidos distintos (antes, um `Set` de ids); `itens` soma quantidades; `receita_centavos` soma `quantidade × preço`. A multiplicação é feita em `bigint` para não estourar o tipo `integer` do PostgreSQL.
- **Mesmo formato:** `count` e `sum` voltam como texto no node-postgres (são `bigint`/`numeric`); `Number()` devolve os mesmos números que a soma em JavaScript dava. A ordem é por dia, como o `sort` antigo.
- **Sem `observacoes`:** a coluna não é mais lida pela rota.

### Fontes

- PostgreSQL 16, [2.7 — Aggregate Functions](https://www.postgresql.org/docs/16/tutorial-agg.html): "An aggregate function computes a single result from multiple input rows"; com `GROUP BY`, a consulta devolve "one output row per" grupo.
- Chen et al., [Detecting Performance Anti-patterns for Applications Developed using Object-Relational Mapping](https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf), ICSE 2014, seção 2.1 "Excessive Data" (p. 1002–1003): trazer do banco dados que a aplicação não usa é um anti-padrão de desempenho; no exemplo do artigo, corrigir isso reduziu o tempo de resposta de 1,68 s para 0,48 s.

### Evidência antes de medir

[diagnostico/17-vendas-por-dia-soma-no-banco.txt](diagnostico/17-vendas-por-dia-soma-no-banco.txt), período de 2024-03-01 a 2024-03-07, uma consulta por vez, sem carga:

| | Antes | Depois |
|---|---|---|
| Linhas enviadas do banco para a API | 12951 | 7 |
| Caracteres de `observacoes` enviados | 3555995 | 0 |
| Tempo da consulta no banco, sem índices | 221,655 ms | 212,288 ms |
| Corpo da resposta HTTP | 540 B | 540 B |

- **Mesma resposta:** em 68 períodos (60 sorteados de 7 dias, os extremos, períodos de 1 e de 31 dias e 2 sem vendas), a resposta nova é idêntica, em texto, à montada pela lógica antiga. O `verificar-contrato.sh comparar` terminou em "Contrato mantido".

Esses tempos não são o resultado do experimento: o resultado sob carga vem do `medir.sh`.

### Custo

- Nenhum serviço novo, nenhum limite e nenhum índice alterado.
- **CPU do banco:** o banco passa a fazer a soma e a ordenação por dia (um `GroupAggregate` sobre ~13 mil linhas, em memória, diagnostico/17). Em troca, deixa de enviar as 12951 linhas pela rede.

### Resultado

Ainda não medido.
