# Guia de consulta: opções do template do Quest Directory Sync

Anotações que fiz enquanto montava o template `Local to Local SID History Sync` no laboratório. A ideia é ter um lugar para consultar o que cada opção faz e em que situação usar.

[Voltar ao README](../README.md)

---

## Duas ideias que aparecem em todas as telas

### Objeto criado e objeto casado

Quando o workflow roda, para cada objeto da origem o Directory Sync procura um correspondente no destino.

- **Não encontrou:** ele cria o objeto no destino. A partir daí é um objeto **criado** (*created*).
- **Encontrou:** ele vincula os dois, usando as regras de correspondência do workflow (sAMAccountName, e-mail, UPN). É um objeto **casado** (*matched*).

Para lembrar: **criado é meu, casado é emprestado.** No que eu criei eu mexo à vontade. No que já existia eu penso duas vezes, porque alguém pode ter cuidado daquela conta antes.

### O workflow roda várias vezes

Em projeto real o workflow fica rodando por semanas antes da virada, manual ou agendado. Por isso muitas opções perguntam o que fazer nas execuções seguintes, e não só na primeira.

### Migração em lotes e coexistência

Ninguém migra centenas de usuários num dia só. A migração vai em lotes, e durante semanas parte das pessoas está no ambiente novo e parte no antigo. Esse período é a **coexistência**. Durante ela, todo mundo precisa continuar aparecendo na lista de endereços e recebendo e-mail, não importa de que lado esteja. Várias opções do template existem por causa disso.

---

## Users

![Tela de Users do template](img/26-template-users.png)

### Create new users as: como a conta nasce no destino

| Opção | O que faz | Quando usar |
|---|---|---|
| **AS-IS** | Copia o estado da origem. Ativa na origem, ativa no destino. Desativada na origem, desativada no destino | Coexistência e testes. Foi o que usei no lab, porque o usuário migrado precisa fazer login para testar o SID History |
| **DISABLED** | Cria sempre desativada | O mais comum em migração real. As contas são criadas semanas antes (*pre-staging*) e só são liberadas no dia da virada, para ninguém usar duas contas ao mesmo tempo |
| **ENABLED** | Cria sempre ativa, mesmo que esteja desativada na origem | Raro. O risco é reativar alguém que já saiu da empresa |
| **CONTACT** | Cria um contato em vez de usuário. Aparece na lista de endereços, mas não faz login | Sincronização de catálogo (GAL sync): o destino só precisa enxergar e mandar e-mail para as pessoas da origem |
| **SKIP** | Não cria nada | Quando as contas no destino já existem e o workflow só deve atualizar |

Para lembrar: **espelha, tranca, libera, lista, pula.**

### Update created users: atualizar as contas que o Directory Sync criou

- **ENABLE:** mudanças na origem (cargo, telefone, sobrenome, gerente) chegam na conta do destino nas próximas execuções.
- **DISABLE:** a conta é criada uma vez e depois não é mais tocada.

Quase sempre fica em ENABLE. Entre a criação da conta e a virada passam semanas, e as pessoas mudam de cargo, de telefone e até de nome. Uso DISABLE só quando o time do destino assume a conta logo depois de criada.

Para lembrar: **quem cria, cuida.**

### Update matched users: atualizar as contas que já existiam

- **ENABLE:** a origem passa a mandar e sobrescreve os atributos da conta do destino.
- **DISABLE:** o Directory Sync só faz o vínculo e não mexe nos dados.

Uso ENABLE quando a origem é a fonte da verdade e as contas do destino estão incompletas. Uso DISABLE quando o destino já tem dados bons e a origem poderia estragar.

### If target address exists: o redirecionamento de e-mail

O `targetAddress` funciona como o redirecionamento de correspondência dos Correios: diz ao servidor de e-mail que aquela conta não tem caixa ali e que as mensagens devem ser entregues em outro endereço.

Exemplo na coexistência:

1. A caixa do João ainda está na Acme. O Directory Sync cria a conta dele na Nexus, sem caixa, com `targetAddress = joao@acme.com`.
2. Alguém da Nexus escolhe "João" no Outlook e manda um e-mail. O servidor da Nexus vê que a conta não tem caixa, lê o `targetAddress` e repassa para a Acme. O João recebe normalmente.
3. No dia da virada, a caixa do João vai para a Nexus. A migração apaga o `targetAddress` da conta da Nexus, e a conta antiga na Acme passa a apontar para a Nexus. O redirecionamento inverte de lado.

A opção define o que o Directory Sync faz quando encontra o campo já preenchido:

| Opção | O que faz | Quando usar |
|---|---|---|
| **OVERWRITE ONCE** | Escreve uma vez e depois respeita mudanças feitas no destino | Padrão em migração com virada. Configura o redirecionamento no começo e deixa a migração de e-mail assumir depois |
| **OVERWRITE ALWAYS** | Escreve em toda execução, mesmo que alguém tenha mudado | Convivência permanente, quando ninguém vai migrar e as empresas só precisam se ver e trocar e-mail. Mantém o redirecionamento atualizado (por exemplo, quando o endereço da pessoa muda na origem) e corrige mudanças manuais erradas |
| **DO NOT OVERWRITE** | Se já tem valor, não mexe | Quando outra ferramenta é a dona do redirecionamento |

O risco do OVERWRITE ALWAYS numa migração: depois da virada, a próxima execução recoloca `joao@acme.com` na conta da Nexus, os e-mails voltam a ser repassados para uma caixa que não existe mais e o João para de receber e-mail.

O ponto fraco do OVERWRITE ONCE: se o endereço da pessoa mudar na origem depois da primeira execução (a Ana se casa e vira `ana.souza@acme.com`), o redirecionamento continua apontando para o endereço antigo.

Para lembrar:

- **ONCE:** eu configuro e saio da frente. Vai ter migração.
- **ALWAYS:** eu mando nisso para sempre. Não vai ter migração.
- **DO NOT OVERWRITE:** isso não é meu.

No lab essa opção não tem efeito, porque não existe Exchange local lendo o campo.

### Escolhas no laboratório

| Opção | Escolha |
|---|---|
| Create new users as | AS-IS |
| Update created users | ENABLE |
| Update matched users | ENABLE |
| If target address exists | OVERWRITE ONCE |

---

## Groups

![Tela de Groups do template](img/27-template-groups.png)

### Base: tipo e escopo de grupo

Todo grupo do AD tem um tipo e um escopo.

| Tipo | Para que serve |
|---|---|
| **Security** | Dar permissão em pastas, impressoras e sistemas. Também pode receber e-mail |
| **Distribution** | Só e-mail. Não serve para permissão |

| Escopo | Quem pode ser membro | Onde pode receber permissão |
|---|---|---|
| **Global** | Só contas do mesmo domínio | Em qualquer domínio que confie nele |
| **Domain Local** | Contas de qualquer lugar, inclusive de outra floresta via trust | Só no próprio domínio |
| **Universal** | Contas de qualquer domínio da mesma floresta | Em qualquer domínio da floresta |

A regra clássica da Microsoft para organizar isso é a **AGDLP**: as contas (**A**ccount) entram num grupo **G**lobal, que organiza as pessoas. O Global entra num **D**omain **L**ocal, que representa o recurso. O Domain Local recebe a **P**ermissão.

Numa migração entre florestas, só o Domain Local aceita membros da outra floresta. Foi por isso que consegui colocar o `NEXUS\svc-odm` no grupo Administrators da Acme: o Administrators é Domain Local.

Para lembrar: Global é bairrista (só gente do próprio domínio). Domain Local é hospitaleiro (aceita gente de fora, mas só trabalha em casa). Universal é da cidade inteira (circula pela floresta, mas não aceita estrangeiro).

### Create groups as: como o grupo nasce no destino

| Opção | O que faz | Quando usar |
|---|---|---|
| **AS-IS** | Mantém o tipo. Security continua Security, Distribution continua Distribution | Migração normal, quando os grupos vão continuar dando permissão no destino |
| **DISTRIBUTION GROUPS** | Cria tudo como distribuição, mesmo que na origem seja segurança | Quando o destino só precisa dos grupos para e-mail e não deve herdar nenhuma permissão por engano |
| **CONTACTS** | Cria o grupo como contato na lista de endereços | GAL sync: o grupo só precisa aparecer na lista para receber e-mail |
| **SKIP** | Não cria grupos | Workflow só de usuários, ou grupos recriados de outra forma |

Para lembrar: AS-IS é grupo de verdade, Distribution é só e-mail, Contacts é só na lista, Skip é sem grupos.

### Update created groups e Update matched groups

A mesma lógica dos usuários. Num grupo, o que mais importa é a lista de membros: com ENABLE, quem entra ou sai do grupo na origem entra ou sai no destino também.

### Convert group options: trocar o escopo no caminho

| Origem | Opções | Quando converter |
|---|---|---|
| **Domain Local** | Domain Local, Universal ou Skip | Para Universal quando o grupo precisa dar permissão em vários domínios da floresta de destino |
| **Global** | Global, Universal ou Skip | Para Universal quando o destino tem vários domínios e o grupo vai receber membros de mais de um. Caso típico de consolidação de várias empresas numa floresta só |
| **Universal** | Universal, Domain Local ou Skip | Para Domain Local quando o grupo precisa aceitar membros de outra floresta durante a coexistência com trust |

Skip em qualquer linha deixa os grupos daquele escopo para trás.

### Escolhas no laboratório

| Opção | Escolha |
|---|---|
| Create groups as | AS-IS |
| Update created groups | ENABLE |
| Update matched groups | ENABLE |
| Domain Local / Global / Universal | Mantidos no mesmo escopo |

No lab essa tela ainda não teve efeito, porque a OU de origem só tem o `teste.acme1`.

---

## Contacts

![Tela de Contacts do template](img/28-template-contacts.png)

### O que é um contato

Um contato é um cartão de visita dentro do AD: nome, e-mail, telefone e empresa. Não faz login, não tem SID (não recebe permissão) e o e-mail dele é de fora da empresa. Serve para colocar fornecedores, parceiros e o contador na lista de endereços do Outlook.

Para lembrar: usuário é funcionário (tem crachá), contato é visitante na agenda (só nome e telefone).

O contato não serve para liberar envio de e-mail. No e-mail da empresa dá para mandar para qualquer endereço, igual ao pessoal. A diferença está na **lista de endereços da empresa**, a GAL (*Global Address List*): é como a lista de ramais, mantida pelo TI e igual para todo mundo. Os usuários aparecem nela automaticamente, e o contato é o jeito de colocar alguém de fora nessa lista oficial.

Na prática, serve para:

- **Todo mundo achar a mesma pessoa** sem cada um salvar na própria agenda (por exemplo, o fiscal do escritório de contabilidade).
- **Colocar gente de fora em grupos de e-mail.** Um grupo só aceita membros que existem no AD, então os engenheiros da construtora parceira entram no `projeto-obra@empresa.com` como contatos.
- **Fazer duas empresas se enxergarem na migração** (GAL sync): as pessoas da Acme aparecem como contatos na lista da Nexus durante a coexistência.

Para lembrar: contato do AD não é sobre poder mandar e-mail, é sobre aparecer na lista de ramais da empresa. Agenda pessoal só você vê; a GAL a empresa inteira vê.

Em boa parte é comodidade: achar a pessoa pelo nome, não errar o endereço, ver cargo e telefone no Outlook. Mas em três situações vira necessidade:

- **Controle centralizado.** Se o endereço do contato muda, o TI atualiza num lugar só e todo mundo passa a usar o novo. Com agendas pessoais, cada um continuaria mandando para o endereço antigo sem perceber.
- **Grupos de e-mail.** O grupo não aceita um endereço digitado solto, só membros que existem no AD. Sem contato, não dá para incluir gente de fora.
- **Migração.** Ninguém sabe de cabeça o e-mail de centenas de colegas que ainda estão do outro lado. Sem os contatos na GAL, a comunicação entre as duas empresas trava durante a coexistência. Por isso a sincronização de catálogo costuma ser uma das primeiras coisas configuradas num projeto de fusão ou separação.

Resumo: no dia a dia, o contato é qualidade de vida; em grupos de e-mail e numa migração, é necessidade.

### Create new contacts as

| Opção | O que faz | Quando usar |
|---|---|---|
| **AS-IS** | Copia os contatos da origem como contatos no destino | Quando a empresa nova também precisa enxergar esses fornecedores e parceiros |
| **DO NOT CREATE** | Ignora os contatos da origem | Quando os contatos só interessam à origem, ou para evitar duplicidade: se a origem tem contatos que representam pessoas do destino (de uma sincronização de catálogo antiga), copiá-los de volta criaria um "João contato" ao lado do "João usuário" |

Não existem as opções de ativo ou desativado, porque contato não faz login.

### Update created contacts e Update matched contacts

A mesma lógica de usuários e grupos. Se o telefone do fornecedor muda na origem, com ENABLE ele muda no destino.

### Escolhas no laboratório

AS-IS, ENABLE e ENABLE. A OU de origem não tem contatos, então não teve efeito.

---

## Devices

![Tela de Devices do template](img/29-template-devices.png)

### O que é um device

Quando um computador entra no domínio, o AD cria uma conta para ele, parecida com a de um usuário: nome, SID e uma senha que o computador e o DC combinam entre si e trocam sozinhos de tempos em tempos. O `Test-ComputerSecureChannel` testa justamente se essa senha ainda bate com a do DC.

Para lembrar: o usuário tem crachá, e o computador também tem o dele. É o crachá do computador que deixa a máquina conversar com o domínio.

### Copiar a conta não migra o computador

Criar a conta do computador no destino não muda nada na máquina. Ela continua no domínio antigo, falando com o DC antigo. A conta nova fica vazia, como um crachá que ninguém usa. Para o computador mudar de domínio é preciso mexer na própria máquina (sair do domínio antigo, entrar no novo, ajustar perfis e permissões), e isso é trabalho do módulo de migração de dispositivos do ODM (Active Directory), não do Directory Sync.

### Create new devices as

| Opção | O que faz | Quando usar |
|---|---|---|
| **AS-IS, ENABLED ou DISABLED** | Cria a conta do computador no destino, com a mesma lógica dos usuários | Quando o projeto vai migrar computadores e quer as contas pré-criadas. Normalmente DISABLED, para a conta só acordar no dia da virada daquela máquina |
| **SKIP** | Não cria contas de computador | Workflow só de identidades (usuários e grupos), ou computadores migrados de outro jeito |

Update created devices e Update matched devices seguem a mesma lógica das outras telas. Com SKIP, perdem o sentido.

### Escolhas no laboratório

Essa foi a única tela em que mudei o padrão, seguindo o guia de SID History da Quest:

| Opção | Escolha |
|---|---|
| Create new devices as | SKIP |
| Update created devices | DISABLE |
| Update matched devices | DISABLE |

Os computadores ficam para a fase de migração de dispositivos.

---

*As próximas telas (senha padrão, SID History e Mappings) vão entrando aqui conforme eu avanço no template.*
