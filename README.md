# Laboratório de Migração Tenant-to-Tenant (T2T) com Entra Connect Sync e Quest ODM

![Windows Server 2022](https://img.shields.io/badge/Windows%20Server-2022-0078D6?logo=windows&logoColor=white)
![Microsoft Entra ID](https://img.shields.io/badge/Microsoft%20Entra%20ID-Identidade%20h%C3%ADbrida-0078D4?logo=microsoft&logoColor=white)
![Active Directory](https://img.shields.io/badge/Active%20Directory-Multi--floresta-003A70)
![Quest ODM](https://img.shields.io/badge/Quest-On%20Demand%20Migration-E1251B)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?logo=powershell&logoColor=white)

Projeto de estudo pessoal. Montei do zero um ambiente com duas florestas Active Directory e dois tenants Microsoft 365 para praticar a parte de identidade de uma migração tenant-to-tenant. Aqui registrei como montei, o que decidi e o que deu errado no caminho.

> [!CAUTION]
> **Este é um laboratório fictício, criado exclusivamente para fins de estudo.**
> As empresas Acme e Nexus, os domínios `acme.lab` e `nexus.lab`, os servidores, os usuários e o cenário de cisão empresarial são inventados. Eles não representam nenhuma empresa, cliente ou projeto real. Todo o ambiente roda em máquinas virtuais isoladas, ligadas a tenants Microsoft 365 de teste.

---

## Resumo

| | |
|---|---|
| **O que montei** | 6 servidores Windows Server 2022, 2 florestas Active Directory e 2 tenants Microsoft 365, simulando a separação de uma empresa de um grupo. |
| **O problema** | Sincronizar a mesma floresta para dois tenants ao mesmo tempo, com o mesmo identificador para cada usuário nos dois lados. Sem isso, a migração gera contas duplicadas. |
| **Resultado** | Identidades com o mesmo `immutableId` nos dois tenants, conferido por script, regras de sincronização próprias e cinco problemas resolvidos e documentados. |

---

## Sumário

- [Por que fiz este laboratório](#por-que-fiz-este-laboratório)
- [O que pratiquei](#o-que-pratiquei)
- [Principais desafios](#principais-desafios)
- [Cenário](#cenário)
- [Arquitetura](#arquitetura)
- [Estratégia de identidade](#estratégia-de-identidade)
- [Pré-requisitos](#pré-requisitos)
- [Passo a passo](#passo-a-passo)
- [Validação](#validação)
- [Resolução de problemas](#resolução-de-problemas)
- [Lições aprendidas](#lições-aprendidas)
- [O que eu faria diferente em um projeto real](#o-que-eu-faria-diferente-em-um-projeto-real)
- [Evidências](#evidências)
- [Status e próximos passos](#status-e-próximos-passos)
- [Referências](#referências)

---

## Por que fiz este laboratório

Trabalho com migrações Microsoft 365 tenant-to-tenant. Queria entender o que acontece com as identidades antes da ferramenta de migração entrar em cena, então montei o cenário inteiro em casa.

O que eu queria aprender:

- Como uma conta do AD local vira uma conta no Entra ID e o que mantém essa conta igual entre dois tenants.
- Instalar e customizar o Entra Connect Sync com mais de uma floresta.
- Resolver erros de verdade (autenticação, DNS, Kerberos, atributos) sem um tutorial dizendo o próximo passo.
- Deixar tudo anotado para consultar depois.

---

## O que pratiquei

| Área | O que fiz | Onde ver |
|---|---|---|
| Identidade híbrida | Instalação customizada do Entra Connect Sync, Password Hash Sync, escolha e conferência do Source Anchor | [Passo a passo](#passo-a-passo) |
| Arquitetura de identidade | Estratégia para manter o `immutableId` igual em dois tenants usando o `ms-DS-ConsistencyGuid` | [Estratégia de identidade](#estratégia-de-identidade) |
| Active Directory | Duas florestas, contas Enterprise Admin, atributos de usuário | [Pré-requisitos](#pré-requisitos) |
| DNS | DNS por floresta e encaminhadores condicionais | [Infraestrutura](#infraestrutura) |
| Kerberos e horário | Falha de autenticação causada por diferença de relógio | [Problema 3](#problema-3-o-ms-ds-consistencyguid-não-é-gravado-no-ad) |
| Regras de sincronização | Regras outbound no Synchronization Rules Editor com expressões e `AuthoritativeNull` | [Fase 5](#fase-5-regras-de-transformação-customizadas) |
| PowerShell | Scripts de conferência no AD, no ADSync e no Microsoft Graph | [Validação](#validação) |
| Virtualização | 6 VMs no VMware Workstation, com snapshots para voltar atrás | [Arquitetura](#arquitetura) |

---

## Principais desafios

Os detalhes de cada um estão em [Resolução de problemas](#resolução-de-problemas).

| Desafio | O que fiz | Resultado |
|---|---|---|
| O atributo que garante o match entre os tenants não era gravado no AD, e nenhum erro claro aparecia | Investiguei a autenticação entre o servidor e o DC e achei uma diferença de relógio maior que o Kerberos aceita | Corrigi fuso e NTP, e o atributo passou a ser gravado |
| O segundo Entra Connect escolheu sozinho o identificador errado | Percebi antes de liberar a sincronização | Reinstalei com o atributo certo, e nenhum ID diferente chegou ao Tenant B |
| As regras de e-mail pareciam funcionar porque o Export ficava verde, mas o `@nexus.lab` continuava indo para o Tenant B | Coloquei um e-mail em um usuário de teste e conferi o objeto no connector space antes e depois | Troquei `NULL` por `AuthoritativeNull` e vi os atributos saírem como `delete` |
| Erro WAM no login do assistente e erro de floresta "inexistente" | Separei as causas: fluxo do WAM em um caso, senha e formato do usuário no outro | Instalação concluída |

---

## Cenário

> *Cenário fictício, criado só para dar contexto ao laboratório.*

A empresa Nexus (floresta `nexus.lab`) faz parte de um grupo. Todas as florestas do grupo sincronizam para um único tenant Microsoft 365, o Tenant Origem, pelo servidor `SRV-ADC-Acme`.

A Nexus vai sair do grupo e ganhar um tenant próprio, o Tenant B. As contas e os dados precisam ser migrados com o Quest ODM sem atrapalhar o dia a dia dos usuários.

Para isso, cada usuário da Nexus precisa existir nos dois tenants com o mesmo `onPremisesImmutableId`. Assim o mapeamento entre origem e destino fica previsível e não aparecem contas duplicadas.

O que o laboratório precisava entregar:

- A floresta `nexus.lab` sincronizando para os dois tenants ao mesmo tempo, cada um com seu próprio Entra Connect Sync.
- O mesmo `onPremisesImmutableId` para cada usuário nos dois tenants, usando o `ms-DS-ConsistencyGuid` como Source Anchor.
- UPN, `mail` e `proxyAddresses` ajustados no caminho para o Tenant B, já que o domínio `.lab` não existe fora do laboratório.
- As contas prontas para o Discovery e o mapeamento no Quest ODM.

Ferramentas: Microsoft Entra ID, Microsoft Entra Connect Sync, Active Directory e DNS no Windows Server 2022, PowerShell (módulos `ActiveDirectory`, `ADSync` e `Microsoft.Graph`), VMware Workstation e, na próxima fase, Quest On Demand Migration.

---

## Arquitetura

O ambiente roda no VMware Workstation, em uma rede NAT isolada (`192.168.150.0/24`), com 6 VMs Windows Server 2022.

```mermaid
flowchart TB
    subgraph ACME["Floresta acme.lab"]
        DC01["DC01-Acme<br/>192.168.150.10"]
    end
    subgraph NEXUS["Floresta nexus.lab"]
        DC02["DC02-Nexus<br/>192.168.150.20"]
    end

    ADCA["SRV-ADC-Acme<br/>Entra Connect Sync<br/>(origem)"]
    ADCN["SRV-ADC-Nexus<br/>Entra Connect Sync<br/>(destino)"]

    TO[("Tenant Origem")]
    TB[("Tenant B")]

    ODM{{"Quest ODM<br/>SRV-ODMAD-Acme<br/>SRV-ODMAD-Nexus"}}

    DC01 --> ADCA
    DC02 --> ADCA
    DC02 --> ADCN
    ADCA --> TO
    ADCN --> TB
    TO -. origem .- ODM
    TB -. destino .- ODM
```

| VM | Função | Floresta | IP | DNS |
|---|---|---|---|---|
| `DC01-Acme` | Controlador de domínio | `acme.lab` | 192.168.150.10 | ele mesmo |
| `SRV-ADC-Acme` | Entra Connect Sync de origem (Acme e Nexus para o Tenant Origem) | `acme.lab` | 192.168.150.11 | 192.168.150.10 |
| `SRV-ODMAD-Acme` | Agente do Quest ODM | `acme.lab` | 192.168.150.12 | 192.168.150.10 |
| `DC02-Nexus` | Controlador de domínio | `nexus.lab` | 192.168.150.20 | ele mesmo |
| `SRV-ADC-Nexus` | Entra Connect Sync de destino (só Nexus, para o Tenant B) | `nexus.lab` | 192.168.150.21 | 192.168.150.20 |
| `SRV-ODMAD-Nexus` | Agente do Quest ODM | `nexus.lab` | 192.168.150.22 | 192.168.150.20 |

---

## Estratégia de identidade

O `onPremisesImmutableId` de um usuário sincronizado é o Source Anchor convertido para Base64. Se cada Entra Connect usasse um atributo diferente como anchor, o mesmo usuário teria um ID em cada tenant.

Por isso os dois servidores usam o `ms-DS-ConsistencyGuid`, e a ordem de instalação foi pensada para o segundo aproveitar o valor gravado pelo primeiro:

```mermaid
sequenceDiagram
    autonumber
    participant A as SRV-ADC-Acme
    participant AD as DC02-Nexus
    participant TO as Tenant Origem
    participant N as SRV-ADC-Nexus
    participant TB as Tenant B

    A->>AD: Lê os usuários (ms-DS-ConsistencyGuid vazio)
    A->>TO: Exporta immutableId = Base64(objectGUID)
    A->>AD: Grava ms-DS-ConsistencyGuid = objectGUID
    Note over AD: Atributo gravado no AD
    N->>AD: Lê o ms-DS-ConsistencyGuid já gravado
    N->>TB: Exporta immutableId = Base64(ms-DS-ConsistencyGuid)
    Note over TO,TB: O usuário tem o mesmo immutableId nos dois tenants
```

1. O Entra Connect de origem é instalado primeiro. Como o `ms-DS-ConsistencyGuid` está vazio, ele usa o `objectGUID` para gerar o `immutableId` e grava esse mesmo valor no `ms-DS-ConsistencyGuid` de cada usuário da Nexus. É a "tatuagem" no AD.
2. O Entra Connect de destino é instalado depois e configurado manualmente para ler o `ms-DS-ConsistencyGuid`. Como o valor é o mesmo, o `immutableId` no Tenant B fica igual ao do Tenant Origem.

---

## Pré-requisitos

### Infraestrutura

- 6 VMs Windows Server 2022, conforme a tabela da [Arquitetura](#arquitetura), na mesma rede NAT.
- Servidores membros no domínio da própria floresta, com o DNS apontando para o DC local.
- Resolução de nomes entre as florestas. O `SRV-ADC-Acme` precisa encontrar `nexus.lab`, então os dois DCs recebem encaminhadores condicionais:

```powershell
# No DC01-Acme
Add-DnsServerConditionalForwarderZone -Name "nexus.lab" -MasterServers 192.168.150.20 -ReplicationScope Forest

# No DC02-Nexus
Add-DnsServerConditionalForwarderZone -Name "acme.lab" -MasterServers 192.168.150.10 -ReplicationScope Forest
```

- Snapshot das VMs antes de cada fase.

### Contas

| Conta | Onde | Uso |
|---|---|---|
| Global Administrator (somente nuvem) | Tenant Origem | Assistente do `SRV-ADC-Acme` |
| Global Administrator (somente nuvem) | Tenant B | Assistente do `SRV-ADC-Nexus` |
| Enterprise Admin | `acme.lab` | Inclusão da floresta Acme |
| Enterprise Admin | `nexus.lab` | Inclusão da floresta Nexus nos dois servidores |

### Software e configurações

- Microsoft Entra Connect Sync (`AzureADConnect.msi`), baixado pelo centro de administração do Microsoft Entra em *Entra Connect > Get started > Manage > Connect Sync*, na versão mais recente.
- TLS 1.2 habilitado nos servidores de sincronização.
- IE Enhanced Security Configuration (IE ESC) desativado nos servidores `SRV-ADC-*`.
- Horário sincronizado em todas as VMs (ver Fase 1).
- Uns 10 usuários de teste por floresta, com UPNs que não se repetem entre as florestas.

> [!IMPORTANT]
> Usei o Entra Connect Sync, e não o Entra Cloud Sync, porque o Cloud Sync não deixa escolher o Source Anchor nem editar regras de sincronização. As duas coisas eram necessárias aqui.

---

## Passo a passo

### Fase 1: Preparação

**Objetivo:** tirar do caminho as causas de falha mais comuns antes de instalar.

1. Desativar o IE ESC em *Server Manager > Local Server > IE Enhanced Security Configuration > Off* para administradores. Com ele ligado, o componente WAM (Web Account Manager) pode falhar ao abrir a tela de login.
2. Ajustar fuso horário e NTP em todas as VMs:

```powershell
# Fuso horário (todas as VMs)
tzutil /s "E. South America Standard Time"

# DC de cada floresta (PDC Emulator) com fonte externa
w32tm /config /manualpeerlist:"a.st1.ntp.br b.st1.ntp.br" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time

# Servidores membros sincronizando com o domínio
w32tm /config /syncfromflags:domhier /update
Restart-Service w32time
w32tm /resync /force

# Conferência
w32tm /query /status
```

> [!TIP]
> No VMware, a sincronização de horário do VMware Tools pode brigar com o `w32time`. Se o relógio continuar mudando sozinho, desligue essa opção do VMware Tools nos membros do domínio.

---

### Fase 2: Servidor de origem (`SRV-ADC-Acme`)

**Objetivo:** sincronizar `acme.lab` e `nexus.lab` para o Tenant Origem e gravar o `ms-DS-ConsistencyGuid` nos usuários.

1. Executar o `AzureADConnect.msi` e escolher **Customize**. O modo Express não aceita mais de uma floresta.
2. **User sign-in:** Password Hash Synchronization.
3. **Connect to Azure AD:** Global Admin do Tenant Origem.
4. **Connect your directories:**
   - Adicionar `acme.lab` com o Enterprise Admin da Acme.
   - Adicionar `nexus.lab` com o Enterprise Admin da Nexus, no formato UPN (`administrator@nexus.lab`).
5. **Domain/OU filtering:** todos os domínios e OUs.
6. **Uniquely identifying your users:**
   - *Users are represented only once across all directories*.
   - Source Anchor: *Let Azure manage the source anchor for me*. Na primeira instalação, essa opção define o `ms-DS-ConsistencyGuid`.
7. **Optional features:** nenhum writeback adicional.
8. Deixar marcada a opção *Start the synchronization process when configuration completes* e concluir.
9. Conferir no `DC02-Nexus` se o atributo foi gravado (ver [Validação](#ms-ds-consistencyguid-gravado-no-ad)).

---

### Fase 3: Problemas no servidor de origem

Três problemas apareceram aqui. Os detalhes estão em [Resolução de problemas](#resolução-de-problemas).

| # | Sintoma | Causa | Ação |
|---|---|---|---|
| 1 | Erro WAM `3400007680` (NoInternet) | Fluxo de autenticação do WAM (TLS 1.2 e cache) | `.\AzureADConnect.exe /InteractiveAuth` |
| 2 | Floresta `nexus.lab` "doesn't exist" | Senha errada e usuário no formato `DOMÍNIO\usuário` | Credencial no formato UPN |
| 3 | `ms-DS-ConsistencyGuid` não gravado | Relógio fora da tolerância do Kerberos | `tzutil` e NTP |

---

### Fase 4: Servidor de destino (`SRV-ADC-Nexus`)

**Objetivo:** sincronizar só `nexus.lab` para o Tenant B, aproveitando o `ms-DS-ConsistencyGuid` que já está gravado.

1. Instalação **Customize** com o Global Admin do Tenant B.
2. **Connect your directories:** adicionar somente `nexus.lab`.
3. **Uniquely identifying your users:** escolher *Choose a specific attribute* e informar `mS-DS-ConsistencyGuid`.

> [!WARNING]
> Neste servidor, não use *Let Azure manage the source anchor*. Quando o assistente encontra o `ms-DS-ConsistencyGuid` já preenchido, ele entende que outra aplicação usa o atributo e volta para o `objectGUID`. O Tenant B receberia outro `immutableId` e o mapeamento quebraria. Como o Source Anchor não pode ser trocado livremente depois de instalado, a correção no laboratório foi desinstalar e instalar de novo.

4. Na última tela, **desmarcar** *Start the synchronization process when configuration completes*. Assim nada vai para o Tenant B antes das regras da próxima fase existirem.

---

### Fase 5: Regras de transformação customizadas

**Objetivo:** ajustar os atributos no caminho para o Tenant B, onde o domínio `nexus.lab` não existe.

Sem essas regras, os usuários chegariam ao Tenant B com login e e-mail `@nexus.lab`, um domínio que não existe nem pode ser verificado lá. As regras mudam esses valores só para o Tenant B. O AD local e o Tenant Origem continuam iguais.

No `SRV-ADC-Nexus`, abrir o Synchronization Rules Editor, escolher *Direction: Outbound* e clicar em **Add new rule**. As três regras usam a mesma base:

| Campo | Valor |
|---|---|
| Connected System | Conector do Tenant B (`<tenantb>.onmicrosoft.com - AAD`) |
| Connected System Object Type | `user` |
| Metaverse Object Type | `person` |
| Link Type | `Join` |
| Scoping filter | vazio |
| Join rules | vazio |

Quando duas regras mandam valor para o mesmo atributo, vale a de número de precedência menor. As regras padrão da Microsoft (*Out to AAD - User Join* e parecidas) começam em 100, então usei 50, 51 e 52, um número diferente para cada regra.

#### Regra 1: UPN (precedência 50)

| FlowType | Target Attribute | Source | Apply Once | Merge Type |
|---|---|---|---|---|
| Expression | `userPrincipalName` | `Left([userPrincipalName], InStr([userPrincipalName], "@")) & "<tenantb>.onmicrosoft.com"` | Não | Update |

Exemplo: `joao.silva@nexus.lab` vira `joao.silva@<tenantb>.onmicrosoft.com`. O `InStr` devolve a posição do `@`, e o `Left` guarda tudo até ele, com o `@` incluído.

#### Regra 2: Mail (precedência 51)

| FlowType | Target Attribute | Source | Merge Type |
|---|---|---|---|
| Expression | `mail` | `AuthoritativeNull` | Update |

#### Regra 3: ProxyAddresses (precedência 52)

| FlowType | Target Attribute | Source | Merge Type |
|---|---|---|---|
| Expression | `proxyAddresses` | `AuthoritativeNull` | Update |

> [!IMPORTANT]
> Para deixar um atributo vazio no Entra Connect, use `AuthoritativeNull`. Um `NULL` comum quer dizer "esta regra não envia nada", e aí a regra padrão manda o valor original.
>
> Na primeira versão do laboratório eu usei `NULL` nas regras 2 e 3, e só percebi o erro quando testei com um usuário que tinha e-mail. Está no [problema 5](#problema-5-as-regras-com-null-não-removiam-o-e-mail).

---

### Fase 6: Ativação

```powershell
# No SRV-ADC-Nexus
Set-ADSyncScheduler -SyncCycleEnabled $true
Start-ADSyncSyncCycle -PolicyType Initial

# Acompanhamento
Get-ADSyncScheduler
```

1. No Synchronization Service Manager, aba *Operations*, conferir o status *success* em *Full Import*, *Full Synchronization* e *Export*.
2. Rodar as conferências da [Validação](#validação).

Usei `Initial` e não `Delta` porque mudanças em regras precisam ser aplicadas a todos os objetos. O `Delta` só reprocessa o que mudou no AD.

---

## Validação

### `ms-DS-ConsistencyGuid` gravado no AD

```powershell
# No DC02-Nexus: mostra o GUID já convertido para o formato do immutableId
Get-ADUser -Filter * -Properties 'mS-DS-ConsistencyGuid' |
    Select-Object SamAccountName, UserPrincipalName,
        @{ n = 'ImmutableId'; e = { if ($_.'mS-DS-ConsistencyGuid') { [Convert]::ToBase64String($_.'mS-DS-ConsistencyGuid') } } }
```

Se a coluna `ImmutableId` vier vazia para algum usuário, o atributo não foi gravado (ver [problema 3](#problema-3-o-ms-ds-consistencyguid-não-é-gravado-no-ad)).

### Source Anchor de cada servidor

```powershell
# Em cada SRV-ADC-*
(Get-ADSyncGlobalSettings).Parameters |
    Where-Object Name -eq 'Microsoft.SynchronizationOption.AnchorAttribute' |
    Select-Object Name, Value
```

Nos dois servidores o resultado precisa ser `mS-DS-ConsistencyGuid`.

### `onPremisesImmutableId` igual nos dois tenants

```powershell
# Rodar uma vez em cada tenant, trocando o TenantId e o nome do arquivo
Connect-MgGraph -TenantId "<tenant>.onmicrosoft.com" -Scopes "User.Read.All"
Get-MgUser -All -Property displayName, userPrincipalName, onPremisesImmutableId |
    Where-Object onPremisesImmutableId |
    Select-Object displayName, userPrincipalName, onPremisesImmutableId |
    Export-Csv ".\tenant-origem.csv" -NoTypeInformation -Encoding UTF8
Disconnect-MgGraph

# Comparação entre os dois arquivos
$origem  = Import-Csv .\tenant-origem.csv
$destino = Import-Csv .\tenant-b.csv
Compare-Object $origem $destino -Property onPremisesImmutableId -IncludeEqual |
    Group-Object SideIndicator | Select-Object Name, Count
```

| Indicador | O que significa |
|---|---|
| `==` | Usuário da Nexus nos dois tenants com o mesmo ID (esperado) |
| `<=` | Usuário da Acme, que só existe no Tenant Origem (esperado) |
| `=>` | Usuário que só existe no Tenant B (precisa investigar) |

### Checklist final

- [x] O Tenant Origem tem usuários das florestas Acme e Nexus.
- [x] O Tenant B tem somente usuários da Nexus (10 usuários e 2 grupos no conector).
- [x] Os UPNs no Tenant B terminam em `@<tenantb>.onmicrosoft.com`.
- [x] Cada usuário da Nexus tem o mesmo `onPremisesImmutableId` nos dois tenants.
- [x] `mail` e `proxyAddresses` com `@nexus.lab` não chegam ao Tenant B.
- [x] A sincronização terminou com status *success* no Synchronization Service Manager.

---

## Resolução de problemas

Cada problema está na mesma ordem: sintoma, causa, solução e prevenção.

### Problema 1: erro WAM `3400007680` (NoInternet) no assistente

| | |
|---|---|
| **Sintoma** | O login do Entra ID falha na primeira tentativa com o código `3400007680` (NoInternet), mesmo com a internet funcionando. |
| **Causa** | Falha no fluxo de autenticação do WAM (Web Account Manager), ligada ao TLS 1.2 e ao cache do WAM. O IE ESC ligado piora a situação. |
| **Solução** | Fechar o assistente e abrir de novo forçando o login interativo: |

```powershell
cd "C:\Program Files\Microsoft Azure Active Directory Connect"
.\AzureADConnect.exe /InteractiveAuth
```

**Prevenção:** desativar o IE ESC e conferir o TLS 1.2 antes de instalar.

---

### Problema 2: "The forest doesn't exist" ao adicionar `nexus.lab`

| | |
|---|---|
| **Sintoma** | Ao adicionar o diretório `nexus.lab` no `SRV-ADC-Acme`, o assistente diz que a floresta não existe ou não responde. |
| **Causa** | Senha errada junto com o usuário no formato `NEXUS\administrator`. |
| **Solução** | Usar a credencial no formato UPN: `administrator@nexus.lab`. |

Antes de mexer na credencial, vale descartar o DNS:

```powershell
# No SRV-ADC-Acme
Resolve-DnsName nexus.lab
Resolve-DnsName -Type SRV _ldap._tcp.dc._msdcs.nexus.lab
Test-NetConnection 192.168.150.20 -Port 389
```

Se a resolução falhar, confira os encaminhadores condicionais em [Infraestrutura](#infraestrutura).

---

### Problema 3: o `ms-DS-ConsistencyGuid` não é gravado no AD

| | |
|---|---|
| **Sintoma** | A sincronização roda, mas o atributo continua vazio nos usuários da Nexus. Sem ele, o match entre os tenants não funciona. |
| **Causa** | Fuso horário errado nas VMs. A diferença real entre os relógios passava dos 5 minutos que o Kerberos tolera, a autenticação falhava e o Entra Connect não conseguia gravar no AD. |
| **Solução** | Corrigir o fuso, forçar o NTP (Fase 1) e rodar um novo ciclo de sincronização. |

```powershell
# Medir a diferença em relação ao DC da Nexus
w32tm /stripchart /computer:DC02-Nexus /samples:3 /dataonly

# Corrigir
tzutil /s "E. South America Standard Time"
w32tm /resync /force

# Limpar os tickets Kerberos antigos e sincronizar de novo
klist purge
Start-ADSyncSyncCycle -PolicyType Delta
```

Depois, conferir com o script de [Validação](#ms-ds-consistencyguid-gravado-no-ad).

---

### Problema 4: o servidor de destino escolheu o `objectGUID` como Source Anchor

| | |
|---|---|
| **Sintoma** | No `SRV-ADC-Nexus`, a opção *Let Azure manage the source anchor* resultou em `objectGUID`. |
| **Causa** | O assistente encontrou o `ms-DS-ConsistencyGuid` preenchido pelo servidor de origem e voltou para o `objectGUID` por precaução. |
| **Impacto** | O Tenant B receberia outro `immutableId` e o mapeamento no ODM não bateria. |
| **Solução** | Desinstalar o Entra Connect, instalar de novo e escolher *Choose a specific attribute* com `mS-DS-ConsistencyGuid`. |

**Prevenção:** no segundo servidor, escolher o atributo manualmente e manter a sincronização desligada até conferir o anchor com o comando de [Validação](#source-anchor-de-cada-servidor).

---

### Problema 5: as regras com `NULL` não removiam o e-mail

| | |
|---|---|
| **Sintoma** | As regras de `mail` e `proxyAddresses` estavam criadas e o Export terminava com *success*, mas o e-mail `@nexus.lab` continuava indo para o Tenant B. Ninguém percebia porque os usuários de teste não tinham e-mail no AD. |
| **Causa** | No Entra Connect, uma regra que devolve `NULL` é tratada como "não contribui", então a regra padrão continuava mandando o valor original. E o Entra ID aceita esse valor sem erro, por isso o Export verde não provava nada. |
| **Solução** | Editar as regras 2 e 3, trocar o Source de `NULL` para `AuthoritativeNull` e rodar `Start-ADSyncSyncCycle -PolicyType Initial`. |

**Como reproduzi:**

```powershell
# No DC02-Nexus: dar um e-mail a um usuário de teste
Set-ADUser teste.nexus8 -EmailAddress 'teste.nexus8@nexus.lab' -Add @{ proxyAddresses = 'SMTP:teste.nexus8@nexus.lab' }

# No SRV-ADC-Nexus: sincronizar
Start-ADSyncSyncCycle -PolicyType Delta
```

Depois abri o objeto do usuário em Synchronization Service Manager > Connectors > conector do Tenant B > *Search Connector Space*:

| Com `NULL` | Com `AuthoritativeNull` |
|---|---|
| `mail` aparece como **add** com `teste.nexus8@nexus.lab` | `mail` e `proxyAddresses` aparecem como **delete** |
| ![Regra com NULL: mail adicionado](docs/img/06a-mail-antes.png) | ![Regra com AuthoritativeNull: mail removido](docs/img/06b-mail-depois.png) |

**Prevenção:** testar regras de transformação com um objeto que tenha o atributo preenchido e olhar o connector space, em vez de confiar no status do Export.

> [!TIP]
> Para abrir uma regra em modo de edição, selecione a regra e clique em **Edit**. O duplo clique abre a regra só para visualização, e o botão Save fica desativado.

---

## Lições aprendidas

1. **A ordem de instalação faz parte da arquitetura.** O primeiro Entra Connect grava o atributo no AD e o segundo só lê. Se a ordem muda, ou se o segundo servidor escolhe o anchor sozinho, o match se perde.
2. **No segundo servidor, o padrão do assistente não serve.** A troca para `objectGUID` acontece sem aviso e só aparece na conferência.
3. **Horário também é infraestrutura.** Um fuso errado parece detalhe, mas derruba o Kerberos e, junto, a gravação no AD. Fuso e NTP agora entram no meu checklist antes de qualquer instalação.
4. **Com várias florestas, começo por DNS e formato de credencial.** Encaminhadores condicionais e usuário no formato UPN evitam o erro de floresta inexistente.
5. **A sincronização só é liberada depois das regras.** Desmarcar a opção de iniciar a sincronização evita mandar atributos errados para o tenant e ter que corrigir depois.
6. **`NULL` e `AuthoritativeNull` não são a mesma coisa.** Para apagar um atributo, a regra de maior prioridade precisa usar `AuthoritativeNull`. Aprendi isso testando: com `NULL`, o e-mail continuava indo para o tenant e nada indicava erro.
7. **Export com *success* não quer dizer que a regra funcionou.** A prova está no connector space, com um objeto que tenha o atributo preenchido.
8. **Entra Connect Sync em vez de Cloud Sync** quando o cenário exige escolher o Source Anchor e criar regras próprias.
9. **Conferir com script.** Comparar o `immutableId` dos dois tenants por PowerShell me deu mais segurança do que olhar alguns usuários no portal.

---

## O que eu faria diferente em um projeto real

O laboratório tem simplificações que não caberiam em produção:

| No laboratório | Em um projeto real |
|---|---|
| Domínio `.lab`, com UPN reescrito e e-mail apagado | Domínios públicos verificados nos tenants e um plano de troca de domínio |
| Reinstalação do Entra Connect para corrigir o Source Anchor | Source Anchor decidido e documentado antes da instalação, com checklist para cada tela do assistente |
| Conferência feita depois da primeira sincronização | Servidor em Staging Mode para conferir o resultado antes de exportar qualquer coisa |
| Regras testadas com usuários sem e-mail | Regras testadas com objetos que tenham todos os atributos que a regra altera |
| Global Admin e Enterprise Admin para tudo | Contas de serviço só com as permissões necessárias |
| Bloqueio de tela desativado nas VMs | Bloqueio de tela e tempo de inatividade mantidos, porque são controles de segurança |
| Usuários de teste | Comunicação com os usuários, janela de manutenção e plano de rollback |

---

## Evidências

Capturas de tela do laboratório, com o nome dos tenants escondido.

### O `ms-DS-ConsistencyGuid` gravado no AD

Attribute Editor do usuário Teste Nexus 8 no `DC02-Nexus`, com o atributo preenchido pelo Entra Connect de origem:

![Attribute Editor com mS-DS-ConsistencyGuid](docs/img/01-attribute-editor.png)

### O mesmo valor no AD e no Tenant B

No AD, o `ms-DS-ConsistencyGuid` convertido para Base64 dá `ELKIWlsVPEutQV96hh8idw==`:

![ImmutableId calculado no AD](docs/img/02-immutableid-ad.png)

No connector space do Tenant B, o `sourceAnchor` enviado pelo `SRV-ADC-Nexus` é o mesmo valor, e o UPN já aparece reescrito pela regra 1:

![Connector space do Tenant B](docs/img/03-connector-space-tenantb.png)

Reparei também que o nome do objeto no conector, `CN={454C4B4957...}`, é o próprio `sourceAnchor` em hexadecimal: `45` = E, `4C` = L, `4B` = K, `49` = I, `57` = W, e assim por diante.

### Correção das regras de e-mail

Os prints de antes e depois estão no [problema 5](#problema-5-as-regras-com-null-não-removiam-o-e-mail).

---

## Status e próximos passos

| Etapa | Status |
|---|---|
| Infraestrutura (6 VMs, 2 florestas, DNS e NTP) | Concluída |
| Entra Connect Sync de origem (Acme e Nexus para o Tenant Origem) | Concluída |
| Entra Connect Sync de destino (Nexus para o Tenant B) | Concluída |
| Regras de transformação | Concluída |
| Conferência do `immutableId` entre os tenants | Concluída |
| Instalação dos agentes do Quest ODM | Próxima etapa |
| Discovery e mapeamento de usuários e grupos no ODM | Planejada |
| Migração de dados por módulo (e-mail, OneDrive, Teams) | Planejada |

Próximas ações:

- [ ] Instalar os agentes do Quest ODM no `SRV-ODMAD-Acme` e no `SRV-ODMAD-Nexus`, conferindo os requisitos na documentação da Quest.
- [ ] Conectar o Tenant Origem e o Tenant B no ODM.
- [ ] Rodar o Discovery de contas e grupos.
- [ ] Mapear usuários e grupos entre origem e destino e conferir o resultado.
- [ ] Migrar os dados módulo por módulo e registrar os resultados aqui.

---

## Referências

- [Microsoft Entra Connect: design concepts (sourceAnchor e ms-DS-ConsistencyGuid)](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/plan-connect-design-concepts)
- [Microsoft Entra Connect Sync: alterações na configuração padrão](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-sync-change-the-configuration)
- [Microsoft Entra Connect Sync: agendador (scheduler)](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-sync-feature-scheduler)
- [Quest On Demand Migration: documentação técnica](https://support.quest.com/on-demand-migration)

---

## Autor

**Samuel Cardoso de Oliveira**
Profissional de TI na área de migrações Microsoft 365 tenant-to-tenant. Estudante de Análise e Desenvolvimento de Sistemas | Facens - Faculdade de Engenharia de Sorocaba.

[LinkedIn](https://www.linkedin.com/in/samcardosoti/) · [GitHub](https://github.com/s4mcardoso)

> **Aviso:** este repositório documenta um **laboratório fictício, feito apenas para estudo**. Empresas, domínios, usuários e cenário são inventados e não correspondem a nenhuma organização ou projeto real. O projeto não tem vínculo com a Microsoft nem com a Quest Software. Teste qualquer procedimento em ambiente controlado antes de usar em produção.
