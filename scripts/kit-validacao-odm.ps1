#Requires -Version 5.1
<#
.SYNOPSIS
    Kit de validação para o piloto do Quest ODM M365.

.DESCRIPTION
    Cria um conteúdo conhecido nas contas de teste do tenant de origem (e-mails, pasta,
    anexo, reunião, contato e arquivos no OneDrive) e gera um manifesto em CSV.
    Depois da migração, o manifesto diz exatamente o que precisa ter chegado no destino.

    Como funciona por dentro:
      1. Login de admin e confirmação do tenant.
      2. Escolha das contas de teste.
      3. Criação de um app temporário com permissões de aplicação no Microsoft Graph.
      4. Pedido de criação antecipada dos OneDrives (origem e destino).
      5. Criação do conteúdo, entrando como o app.
      6. Resumo, manifesto e exclusão do app temporário.

    USE SÓ EM TENANT DE LABORATÓRIO OU COM APROVAÇÃO DO CLIENTE.
    O app temporário tem permissão de ler e gravar e-mail e arquivos de todo o tenant
    enquanto existe (alguns minutos).

.EXAMPLE
    .\kit-validacao-odm.ps1
    Abre o menu e a tabela de escolha das contas.

.EXAMPLE
    .\kit-validacao-odm.ps1 -Modo SoOneDrive -Usuarios teste.nexus1,teste.nexus2

.EXAMPLE
    .\kit-validacao-odm.ps1 -Modo Validar
    Compara origem e destino: pastas do kit no Exchange Online e arquivos no OneDrive.

.EXAMPLE
    .\kit-validacao-odm.ps1 -WhatIf
    Simulação: mostra todas as telas e o que seria feito, sem login e sem mudar nada.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]   $Tenant        = "__ORIGEM__",
    [string]   $TenantDestino = "__DESTINO__",
    [string[]] $Usuarios,
    [string]   $CsvUsuarios,
    [ValidateSet("Completo", "SoOneDrive", "Validar")]
    [string]   $Modo,
    [ValidateRange(1, 50)]
    [int]      $QtdEmails = 3,
    [switch]   $SemProvisionar,
    # Mostra tudo o que seria feito, sem login e sem mudar nada (o mesmo que -WhatIf)
    [switch]   $Simular,
    [int]      $EsperaOneDriveMin = 40
)

$ErrorActionPreference = "Stop"
if ($WhatIfPreference) { $Simular = $true; $WhatIfPreference = $false }
try { $Host.UI.RawUI.WindowTitle = "Kit de validação · piloto ODM M365" } catch { }

# =============================================================== visual
$LARG = 66
function Linha([string]$c = "─", [string]$cor = "DarkGray") { Write-Host ("  " + ($c * $LARG)) -ForegroundColor $cor }
function Banner {
    Clear-Host
    Write-Host ""
    Linha "═" "DarkCyan"
    Write-Host "   KIT DE VALIDAÇÃO  ·  PILOTO QUEST ODM M365" -ForegroundColor White
    Write-Host "   Conteúdo conhecido nas contas de teste, para conferir a migração" -ForegroundColor Gray
    Linha "═" "DarkCyan"
    Write-Host "   Use só em tenant de laboratório ou com aprovação do cliente." -ForegroundColor DarkYellow
    if ($script:Simular) {
        Write-Host ""
        Write-Host "   >>> MODO SIMULAÇÃO: nenhum login, nenhuma mudança <<<" -ForegroundColor Magenta
    }
}
function Sim([string]$t) { Write-Host "   [SIM ] $t" -ForegroundColor Magenta }
function Etapa([int]$n, [string]$texto, [int]$total = 6) {
    Write-Host ""
    Write-Host ("  {0}/{1}  {2}" -f $n, $total, $texto.ToUpper()) -ForegroundColor Cyan
    Linha
}
function Ok([string]$t)    { Write-Host "   [ OK ] $t" -ForegroundColor Green }
function Info([string]$t)  { Write-Host "   [ .. ] $t" -ForegroundColor Gray }
function Aviso([string]$t) { Write-Host "   [ !! ] $t" -ForegroundColor Yellow }
function Falha([string]$t) { Write-Host "   [ XX ] $t" -ForegroundColor Red }
function Campo([string]$rotulo, [string]$valor) {
    Write-Host ("   {0,-14}" -f $rotulo) -ForegroundColor DarkGray -NoNewline
    Write-Host $valor -ForegroundColor White
}
function Pergunta([string]$t) {
    Write-Host ""
    Write-Host "   $t " -ForegroundColor White -NoNewline
    return (Read-Host).Trim()
}
function Encerrar([string]$motivo) {
    Write-Host ""
    Aviso $motivo
    throw "ENCERRADO"
}

# =============================================================== Graph
function Graph {
    param([string]$Metodo, [string]$Uri, $Corpo, [string]$Tipo = "application/json", [int]$Tentativas = 6)
    for ($i = 1; $i -le $Tentativas; $i++) {
        try {
            if ($null -eq $Corpo) { return Invoke-MgGraphRequest -Method $Metodo -Uri $Uri }
            if ($Tipo -eq "application/json") { $Corpo = $Corpo | ConvertTo-Json -Depth 10 }
            return Invoke-MgGraphRequest -Method $Metodo -Uri $Uri -Body $Corpo -ContentType $Tipo
        } catch {
            if ($i -lt $Tentativas -and $_.Exception.Message -match "403|401|Forbidden|Unauthorized|429|503|ErrorAccessDenied") {
                Info "aguardando as permissões valerem ($i/$Tentativas)..."
                Start-Sleep -Seconds 20
            } else { throw }
        }
    }
}
function Todos([string]$Uri) {
    $itens = @(); $prox = $Uri
    while ($prox) { $r = Graph GET $prox; $itens += $r.value; $prox = $r.'@odata.nextLink' }
    return $itens
}

# =============================================================== validação
function Conectar-Exchange([string]$t, [string]$papel) {
    Info "login de ADMIN do Exchange Online do $papel ($t). Use 'Usar outra conta' se precisar."
    Connect-ExchangeOnline -ShowBanner:$false
    $inicial = (Get-AcceptedDomain | Where-Object InitialDomain).DomainName
    Campo "Organização" (Get-OrganizationConfig).DisplayName
    Campo "Tenant"      $inicial
    if ($inicial -ne $t) {
        Disconnect-ExchangeOnline -Confirm:$false | Out-Null
        Encerrar "Login no tenant errado: esperado $t, conectado em $inicial."
    }
}

function Pastas-Kit([string]$upn) {
    $st = Get-EXOMailboxStatistics -Identity $upn -ErrorAction Stop
    $fs = @(Get-MailboxFolderStatistics -Identity $upn -ErrorAction Stop)
    $soma = { param($f) if ($f) { [int](($f | Measure-Object ItemsInFolder -Sum).Sum) } else { $null } }
    [ordered]@{
        "Total da caixa"   = [int]$st.ItemCount
        "Caixa de Entrada" = & $soma ($fs | Where-Object FolderType -eq "Inbox")
        "Projeto Nexus"    = & $soma ($fs | Where-Object Name -eq "Projeto Nexus")
        "Calendário"       = & $soma ($fs | Where-Object FolderType -eq "Calendar")
        "Contatos"         = & $soma ($fs | Where-Object FolderType -eq "Contacts")
    }
}

function Invoke-Validacao {
    $T = 5
    # ---- 1. contas
    Etapa 1 "Escolher as contas" $T
    if (-not $TenantDestino) { $script:TenantDestino = Pergunta "Tenant de DESTINO (ex.: fabrikam.onmicrosoft.com):" }
    if ($Usuarios) {
        $prefixos = $Usuarios
    } elseif ($Simular) {
        $prefixos = "exemplo1", "exemplo2", "exemplo3"
    } else {
        $manifestos = @(Get-ChildItem $pastaBase -Filter "kit-validacao-*.csv" -ErrorAction SilentlyContinue)
        $lista = @($manifestos | ForEach-Object { Import-Csv $_.FullName } | ForEach-Object { $_.Usuario } | Sort-Object -Unique |
                   ForEach-Object { [pscustomobject]@{ Conta = $_.Split("@")[0]; Origem = $_ } })
        if ($lista) {
            Info "contas encontradas nos manifestos do kit. Selecione e clique em OK."
            $prefixos = ($lista | Out-GridView -Title "Validação: escolha as contas e clique em OK" -OutputMode Multiple).Conta
        } else {
            $prefixos = (Pergunta "Contas, separadas por vírgula (ex.: teste.nexus1,teste.nexus2):") -split "\s*,\s*"
        }
    }
    $prefixos = @($prefixos | Where-Object { $_ } | ForEach-Object { $_.Split("@")[0] })
    if (-not $prefixos) { Encerrar "Nenhuma conta escolhida." }
    foreach ($p in $prefixos) { Ok ("{0}@{1}  ->  {0}@{2}" -f $p, $Tenant, $TenantDestino) }
    Info "o par é montado pelo nome antes do @, que é igual nos dois tenants neste lab"

    $dados = @{}
    foreach ($p in $prefixos) { $dados[$p] = @{ Origem = $null; Destino = $null; OneDrive = $null; Obs = @() } }

    # ---- 2 e 3. Exchange Online na origem e no destino
    $lados = @(@{ N = 2; Nome = "origem";  Tenant = $Tenant;        Campo = "Origem"  },
               @{ N = 3; Nome = "destino"; Tenant = $TenantDestino; Campo = "Destino" })
    foreach ($l in $lados) {
        Etapa $l.N ("Ler as pastas no " + $l.Nome) $T
        if ($Simular) {
            Sim "abriria o login de admin do Exchange Online do $($l.Tenant)"
            foreach ($p in $prefixos) {
                $dados[$p][$l.Campo] = [ordered]@{ "Total da caixa" = 12; "Caixa de Entrada" = 4; "Projeto Nexus" = 1; "Calendário" = 1; "Contatos" = 1 }
                Sim "leria as pastas de $p@$($l.Tenant)"
            }
            continue
        }
        Conectar-Exchange $l.Tenant $l.Nome
        foreach ($p in $prefixos) {
            $upn = "$p@$($l.Tenant)"
            try   { $dados[$p][$l.Campo] = Pastas-Kit $upn; Ok "$upn" }
            catch { $dados[$p].Obs += "sem caixa no $($l.Nome)"; Aviso "$upn : caixa não encontrada" }
        }
        Disconnect-ExchangeOnline -Confirm:$false | Out-Null
    }

    # ---- 4. OneDrive do destino
    Etapa 4 "Conferir o OneDrive no destino" $T
    if ($Simular) {
        Sim "criaria um app temporário só de leitura (Files.Read.All) no $TenantDestino"
        foreach ($p in $prefixos) { $dados[$p].OneDrive = 2; Sim "procuraria os 2 arquivos do kit no OneDrive de $p" }
    } elseif ((Pergunta "Conferir também o OneDrive do destino? Pede mais um login de admin. (S/N):") -match "^[sS]") {
        Info "login de ADMIN do Microsoft Graph do destino ($TenantDestino)"
        Connect-MgGraph -TenantId $TenantDestino -NoWelcome -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"
        $graphSp = Graph GET "v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')"
        $roles   = $graphSp.appRoles | Where-Object { $_.value -in "Files.Read.All", "Application.ReadWrite.OwnedBy" -and $_.allowedMemberTypes -contains "Application" }
        $script:app = Graph POST "v1.0/applications" @{
            displayName            = "Kit-Validacao-ODM leitura (temporario, apagar se encontrar)"
            requiredResourceAccess = @(@{ resourceAppId = $graphSp.appId; resourceAccess = @($roles | ForEach-Object { @{ id = $_.id; type = "Role" } }) })
        }
        $sp = Graph POST "v1.0/servicePrincipals" @{ appId = $app.appId }
        foreach ($r in $roles) { Graph POST "v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" @{ principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $r.id } | Out-Null }
        Graph POST "v1.0/applications/$($app.id)/owners/`$ref" @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.id)" } | Out-Null
        $segredo = Graph POST "v1.0/applications/$($app.id)/addPassword" @{
            passwordCredential = @{ displayName = "kit"; endDateTime = (Get-Date).ToUniversalTime().AddHours(1).ToString("o") }
        }
        Disconnect-MgGraph | Out-Null
        Ok "app de leitura criado; esperando 60 s para as permissões valerem..."
        Start-Sleep -Seconds 60
        $cred = New-Object System.Management.Automation.PSCredential($app.appId, (ConvertTo-SecureString $segredo.secretText -AsPlainText -Force))
        Connect-MgGraph -TenantId $TenantDestino -ClientSecretCredential $cred -NoWelcome
        foreach ($p in $prefixos) {
            $upn = "$p@$TenantDestino"; $achados = 0
            foreach ($caminho in "Kit-Validacao.txt", "Projeto%20Nexus/Planilha.csv") {
                try { Graph GET "v1.0/users/$upn/drive/root:/$($caminho):?`$select=id" | Out-Null; $achados++ } catch { }
            }
            $dados[$p].OneDrive = $achados
            Ok "$upn : $achados de 2 arquivos"
        }
        try { Graph DELETE "v1.0/applications/$($app.id)" -Tentativas 2 | Out-Null; $script:app = $null; Ok "app de leitura apagado" }
        catch { Aviso "o app de leitura não conseguiu se apagar sozinho" }
        Disconnect-MgGraph | Out-Null
    } else {
        Info "pulado"
    }

    # ---- 5. resultado
    Etapa 5 "Resultado" $T
    $relatorio = @(); $ok = 0; $total = 0
    foreach ($p in $prefixos) {
        Write-Host ""
        Write-Host "   > $p" -ForegroundColor White
        Write-Host ("     {0,-18} {1,7} {2,8}   {3}" -f "Item", "Origem", "Destino", "Situação") -ForegroundColor DarkGray
        $o = $dados[$p].Origem; $d = $dados[$p].Destino
        $itens = @("Caixa de Entrada", "Projeto Nexus", "Calendário", "Contatos", "Total da caixa")
        foreach ($it in $itens) {
            $vo = if ($o) { $o[$it] } else { $null }
            $vd = if ($d) { $d[$it] } else { $null }
            if ($it -eq "Total da caixa") { $sit = "referência"; $cor = "DarkGray" }
            elseif ($null -eq $vo)        { $sit = "não existe na origem"; $cor = "DarkGray" }
            elseif ($null -eq $vd)        { $sit = "não existe no destino"; $cor = "Yellow"; $total++ }
            elseif ($vd -ge $vo)          { $sit = "OK"; $cor = "Green"; $ok++; $total++ }
            else                          { $sit = "faltam {0}" -f ($vo - $vd); $cor = "Yellow"; $total++ }
            $fmt = { param($v) if ($null -eq $v) { "-" } else { $v } }
            Write-Host ("     {0,-18} {1,7} {2,8}   {3}" -f $it, (& $fmt $vo), (& $fmt $vd), $sit) -ForegroundColor $cor
            $relatorio += [pscustomobject]@{ Conta = $p; Item = $it; Origem = $vo; Destino = $vd; Situacao = $sit }
        }
        if ($null -ne $dados[$p].OneDrive) {
            $vd = $dados[$p].OneDrive; $total++
            if ($vd -ge 2) { $sit = "OK"; $cor = "Green"; $ok++ } else { $sit = "faltam {0}" -f (2 - $vd); $cor = "Yellow" }
            Write-Host ("     {0,-18} {1,7} {2,8}   {3}" -f "OneDrive (kit)", 2, $vd, $sit) -ForegroundColor $cor
            $relatorio += [pscustomobject]@{ Conta = $p; Item = "OneDrive (kit)"; Origem = 2; Destino = $vd; Situacao = $sit }
        }
        foreach ($x in $dados[$p].Obs) { Aviso $x }
    }
    Write-Host ""
    Info "'Total da caixa' inclui itens de sistema e serve só de referência; a conferência é pelas pastas do kit."
    Info "Antes da migração é normal o destino aparecer vazio."

    $arq = if ($Simular) { "(não gerado na simulação)" } else {
        $f = Join-Path $pastaBase ("validacao-{0}-{1}.csv" -f $Tenant.Split(".")[0], $carimbo)
        $relatorio | Export-Csv $f -NoTypeInformation -Encoding UTF8; $f
    }
    Write-Host ""
    Linha "═" "DarkCyan"
    $cor = if ($total -gt 0 -and $ok -eq $total) { "Green" } else { "Yellow" }
    Write-Host ("   {0} DE {1} ITENS DO KIT CONFERIDOS NO DESTINO" -f $ok, $total) -ForegroundColor $cor
    if ($Simular) { Write-Host "   SIMULAÇÃO: nada foi lido nem alterado" -ForegroundColor Magenta }
    Campo "Relatório" $arq
    Campo "Log"       $arqLog
    Linha "═" "DarkCyan"
}

# =============================================================== início
$pastaBase = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$carimbo   = Get-Date -Format "yyyyMMdd-HHmmss"
$pastaLog  = Join-Path $pastaBase "logs"
New-Item -ItemType Directory -Path $pastaLog -Force | Out-Null
$arqLog    = Join-Path $pastaLog "kit-validacao-$carimbo.log"
Start-Transcript -Path $arqLog | Out-Null
$simParam = [bool]$Simular
$primeira = $true
$sair     = $false

do {
$app = $null
if (-not $primeira) { $Modo = $null; $Simular = $simParam }
$primeira = $false

try {
    Banner

    if (-not $Modo) {
        Write-Host ""
        Write-Host $(if ($Simular) { "   O que você quer simular?" } else { "   O que você quer fazer?" }) -ForegroundColor White
        Write-Host ""
        Write-Host "     [1]  Kit completo   " -ForegroundColor Cyan -NoNewline; Write-Host "e-mails, pasta, anexo, reunião, contato e OneDrive" -ForegroundColor Gray
        Write-Host "     [2]  Só OneDrive    " -ForegroundColor Cyan -NoNewline; Write-Host "quando os e-mails já foram criados antes" -ForegroundColor Gray
        Write-Host "     [4]  Validar        " -ForegroundColor Cyan -NoNewline; Write-Host "compara origem e destino: pastas do kit e OneDrive" -ForegroundColor Gray
        if (-not $Simular) { Write-Host "     [3]  Simular        " -ForegroundColor Magenta -NoNewline; Write-Host "mostra tudo o que seria feito, sem login e sem mudar nada" -ForegroundColor Gray }
        Write-Host "     [0]  Sair" -ForegroundColor Cyan
        switch (Pergunta "Opção:") {
            "1"     { $Modo = "Completo" }
            "2"     { $Modo = "SoOneDrive" }
            "3"     { $Modo = "Completo"; $Simular = $true; Banner }
            "4"     { $Modo = "Validar" }
            default { $sair = $true; Encerrar "Até a próxima." }
        }
    }
    if ($Simular -and ($Tenant -like "*__*" -or -not $Tenant)) { $Tenant = "contoso.onmicrosoft.com" }
    if ($Simular -and $TenantDestino -like "*__*") { $TenantDestino = "fabrikam.onmicrosoft.com" }
    if ($Tenant -like "*__*" -or -not $Tenant) {
        $Tenant = Pergunta "Tenant de ORIGEM (ex.: contoso.onmicrosoft.com):"
    }
    if ($TenantDestino -like "*__*") {
        $TenantDestino = Pergunta "Tenant de DESTINO (Enter para pular o OneDrive do destino):"
    }

    $modulos = if ($Modo -eq "Validar") { "Microsoft.Graph.Authentication", "ExchangeOnlineManagement" } else { "Microsoft.Graph.Authentication", "Microsoft.Online.SharePoint.PowerShell" }
    foreach ($m in $modulos) {
        if ($Simular) { break }
        if ($m -like "*SharePoint*" -and $SemProvisionar) { continue }
        if (-not (Get-Module -ListAvailable $m)) {
            Info "instalando o módulo $m (só na primeira vez)..."
            Install-Module $m -Scope CurrentUser -Force -AllowClobber
        }
    }
    if (-not $Simular) { Import-Module Microsoft.Graph.Authentication }
    if (-not $Simular -and $Modo -eq "Validar") { Import-Module ExchangeOnlineManagement }

    if ($Modo -eq "Validar") { Invoke-Validacao } else {

    # ----------------------------------------------------------- 1
    Etapa 1 "Conectar e confirmar o tenant"
    if ($Simular) {
        Sim "abriria o login de admin do $Tenant"
        $nomeOrg = "Contoso (simulação)"; $dominioInicial = $Tenant; $conta = "admin@$Tenant"
    } else {
        Info "abrindo o login. Use a conta de ADMIN do tenant de origem (clique em 'Usar outra conta' se precisar)."
        Connect-MgGraph -TenantId $Tenant -NoWelcome -Scopes `
            "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All", "User.Read.All", "Organization.Read.All"
        $org = (Graph GET "v1.0/organization?`$select=displayName,verifiedDomains").value[0]
        $nomeOrg = $org.displayName
        $dominioInicial = ($org.verifiedDomains | Where-Object { $_.isInitial }).name
        $conta = (Get-MgContext).Account
    }
    Write-Host ""
    Campo "Organização"  $nomeOrg
    Campo "Tenant"       $dominioInicial
    Campo "Conta"        $conta
    Campo "Modo"         $(if ($Modo -eq "Completo") { "Kit completo" } else { "Só OneDrive" })
    if ($TenantDestino) { Campo "Destino" $TenantDestino }
    if ((Pergunta "É esse o tenant certo? (S/N):") -notmatch "^[sS]") { Encerrar "Cancelado antes de qualquer mudança." }

    # ----------------------------------------------------------- 2
    Etapa 2 "Escolher as contas de teste"
    if ($CsvUsuarios) {
        $nomes = (Import-Csv $CsvUsuarios) | ForEach-Object { if ($_.UPN) { $_.UPN } else { $_.Usuario } }
    } elseif ($Usuarios) {
        $nomes = $Usuarios
    } else {
        if ($Simular) {
            $lista = 1..6 | ForEach-Object { [pscustomobject]@{
                Nome = "Usuário Exemplo $_"; UPN = "exemplo$_@$Tenant"; Licenciado = $(if ($_ -le 4) { "Sim" } else { "Não" }) } }
        } else {
            Info "carregando os usuários do tenant..."
            $lista = Todos "v1.0/users?`$select=displayName,userPrincipalName,assignedLicenses&`$top=999" |
                ForEach-Object { [pscustomobject]@{
                    Nome       = $_.displayName
                    UPN        = $_.userPrincipalName
                    Licenciado = $(if ($_.assignedLicenses.Count -gt 0) { "Sim" } else { "Não" })
                } } | Sort-Object Nome
        }
        Info "uma janela com a lista vai abrir. Selecione as contas (Ctrl + clique) e clique em OK."
        $nomes = ($lista | Out-GridView -Title "Kit de validação: escolha as contas de teste e clique em OK" -OutputMode Multiple).UPN
    }
    $upns = @($nomes | Where-Object { $_ } | ForEach-Object { if ($_ -like "*@*") { $_ } else { "$_@$Tenant" } })
    if (-not $upns) { Encerrar "Nenhuma conta escolhida. Nada foi feito." }
    $upns | ForEach-Object { Ok $_ }
    if ((Pergunta ("Criar o kit nessas {0} conta(s)? (S/N):" -f $upns.Count)) -notmatch "^[sS]") {
        Encerrar "Cancelado antes de qualquer mudança."
    }

    # ----------------------------------------------------------- 3
    Etapa 3 "Preparar o acesso (app temporário)"
    $perms = "Mail.ReadWrite", "Calendars.ReadWrite", "Contacts.ReadWrite", "Files.ReadWrite.All", "Application.ReadWrite.OwnedBy"
    if ($Simular) {
        Sim "criaria o app 'Kit-Validacao-ODM (temporario)' com segredo válido por 2 horas"
        Sim ("daria a ele: " + ($perms -join ", "))
    } else {
    $graphSp = Graph GET "v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')"
    $roles   = $graphSp.appRoles | Where-Object { $_.value -in $perms -and $_.allowedMemberTypes -contains "Application" }
    $app = Graph POST "v1.0/applications" @{
        displayName            = "Kit-Validacao-ODM (temporario, apagar se encontrar)"
        requiredResourceAccess = @(@{ resourceAppId = $graphSp.appId; resourceAccess = @($roles | ForEach-Object { @{ id = $_.id; type = "Role" } }) })
    }
    $sp = Graph POST "v1.0/servicePrincipals" @{ appId = $app.appId }
    foreach ($r in $roles) {
        Graph POST "v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" @{ principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $r.id } | Out-Null
    }
    # o próprio app vira dono do registro, para conseguir se apagar no final
    Graph POST "v1.0/applications/$($app.id)/owners/`$ref" @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.id)" } | Out-Null
    $segredo = Graph POST "v1.0/applications/$($app.id)/addPassword" @{
        passwordCredential = @{ displayName = "kit"; endDateTime = (Get-Date).ToUniversalTime().AddHours(2).ToString("o") }
    }
    $criadoEm = Get-Date
    Disconnect-MgGraph | Out-Null
    Ok "app criado, com segredo válido por 2 horas"
    Info ("permissões: " + ($perms -join ", "))
    }

    # ----------------------------------------------------------- 4
    Etapa 4 "Pedir os OneDrives (origem e destino)"
    if ($SemProvisionar) {
        Info "pulado (-SemProvisionar)"
    } elseif ($Simular) {
        foreach ($t in @($Tenant, $TenantDestino) | Where-Object { $_ }) { Sim "pediria os OneDrives das contas escolhidas no $t (login de admin do SharePoint)" }
    } else {
        Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking
        $prefixos = $upns | ForEach-Object { $_.Split("@")[0] }
        foreach ($t in @($Tenant, $TenantDestino) | Where-Object { $_ }) {
            Info "login de ADMIN do SharePoint de $t"
            Connect-SPOService -Url ("https://{0}-admin.sharepoint.com" -f $t.Split(".")[0])
            Request-SPOPersonalSite -UserEmails ($prefixos | ForEach-Object { "$_@$t" }) -NoWait
            Disconnect-SPOService
            Ok "pedido feito no $t"
        }
    }

    # ----------------------------------------------------------- 5
    Etapa 5 "Criar o conteúdo"
    if (-not $Simular) {
        $falta = 60 - [int]((Get-Date) - $criadoEm).TotalSeconds
        if ($falta -gt 0) { Info "esperando $falta s para as permissões do app valerem..."; Start-Sleep -Seconds $falta }
        $cred = New-Object System.Management.Automation.PSCredential($app.appId, (ConvertTo-SecureString $segredo.secretText -AsPlainText -Force))
        Connect-MgGraph -TenantId $Tenant -ClientSecretCredential $cred -NoWelcome
    }

    $fuso     = "E. South America Standard Time"
    $anexoB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Anexo de teste do kit de validacao. Se este texto chegou inteiro, o anexo migrou."))
    $manifesto = @()
    $n = 0

    foreach ($upn in $upns) {
        $n++
        Write-Progress -Activity "Criando o kit" -Status "$upn ($n de $($upns.Count))" -PercentComplete ((($n - 1) / $upns.Count) * 100)
        Write-Host ""
        Write-Host "   > $upn" -ForegroundColor White
        $item = [ordered]@{ Usuario = $upn; Emails = 0; Anexo = $false; Pasta = $false; Reuniao = $false; Contato = $false; OneDrive = 0; Observacao = "" }

        if ($Simular) {
            if ($Modo -eq "Completo") {
                Sim ("criaria {0} e-mails na Caixa de Entrada, um com anexo" -f ($QtdEmails + 1)); Start-Sleep -Milliseconds 250
                Sim "criaria a pasta Projeto Nexus com 1 e-mail";                                   Start-Sleep -Milliseconds 250
                Sim ("criaria uma reunião em {0:dd/MM} às 10:00" -f (Get-Date).Date.AddDays(7));      Start-Sleep -Milliseconds 250
                Sim "criaria um contato pessoal";                                                     Start-Sleep -Milliseconds 250
                $item.Emails = $QtdEmails + 2; $item.Anexo = $true; $item.Pasta = $true; $item.Reuniao = $true; $item.Contato = $true
            }
            Sim "gravaria 2 arquivos no OneDrive (raiz e pasta Projeto Nexus)"; Start-Sleep -Milliseconds 250
            $item.OneDrive = 2
            $manifesto += [pscustomobject]$item
            continue
        }

        if ($Modo -eq "Completo") {
            try { Graph GET "v1.0/users/$upn/mailFolders/inbox?`$select=id" | Out-Null }
            catch {
                $item.Observacao = "sem caixa de e-mail (sem licença ou licença recente)"
                Aviso $item.Observacao
                $manifesto += [pscustomobject]$item
                continue
            }

            function Novo-Email($pasta, $assunto, $texto, [switch]$ComAnexo) {
                $m = @{
                    subject      = $assunto
                    body         = @{ contentType = "Text"; content = $texto }
                    from         = @{ emailAddress = @{ address = "kit.validacao@$Tenant"; name = "Kit de validacao" } }
                    toRecipients = @(@{ emailAddress = @{ address = $upn } })
                    # PR_MESSAGE_FLAGS = 1: item recebido e lido (sem isso o Outlook trata como rascunho)
                    singleValueExtendedProperties = @(@{ id = "Integer 0x0E07"; value = "1" })
                }
                if ($ComAnexo) { $m.attachments = @(@{ "@odata.type" = "#microsoft.graph.fileAttachment"; name = "anexo-teste.txt"; contentBytes = $anexoB64 }) }
                Graph POST "v1.0/users/$upn/mailFolders/$pasta/messages" $m | Out-Null
            }

            1..$QtdEmails | ForEach-Object { Novo-Email "inbox" ("Teste migracao {0:D2}" -f $_) "E-mail $_ de $QtdEmails do kit de validacao."; $item.Emails++ }
            Novo-Email "inbox" "Teste migracao - com anexo" "Este e-mail tem um anexo de texto." -ComAnexo
            $item.Emails++; $item.Anexo = $true
            Ok ("{0} e-mails na Caixa de Entrada, um com anexo" -f $item.Emails)

            $pasta = @((Graph GET "v1.0/users/$upn/mailFolders?`$top=100").value | Where-Object { $_.displayName -eq "Projeto Nexus" })[0]
            if (-not $pasta) { $pasta = Graph POST "v1.0/users/$upn/mailFolders" @{ displayName = "Projeto Nexus" } }
            Novo-Email $pasta.id "Teste migracao - dentro da pasta" "Este e-mail fica na pasta Projeto Nexus."
            $item.Emails++; $item.Pasta = $true
            Ok "pasta Projeto Nexus com 1 e-mail"

            $inicio = (Get-Date).Date.AddDays(7).AddHours(10)
            Graph POST "v1.0/users/$upn/events" @{
                subject = "Reuniao de validacao da migracao"
                body    = @{ contentType = "Text"; content = "Evento do kit de validacao." }
                start   = @{ dateTime = $inicio.ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = $fuso }
                end     = @{ dateTime = $inicio.AddHours(1).ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = $fuso }
            } | Out-Null
            $item.Reuniao = $true
            Ok ("reunião em {0:dd/MM} às 10:00" -f $inicio)

            Graph POST "v1.0/users/$upn/contacts" @{
                givenName = "Contato"; surname = "Validacao"; companyName = "Fornecedor Teste"
                emailAddresses = @(@{ address = "contato.validacao@exemplo.com"; name = "Contato Validacao" })
            } | Out-Null
            $item.Contato = $true
            Ok "contato pessoal"
        }

        # OneDrive
        $limite = (Get-Date).AddMinutes($EsperaOneDriveMin); $pronto = $false
        while (-not $pronto -and (Get-Date) -lt $limite) {
            try { Graph GET "v1.0/users/$upn/drive?`$select=id" -Tentativas 1 | Out-Null; $pronto = $true }
            catch { Info "OneDrive ainda sendo criado, nova tentativa em 1 min..."; Start-Sleep -Seconds 60 }
        }
        if ($pronto) {
            try {
                Graph PUT "v1.0/users/$upn/drive/root:/Kit-Validacao.txt:/content" "Arquivo na raiz do OneDrive." "text/plain" | Out-Null
                $item.OneDrive++
                Graph PUT "v1.0/users/$upn/drive/root:/Projeto%20Nexus/Planilha.csv:/content" "Item;Quantidade`nTeste;1" "text/plain" | Out-Null
                $item.OneDrive++
                Ok "2 arquivos no OneDrive (raiz e pasta Projeto Nexus)"
            } catch { $item.Observacao = "erro no OneDrive: $($_.Exception.Message)"; Falha $item.Observacao }
        } else {
            $item.Observacao = "OneDrive não ficou pronto em $EsperaOneDriveMin min. Rode de novo com -Modo SoOneDrive -SemProvisionar."
            Aviso $item.Observacao
        }
        $manifesto += [pscustomobject]$item
    }
    Write-Progress -Activity "Criando o kit" -Completed

    # ----------------------------------------------------------- 6
    Etapa 6 "Resumo e limpeza"
    $sufixo  = if ($Modo -eq "SoOneDrive") { "-onedrive" } else { "" }
    $arqCsv  = Join-Path $pastaBase ("kit-validacao-{0}{1}-{2}.csv" -f $Tenant.Split(".")[0], $sufixo, $carimbo)
    if ($Simular) { $arqCsv = "(não gerado na simulação)" } else { $manifesto | Export-Csv $arqCsv -NoTypeInformation -Encoding UTF8 }

    Write-Host ""
    Write-Host ("   {0,-46} {1,7} {2,8} {3,8} {4,8}" -f "Conta", "E-mails", "Reunião", "Contato", "OneDrive") -ForegroundColor DarkGray
    foreach ($i in $manifesto) {
        $cor = if ($i.Observacao) { "Yellow" } else { "Green" }
        $sn  = { param($v) if ($v) { "sim" } else { "-" } }
        Write-Host ("   {0,-46} {1,7} {2,8} {3,8} {4,8}" -f $i.Usuario, $i.Emails, (& $sn $i.Reuniao), (& $sn $i.Contato), $i.OneDrive) -ForegroundColor $cor
        if ($i.Observacao) { Write-Host "      $($i.Observacao)" -ForegroundColor Yellow }
    }

    if ($Simular) { Write-Host ""; Sim "apagaria o app temporário" } else {
    try {
        Graph DELETE "v1.0/applications/$($app.id)" -Tentativas 2 | Out-Null
        $app = $null
        Write-Host ""
        Ok "app temporário apagado"
    } catch { Aviso "o app não conseguiu se apagar sozinho; vou pedir login de admin" }
    Disconnect-MgGraph | Out-Null

    if ($app) {
        Connect-MgGraph -TenantId $Tenant -Scopes "Application.ReadWrite.All" -NoWelcome
        Graph DELETE "v1.0/applications/$($app.id)" | Out-Null
        Disconnect-MgGraph | Out-Null
        $app = $null
        Ok "app temporário apagado"
    }
    }

    Write-Host ""
    Linha "═" "DarkCyan"
    if ($Simular) { Write-Host "   SIMULAÇÃO CONCLUÍDA: nada foi alterado" -ForegroundColor Magenta }
    else          { Write-Host "   PRONTO" -ForegroundColor Green }
    Campo "Manifesto" $arqCsv
    Campo "Log"       $arqLog
    Linha "═" "DarkCyan"
    }
}
catch {
    if ($_.Exception.Message -ne "ENCERRADO") {
        Write-Host ""
        Falha "erro: $($_.Exception.Message)"
        Info "detalhes completos no log: $arqLog"
    }
    if ($app) {
        Aviso "o app temporário '$($app.displayName)' pode ter ficado no tenant."
        Aviso "Apague em Entra ID > App registrations > All applications."
    }
}
finally {
    if (-not $Simular) {
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
        if ($Modo -eq "Validar") { try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { } }
    }
}

if ($sair) { break }
Write-Host ""
Write-Host "   [M] " -ForegroundColor Cyan -NoNewline; Write-Host "Voltar ao menu     " -ForegroundColor Gray -NoNewline
Write-Host "[Enter] " -ForegroundColor Cyan -NoNewline; Write-Host "Sair" -ForegroundColor Gray
$resposta = Pergunta "Opção:"
} while ($resposta -match "^[mM]")

try { Stop-Transcript | Out-Null } catch { }
