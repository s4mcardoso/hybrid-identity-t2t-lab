# Guia de consulta: Quest ODM M365 (contas e conteúdo)

Anotações do piloto de migração de contas, e-mail e OneDrive entre o Tenant Origem e o Tenant B, para consultar depois. O passo a passo com os problemas está no [README](../README.md#fase-12-piloto-do-odm-m365-preparação-discovery-e-match).

---

## 1. A ordem do trabalho

No projeto *Accounts and User data*, tudo segue a mesma ordem:

```
DISCOVERY  ->  MATCH  ->  MIGRATE
 (achar)      (casar)    (copiar)
```

O botão **MIGRATE** fica cinza até existirem contas descobertas e casadas.

Para lembrar: descobrir, casar, migrar. Pular o casamento é o erro clássico, porque o ODM acaba criando uma conta nova no destino quando o certo era usar a que já existe.

### As abas do projeto

| Aba | Para que serve |
|---|---|
| **Dashboard** | Visão geral e os passos iniciais (consentimento, descoberta, casamento, migração) |
| **Accounts** | Contas descobertas e o par origem e destino. Tudo começa aqui |
| **Mailboxes** | Migração de e-mail, calendário e contatos |
| **OneDrive** | Migração dos arquivos |
| **Desktop Agents** | Agente que reconfigura o Outlook e o OneDrive no computador do usuário depois da virada |
| **Reports / Events / Tasks** | Acompanhamento: o que rodou, o que deu erro, o que está na fila |

---

## 2. Antes do Discovery: os tenants

O ODM migra conteúdo de uma caixa e de um OneDrive que existem para uma caixa e um OneDrive que existem. Então, antes de abrir o ODM:

| Item | Por quê |
|---|---|
| **Licença na origem** | Sem licença não existe caixa nem OneDrive, e não há o que migrar |
| **Licença no destino** | O ODM grava dentro de uma caixa que já existe. Sem licença no destino, a migração de e-mail falha |
| **Usage location** | A licença só é atribuída com o país preenchido. Conta sincronizada pelo Entra Connect costuma vir sem ele |
| **OneDrive provisionado** | A caixa nasce com a licença. O OneDrive só nasce no primeiro acesso do usuário ou com o `Request-SPOPersonalSite` |
| **Conteúdo conhecido na origem** | Para validar a migração comparando o que tinha com o que chegou |

Para lembrar: caixa nasce com a licença; OneDrive nasce no primeiro acesso.

---

## 3. Discovery

![Opções do Discovery](img/51-odm-discovery-opcoes.png)

| Opção | O que faz | Quando usar |
|---|---|---|
| **Discover All** | Lê todas as contas e grupos da origem | Lab ou projeto que migra a empresa inteira. Em cliente grande, mistura contas que não vão migrar |
| **Discover from File** | Lê só as contas de um CSV | O mais usado em projeto: o cliente manda a planilha da onda |
| **Discover from Security Groups** | Lê os membros de grupos de segurança | Quando as ondas são organizadas por grupo no Entra ID. Para mudar a onda, basta mexer no grupo |
| **Refresh Selected Accounts** | Relê no tenant só as contas já descobertas e marcadas | Depois de uma mudança na origem, ou para completar uma descoberta que ficou pela metade |

Para lembrar: Discover All é para lab; From File e From Security Groups são para projeto. A pergunta que decide é quem define as ondas, uma planilha ou um grupo.

### O CSV do Discovery

![Formato do CSV do Discovery](img/52-odm-discovery-csv.png)

| Formato | Identificador | Quando usar |
|---|---|---|
| `UserPrincipalName,Type` | UPN | O mais comum. Fácil de ler e conferir |
| `ObjectId,Type` | GUID da conta no Entra ID | Quando o UPN pode mudar durante o projeto (troca de domínio, de nome). O ObjectId nunca muda |

A coluna `Type` aceita `user` ou `group`, então contas e grupos podem ir no mesmo arquivo.

O arquivo do piloto:

```
UserPrincipalName,Type
teste.nexus1@<tenant-origem>.onmicrosoft.com,user
teste.nexus2@<tenant-origem>.onmicrosoft.com,user
teste.nexus3@<tenant-origem>.onmicrosoft.com,user
```

Em projeto, o CSV da onda é um documento: tem nome com a onda e a data e fica guardado como prova do que foi migrado.

### Como saber se o Discovery terminou de verdade

A coluna **Source Type** deve mostrar o tipo da conta (por exemplo, *Mailbox-Enabled*). Vazia, quer dizer que a descoberta ficou incompleta, e o Match vai falhar pedindo um novo Discovery. A correção é o **Refresh Selected Accounts**.

---

## 4. Match e Map

| Opção | Como funciona | Quando usar |
|---|---|---|
| **Match Selected** | O ODM procura no destino uma conta com o mesmo valor num atributo escolhido | Quando existe um atributo confiável e igual nos dois lados. Rápido para muitas contas |
| **Map from File** | Um CSV diz os pares, conta por conta | Quando os nomes não batem, ou quando o cliente quer aprovar par por par |

Para lembrar: Match, o ODM descobre os pares; Map, você diz os pares. Em projeto é comum usar os dois: Match para a maioria e Map para o que sobrou ou casou errado.

### Match Selected

![Atributos do Match](img/53-odm-match-atributos.png)

| Opção | O que faz |
|---|---|
| **Clear existing matches** | Desfaz os casamentos das contas selecionadas. É o caminho de volta quando um Match casou errado |
| **Match by attributes** | Compara um atributo da origem com um atributo do destino. Os dois são escolhidos separadamente |

Os atributos, no cenário do lab:

| Atributo | Origem | Destino | Resultado |
|---|---|---|---|
| **displayName** | Teste Nexus 1 | Teste Nexus 1 | Casa, mas é frágil: nomes se repetem e mudam |
| **mail** | domínio do Tenant Origem | vazio (a regra da Fase 5 apaga) | Não casa |
| **mailNickname** | teste.nexus1 | teste.nexus1 | Casa. Boa opção sem identificador compartilhado |
| **immutableId** | o mesmo valor | o mesmo valor | Casa, e é o mais seguro |
| **employeeId** | vazio | vazio | Não casa no lab. Em empresa, a matrícula do RH costuma ser uma ótima chave |

Usei `immutableId` nos dois lados. Ele é igual nos dois tenants porque os dois Entra Connect usam o `ms-DS-ConsistencyGuid` como Source Anchor (Fases 2 e 4), o que torna o casamento determinístico.

Para lembrar: bom atributo de Match é único e igual nos dois lados. Do mais seguro ao menos seguro: identificador compartilhado (immutableId, employeeId), depois `mail` ou prefixo do UPN, por último `displayName`.

### Map from File

![Formato do CSV de mapeamento](img/54-odm-map-csv.png)

| Opção | Quando usar |
|---|---|
| **Match with existing account** | A conta já existe no destino. No lab, quem cria é o Entra Connect |
| **Map to new account** | O destino está vazio e o ODM vai criar a conta durante a migração |

Escolher *Map to new account* num destino onde a conta já existe leva a conta duplicada ou a erro de UPN em uso. A pergunta que decide: quem cria a conta no destino?

O arquivo do piloto:

```
SourceUPN,TargetUPN
teste.nexus3@<tenant-origem>.onmicrosoft.com,teste.nexus3@<tenant-b>.onmicrosoft.com
```

Também existe o formato `SourceObjectId,TargetObjectId`, mais resistente a mudança de nome.

O Map grava o par sem ler a conta do destino. Depois dele, o Teste Nexus 3 ficou com o **Target Type** vazio, enquanto os casados por Match já mostravam *Mailbox-Enabled*. Um erro de digitação no UPN só apareceria na migração. Por isso, depois de um Map, vale um **Refresh Selected Accounts** e a conferência do Target Type.

### Resultado do piloto

![Contas casadas](img/56-odm-contas-casadas.png)

| Conta | Método | Par no Tenant B |
|---|---|---|
| Teste Nexus 1 | Match por `immutableId` | Teste Nexus 1 |
| Teste Nexus 2 | Match por `immutableId` | Teste Nexus 2 |
| Teste Nexus 3 | Map from File (UPN) | Teste Nexus 3 |

Depois de um Match, a conferência é conta por conta, olhando **Target Name** e **Target UPN**. Um casamento errado também aparece como *Matched*.

---

## 5. A aba Tasks como diário do projeto

![Tarefas do piloto](img/55-odm-tasks.png)

Lendo de baixo para cima:

| Tarefa | Resultado | O que aconteceu |
|---|---|---|
| Account Discovery (from File) | Failed | Erro de função do Exchange. As contas entraram na lista, mas incompletas |
| Account Matching | Failed | Bloqueado pela falta dos dados de licença, consequência da descoberta incompleta |
| Refresh Selected Accounts | Completed | Os dados das três contas foram completados |
| Account Matching | Completed | Match feito |

O primeiro Discovery continua como *Failed* mesmo com as contas aparecendo. É a tarefa que diz se o trabalho foi completo, não a lista.

Para lembrar: num erro, leia as tarefas em ordem de tempo. A causa costuma estar numa tarefa anterior à que falhou.

### Os dois "refresh"

| Refresh | O que faz |
|---|---|
| **F5 ou atualizar a lista** | Redesenha a tela com o que já está no banco da Quest |
| **Refresh Selected Accounts** | Volta ao tenant e relê as contas |

Quando um dado está faltando ou desatualizado, é o segundo que resolve.

---

*A migração de e-mail e OneDrive vai entrando aqui.*
