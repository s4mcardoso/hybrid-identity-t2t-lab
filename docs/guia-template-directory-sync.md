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

*As próximas telas (Groups, Contacts, Devices, senha padrão, SID History e Mappings) vão entrando aqui conforme eu avanço no template.*
