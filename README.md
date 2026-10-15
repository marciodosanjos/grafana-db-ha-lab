# Grafana DB HA Lab

Sandbox local para validar **alta disponibilidade do banco interno do Grafana** com PostgreSQL, Patroni, etcd e HAProxy.

> **Importante:** este repositório é uma POC/laboratório. A configuração foi criada para estudo e demonstração de failover; não deve ser usada em produção sem revisão de segurança, persistência, observabilidade, backup, RPO/RTO e arquitetura de infraestrutura.

## Objetivo

Validar, de forma reproduzível, o ciclo completo de alta disponibilidade:

1. um nó PostgreSQL atua como **Primary/Leader**;
2. os demais atuam como **Replicas/Standbys**;
3. as alterações do Primary são replicadas;
4. se o Primary cair, o Patroni promove automaticamente uma réplica;
5. o HAProxy continua oferecendo o **mesmo endpoint de escrita**;
6. novas transações são aceitas pelo novo Primary;
7. quando o antigo Primary volta, ele retorna como réplica e se ressincroniza.

## Arquitetura

```text
                        cliente / futuro Grafana
                                 |
                                 v
                           HAProxy :5000
                      (somente Primary atual)
                                 |
                     +-----------+-----------+
                     |           |           |
                     v           v           v
                  patroni1    patroni2    patroni3
                  PostgreSQL  PostgreSQL  PostgreSQL
                     |           |           |
                     +-----------+-----------+
                                 |
                           etcd1/2/3
                     (consenso / leader lock)
```

### Responsabilidades

| Componente | Papel |
|---|---|
| PostgreSQL | Armazena os dados e replica WAL |
| Patroni | Gerencia liderança, failover, promoção e rejoin |
| etcd | Mantém o estado distribuído/leader lock usado pelo Patroni |
| HAProxy | Expõe um endpoint estável e encaminha para o Primary atual |
| Docker Compose | Sobe e conecta os componentes do laboratório |

## Estrutura do projeto

```text
grafana-db-ha-lab/
├── docker-compose.yml
├── Dockerfile
├── haproxy/
│   └── haproxy.cfg
├── patroni/
│   ├── patroni1.yml
│   ├── patroni2.yml
│   └── patroni3.yml
├── scripts/
└── README.md
```

## Pré-requisitos

- Docker Desktop/Engine
- Docker Compose
- Git
- Windows + Git Bash funciona; para caminhos Linux dentro dos containers pode ser necessário usar `MSYS_NO_PATHCONV=1`.

Verificações:

```bash
docker desktop status
docker info
docker compose version
```

Se o Docker Desktop estiver parado:

```bash
docker desktop start
```

## Subir o laboratório

Primeira execução ou após recriar os containers:

```bash
docker compose up --build -d
```

Verifique os containers:

```bash
docker compose ps
```

Verifique o cluster Patroni:

```bash
MSYS_NO_PATHCONV=1 docker exec -it patroni1 \
  patronictl -c /etc/patroni.yml list
```

Estado saudável esperado:

```text
1 Leader / Primary
2 Replicas em streaming
Lag 0 ou próximo de 0
```

## Endpoints do HAProxy

| Endpoint | Uso |
|---|---|
| `localhost:5000` | conexão com o Primary atual (read/write) |
| `localhost:5001` | conexão com réplicas saudáveis |
| `http://localhost:7000` | página de status do HAProxy |

## Criar dados de teste pelo endpoint estável

Conecte pela porta 5000, sem conhecer o nó Primary:

```bash
docker exec -e PGPASSWORD=postgres -it patroni1 \
  psql -h haproxy -p 5000 -U postgres -d postgres
```

Confirme que a conexão chegou ao Primary:

```sql
SELECT inet_server_addr(), pg_is_in_recovery();
```

`pg_is_in_recovery() = f` significa **Primary**.  
`pg_is_in_recovery() = t` significa **Replica/Standby**.

Tabela usada na POC:

```sql
CREATE TABLE IF NOT EXISTS teste_ha (
    id BIGSERIAL PRIMARY KEY,
    descricao TEXT NOT NULL,
    criado_em TIMESTAMPTZ DEFAULT now()
);
```

Dados iniciais:

```sql
INSERT INTO teste_ha(descricao)
VALUES
    ('registro-antes-failover-1'),
    ('registro-antes-failover-2'),
    ('registro-antes-failover-3');
```

## Teste de failover

### 1. Descobrir o Leader atual

```bash
MSYS_NO_PATHCONV=1 docker exec -it patroni1 \
  patronictl -c /etc/patroni.yml list
```

### 2. Derrubar o Leader

Substitua `<leader>` pelo container mostrado como `Leader`, por exemplo `patroni2`:

```bash
docker stop <leader>
```

### 3. Confirmar a eleição de um novo Primary

```bash
MSYS_NO_PATHCONV=1 docker exec -it patroni1 \
  patronictl -c /etc/patroni.yml list
```

O esperado é que uma antiga Replica apareça como `Leader` e a outra continue `streaming`.

### 4. Testar o mesmo endpoint HAProxy

```bash
docker exec -e PGPASSWORD=postgres -it patroni1 \
  psql -h haproxy -p 5000 -U postgres -d postgres
```

```sql
SELECT pg_is_in_recovery();
SELECT COUNT(*) FROM teste_ha;
```

O resultado de `pg_is_in_recovery()` deve ser `f`.

### 5. Gravar novas transações após o failover

```sql
INSERT INTO teste_ha(descricao)
SELECT 'registro-depois-failover-' || n
FROM generate_series(1,10) AS n;

SELECT COUNT(*) FROM teste_ha;
```

Partindo dos 3 registros iniciais, o total esperado é **13**.

### 6. Trazer o antigo Primary de volta

```bash
docker start <leader-antigo>
```

Confira o cluster:

```bash
MSYS_NO_PATHCONV=1 docker exec -it patroni1 \
  patronictl -c /etc/patroni.yml list
```

O antigo Primary deve voltar como `Replica` e ficar `streaming`.

### 7. Validar a ressincronização do antigo Primary

```bash
docker exec -e PGPASSWORD=postgres -it <leader-antigo> \
  psql -U postgres -d postgres
```

```sql
SELECT pg_is_in_recovery();
SELECT COUNT(*) FROM teste_ha;
```

Esperado:

```text
pg_is_in_recovery = t
count = 13
```

Isso comprova que o nó que ficou fora retornou como réplica do novo Primary e recebeu as transações realizadas durante a indisponibilidade.

## Preservar o laboratório entre sessões

No estado atual da POC, o diretório de dados do PostgreSQL está no filesystem dos containers. Portanto:

- para **parar e continuar depois preservando os dados**, use:

```bash
docker compose stop
```

- no dia seguinte:

```bash
docker compose start
```

- evite `docker compose down` se quiser preservar os dados atuais, pois a remoção dos containers pode apagar os dados do laboratório.

Para recriar tudo do zero:

```bash
docker compose down
docker compose up --build -d
```

## Troubleshooting conhecido

### Git Bash converte `/etc/patroni.yml` para caminho do Windows

Use:

```bash
MSYS_NO_PATHCONV=1 docker exec -it patroni1 \
  patronictl -c /etc/patroni.yml list
```

### Docker CLI funciona, mas o Server não responde

```bash
docker desktop status
docker desktop start
docker info
```

### PostgreSQL: `data directory has invalid permissions`

O diretório de dados precisa ser `0700` ou `0750`. O Dockerfile deste lab cria `/var/lib/postgresql/patroni` com `chmod 700`.

### HAProxy: `Missing LF on last line`

Garanta uma quebra de linha no final de `haproxy/haproxy.cfg`.

## Próximas evoluções

- ativar e testar **replicação síncrona**;
- definir e medir RPO/RTO;
- adicionar volumes persistentes separados por nó;
- adicionar backup/PITR;
- adicionar observabilidade de replication lag e failover;
- adicionar um container Grafana apontando para `haproxy:5000`;
- testar criação/edição de dashboard durante failover;
- revisar segurança (secrets, TLS, autenticação, rede e credenciais);
- transformar comandos repetitivos em scripts dentro de `scripts/`.
