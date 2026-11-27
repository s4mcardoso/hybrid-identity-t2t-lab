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
    Valida a migração em 6 camadas (conta, caixa, pastas, itens do kit, amostra de e-mails
    e OneDrive) e gera um relatório HTML e um CSV. Só lê, não altera nada.

.EXAMPLE
    .\kit-validacao-odm.ps1 -Modo Validar -MapaCsv .\mapa.csv -Camadas Conta,Pastas,OneDrive
    Valida as contas de um mapa SourceUPN,TargetUPN (o mesmo formato do Map from File do ODM).

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
    [int]      $EsperaOneDriveMin = 40,
    # Validação: camadas a conferir (padrão: escolher no menu)
    [ValidateSet("Conta", "Caixa", "Pastas", "Itens", "Amostra", "OneDrive")]
    [string[]] $Camadas,
    # Validação: CSV SourceUPN,TargetUPN quando os UPNs mudam entre os tenants
    [string]   $MapaCsv,
    # Validação: quantos e-mails reais por conta procurar no destino
    [ValidateRange(0, 500)]
    [int]      $Amostra = 25,
    # Validação: limite de arquivos por OneDrive no inventário
    [ValidateRange(10, 200000)]
    [int]      $MaxArquivos = 5000
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
$DESC_CAMADAS = [ordered]@{
    "Conta"    = "conta e licença nos dois tenants: os pré-requisitos para migrar"
    "Caixa"    = "propriedades da caixa: tipo, tamanho, arquivo morto, retenção, encaminhamento, X500 e permissões"
    "Pastas"   = "todas as pastas da caixa, com quantidade de itens e tamanho"
    "Itens"    = "itens do kit um a um: e-mails, anexo com hash, pasta de origem, reunião e contato"
    "Amostra"  = "e-mails reais da origem (fora do kit) procurados no destino pelo Message-ID"
    "OneDrive" = "inventário do OneDrive arquivo por arquivo, com hash de integridade"
}
$ROTULO_CAMADA = @{ Conta = "Conta"; Caixa = "Caixa"; Pastas = "Pastas"; Itens = "Itens do kit"; Amostra = "Amostra"; OneDrive = "OneDrive" }
$IGNORAR_PASTA = '^(Root|RecoverableItems\w*|Audits|CalendarLogging|SyncIssues|Conflicts|LocalFailures|ServerFailures|RecipientCache|PersonMetadata|ConversationActions|SearchFolders|Files|GraphFiles|QuickContacts|ImContactList|OrganizationalContacts|MyContactsExtended|ExternalContacts|SubstrateHolds|DiscoveryHolds|Versions|Purges|Deletions|DeferredAction|RssSubscription|TeamsMessagesData|SwssItems|BirthdayCalendar|Yammer\w*|Social\w*|CommunicatorHistory|ScheduledActions|SharePointNotifications|FreeBusyData|ProtectedFolder\w*)$'
$PASTA_SINAL   = '^(User Created|Inbox|SentItems|Calendar|Contacts|Tasks|Notes|Drafts|Archive)$'
$EXT_OFFICE    = '\.(docx|docm|xlsx|xlsm|pptx|pptm|dotx|xltx|potx|vsdx)$'
$NIVEIS        = @("Falha", "Atenção", "Pendente", "OK", "Info")

# ---------------------------------------------------------------- utilitários
function Bytes($s) {
    if ($null -eq $s) { return $null }
    $m = [regex]::Match([string]$s, '\(([\d,\.\s]+) bytes\)')
    if ($m.Success) { return [int64]($m.Groups[1].Value -replace '[^\d]', '') }
    return $null
}
function Tam($b) {
    if ($null -eq $b -or "$b" -eq "") { return "-" }
    $b = [double]$b
    if ($b -ge 1GB) { return "{0:N2} GB" -f ($b / 1GB) }
    if ($b -ge 1MB) { return "{0:N1} MB" -f ($b / 1MB) }
    if ($b -ge 1KB) { return "{0:N0} KB" -f ($b / 1KB) }
    return "{0} B" -f $b
}
function Pct($a, $b) {
    if ($null -eq $a -or $null -eq $b -or [double]$b -eq 0) { return "-" }
    return "{0:N0}% da origem" -f ([double]$a / [double]$b * 100)
}
function Prefixo([string]$u) { if ($u) { return $u.Split("@")[0].Trim().ToLower() } else { return "" } }
function Url([string]$v) { return [uri]::EscapeDataString($v) }
function SN($v) { if ($null -eq $v) { "-" } elseif ($v) { "Sim" } else { "Não" } }
function Curto([string]$s, [int]$n) {
    if (-not $s) { return "(sem assunto)" }
    if ($s.Length -le $n) { return $s }
    return $s.Substring(0, $n - 3) + "..."
}
function Sha([byte[]]$b) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($h.ComputeHash($b)) -replace '-', '').Substring(0, 16) } finally { $h.Dispose() }
}
function ParaData($v) {
    if ($null -eq $v -or "$v" -eq "") { return $null }
    if ($v -is [datetime]) { if ($v.Kind -eq "Local") { return $v.ToUniversalTime() } return $v }
    $estilo = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    try { return [datetime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, $estilo) } catch { return $null }
}
function Dt($v) { if ($v) { return $v.ToString("dd/MM/yyyy HH:mm") + " UTC" } else { return "-" } }
function Perto($a, $b) {
    if (-not $a -or -not $b) { return $false }
    return ([math]::Abs(($a - $b).TotalMinutes) -le 2)
}
function Soma($lista) { $s = ($lista | Measure-Object Bytes -Sum).Sum; if ($s) { return [int64]$s } else { return [int64]0 } }
function Esc([string]$s) { return [System.Net.WebUtility]::HtmlEncode($s) }

# Registra uma conferência.
#   -Dados : depende da migração ter acontecido (vira "Pendente" antes dela)
#   -Sinal : prova forte de que algo migrou (usado para descobrir a fase)
#   -Prereq: pré-requisito para migrar
function Reg($conta, $camada, $item, $origem, $destino, $nivel, $sit, [string]$detalhe = "", [switch]$Dados, [switch]$Sinal, [switch]$Prereq) {
    $script:ordemVal++
    $script:linhasVal.Add([pscustomobject]@{
        Conta = $conta; Camada = $camada; Item = [string]$item; Origem = [string]$origem; Destino = [string]$destino
        Nivel = $nivel; Situacao = $sit; Detalhe = $detalhe
        Dados = [bool]$Dados; Sinal = [bool]$Sinal; Prereq = [bool]$Prereq; Ordem = $script:ordemVal
    })
}
function Contagem($ls) {
    $h = @{ "OK" = 0; "Atenção" = 0; "Falha" = 0; "Pendente" = 0; "Info" = 0 }
    foreach ($l in $ls) { $h[$l.Nivel]++ }
    return $h
}
function Placar($h) {
    $t = $h["OK"] + $h["Atenção"] + $h["Falha"] + $h["Pendente"]
    if ($t -eq 0) { return "só informativo" }
    $s = "{0}/{1} OK" -f $h["OK"], $t
    if ($h["Falha"])    { $s += " · {0} falha(s)" -f $h["Falha"] }
    if ($h["Atenção"])  { $s += " · {0} atenção" -f $h["Atenção"] }
    if ($h["Pendente"]) { $s += " · {0} pendente(s)" -f $h["Pendente"] }
    return $s
}
function Cor-Placar($h) {
    if ($h["Falha"]) { "Red" } elseif ($h["Atenção"]) { "Yellow" } elseif ($h["Pendente"]) { "DarkCyan" } elseif ($h["OK"]) { "Green" } else { "DarkGray" }
}
function Cor-Fase([string]$f) {
    switch ($f) { "Migrado" { "Green" } "Migrado com avisos" { "Green" } "Migração parcial" { "Yellow" } "Antes da migração" { "Cyan" } default { "Gray" } }
}
function Classe([string]$n) {
    switch ($n) { "OK" { "ok" } "Atenção" { "at" } "Falha" { "fa" } "Pendente" { "pe" } default { "in" } }
}

# ---------------------------------------------------------------- contas e camadas
function Par([string]$o, [string]$d, [string]$fonte) {
    [pscustomobject]@{ Nome = (Prefixo $o); Origem = $o.Trim(); Destino = $d.Trim(); Fonte = $fonte }
}
function Escolher-Pares {
    if ($MapaCsv) {
        return @(Import-Csv $MapaCsv | Where-Object { $_.SourceUPN -and $_.TargetUPN } | ForEach-Object { Par $_.SourceUPN $_.TargetUPN "mapa" })
    }
    if ($Usuarios) {
        return @($Usuarios | ForEach-Object { $x = Prefixo $_; Par "$x@$Tenant" "$x@$TenantDestino" "parâmetro" })
    }
    if ($Simular) {
        return @(1..3 | ForEach-Object { Par "exemplo$_@$Tenant" "exemplo$_@$TenantDestino" "simulação" })
    }
    $lista = @{}
    foreach ($m in @(Get-ChildItem $pastaBase -Filter "kit-validacao-*.csv" -ErrorAction SilentlyContinue)) {
        foreach ($l in @(Import-Csv $m.FullName)) {
            if ($l.Usuario -and $l.Usuario -like "*@$Tenant") {
                $x = Prefixo $l.Usuario
                $lista[$l.Usuario.ToLower()] = Par $l.Usuario "$x@$TenantDestino" "manifesto do kit"
            }
        }
    }
    foreach ($m in @(Get-ChildItem $pastaBase -Filter "*.csv" -ErrorAction SilentlyContinue)) {
        $cab = [string](Get-Content $m.FullName -TotalCount 1)
        if ($cab -match 'SourceUPN' -and $cab -match 'TargetUPN') {
            foreach ($l in @(Import-Csv $m.FullName)) {
                if ($l.SourceUPN -and $l.TargetUPN) { $lista[$l.SourceUPN.ToLower()] = Par $l.SourceUPN $l.TargetUPN $m.Name }
            }
        }
    }
    if ($lista.Count) {
        Info "uma janela vai abrir com as contas dos manifestos do kit e dos mapas (SourceUPN,TargetUPN) desta pasta."
        Info "Selecione as contas (Ctrl + clique) e clique em OK."
        $sel = @($lista.Values | Sort-Object Origem | Select-Object Origem, Destino, Fonte |
                 Out-GridView -Title "Validação: escolha as contas e clique em OK" -OutputMode Multiple)
        return @($sel | ForEach-Object { Par $_.Origem $_.Destino $_.Fonte })
    }
    $r = Pergunta "Contas (ex.: teste.nexus1,teste.nexus2) ou caminho de um CSV SourceUPN,TargetUPN:"
    if ($r -match '\.csv$' -and (Test-Path $r)) {
        return @(Import-Csv $r | Where-Object { $_.SourceUPN -and $_.TargetUPN } | ForEach-Object { Par $_.SourceUPN $_.TargetUPN "mapa" })
    }
    return @($r -split "\s*,\s*" | Where-Object { $_ } | ForEach-Object { $x = Prefixo $_; Par "$x@$Tenant" "$x@$TenantDestino" "digitado" })
}
function Escolher-Camadas {
    $todas = @($DESC_CAMADAS.Keys)
    if ($Camadas) { return @($todas | Where-Object { $_ -in $Camadas }) }
    if ($Simular) { return $todas }
    Write-Host ""
    Write-Host "   Que validação você quer?" -ForegroundColor White
    Write-Host ""
    Write-Host "     [1]  Completa       " -ForegroundColor Cyan -NoNewline; Write-Host "as 6 camadas; 4 logins (Graph e Exchange em cada tenant)" -ForegroundColor Gray
    Write-Host "     [2]  Rápida         " -ForegroundColor Cyan -NoNewline; Write-Host "caixa e pastas pelo Exchange Online; 2 logins" -ForegroundColor Gray
    Write-Host "     [3]  Personalizada  " -ForegroundColor Cyan -NoNewline; Write-Host "escolher as camadas numa lista" -ForegroundColor Gray
    switch (Pergunta "Opção:") {
        "2" { return @("Caixa", "Pastas") }
        "3" {
            $sel = @($todas | ForEach-Object { [pscustomobject]@{ Camada = $_; "O que confere" = $DESC_CAMADAS[$_] } } |
                     Out-GridView -Title "Escolha as camadas e clique em OK" -OutputMode Multiple)
            if (-not $sel) { Encerrar "Nenhuma camada escolhida." }
            return @($sel | ForEach-Object { $_.Camada })
        }
        default { return $todas }
    }
}

# ---------------------------------------------------------------- acesso
function Tentar-Login([string]$nome, [scriptblock]$acao) {
    while ($true) {
        try { & $acao; return }
        catch {
            Aviso "o login do $nome não foi concluído: $($_.Exception.Message)"
            Info "a janela de login às vezes abre atrás das outras janelas: confira com Alt+Tab."
            if ((Pergunta "Tentar o login de novo? (S/N):") -notmatch "^[sS]") { throw }
        }
    }
}
function Limpar-AppsEsquecidos {
    # roda com o login de admin: procura apps temporários que ficaram de execuções interrompidas
    $velhos = @()
    try { $velhos = @((Graph GET ("v1.0/applications?`$filter=" + (Url "startswith(displayName,'Kit-Validacao-ODM')") + "&`$select=id,displayName,createdDateTime") -Tentativas 2).value) } catch { return }
    if (-not $velhos.Count) { return }
    Write-Host ""
    Aviso ("encontrei {0} app(s) temporário(s) de execuções anteriores que ficaram no tenant:" -f $velhos.Count)
    foreach ($v in $velhos) { Write-Host ("        {0}  (criado em {1})" -f $v.displayName, (Dt (ParaData $v.createdDateTime))) -ForegroundColor Yellow }
    Info "se outra pessoa estiver rodando o kit neste tenant agora, responda N."
    if ((Pergunta "Apagar esses apps? (S/N):") -match "^[sS]") {
        foreach ($v in $velhos) {
            try { Graph DELETE "v1.0/applications/$($v.id)" -Tentativas 2 | Out-Null; Ok "apagado: $($v.displayName)" }
            catch { Aviso "não consegui apagar $($v.displayName): $($_.Exception.Message)" }
        }
    }
}
function Conectar-Exchange([string]$t, [string]$papel) {
    Info "login de ADMIN do Exchange Online do $papel ($t). Use 'Usar outra conta' se precisar."
    Tentar-Login "Exchange Online" { Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop }
    $inicial = (Get-AcceptedDomain | Where-Object InitialDomain).DomainName
    Campo "Organização" (Get-OrganizationConfig).DisplayName
    Campo "Tenant"      $inicial
    if ($inicial -ne $t) {
        Disconnect-ExchangeOnline -Confirm:$false | Out-Null
        Encerrar "Login no tenant errado: esperado $t, conectado em $inicial."
    }
}
function Criar-AppLeitura([string]$t, [string]$papel, $camadas) {
    $perms = @("User.Read.All", "Application.ReadWrite.OwnedBy")
    if ("Conta" -in $camadas)                            { $perms += "Organization.Read.All", "MailboxSettings.Read", "Files.Read.All" }
    if ("Itens" -in $camadas)                            { $perms += "Mail.Read", "Calendars.Read", "Contacts.Read" }
    if ("Amostra" -in $camadas)                          { $perms += "Mail.Read" }
    if ("OneDrive" -in $camadas)                         { $perms += "Files.Read.All" }
    $perms = @($perms | Select-Object -Unique)

    Info "login de ADMIN do Microsoft Graph do $papel ($t). Use 'Usar outra conta' se precisar."
    Tentar-Login "Microsoft Graph" { Connect-MgGraph -TenantId $t -NoWelcome -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All", "Organization.Read.All" -ErrorAction Stop }
    $org = (Graph GET "v1.0/organization?`$select=displayName,verifiedDomains").value[0]
    $inicial = ($org.verifiedDomains | Where-Object { $_.isInitial }).name
    Campo "Organização" $org.displayName
    Campo "Tenant"      $inicial
    Campo "Conta"       (Get-MgContext).Account
    if ($inicial -ne $t) {
        Disconnect-MgGraph | Out-Null
        Encerrar "Login no tenant errado: esperado $t, conectado em $inicial."
    }
    Limpar-AppsEsquecidos
    $graphSp = Graph GET "v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')"
    $roles   = $graphSp.appRoles | Where-Object { $_.value -in $perms -and $_.allowedMemberTypes -contains "Application" }
    $app = Graph POST "v1.0/applications" @{
        displayName            = "Kit-Validacao-ODM leitura (temporario, apagar se encontrar)"
        requiredResourceAccess = @(@{ resourceAppId = $graphSp.appId; resourceAccess = @($roles | ForEach-Object { @{ id = $_.id; type = "Role" } }) })
    }
    $script:appsVal += @{ Tenant = $t; Id = $app.id; Nome = $app.displayName }
    $sp = Graph POST "v1.0/servicePrincipals" @{ appId = $app.appId }
    foreach ($r in $roles) { Graph POST "v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" @{ principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $r.id } | Out-Null }
    Graph POST "v1.0/applications/$($app.id)/owners/`$ref" @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.id)" } | Out-Null
    $segredo = Graph POST "v1.0/applications/$($app.id)/addPassword" @{
        passwordCredential = @{ displayName = "kit"; endDateTime = (Get-Date).ToUniversalTime().AddHours(2).ToString("o") }
    }
    Disconnect-MgGraph | Out-Null
    Ok "app só de leitura criado (segredo válido por 2 horas)"
    Info ("permissões: " + ($perms -join ", "))
    return @{
        App    = $app
        Criado = Get-Date
        Cred   = New-Object System.Management.Automation.PSCredential($app.appId, (ConvertTo-SecureString $segredo.secretText -AsPlainText -Force))
    }
}
function Apagar-AppLeitura($info) {
    try {
        Graph DELETE "v1.0/applications/$($info.App.id)" -Tentativas 2 | Out-Null
        $script:appsVal = @($script:appsVal | Where-Object { $_.Id -ne $info.App.id })
        Ok "app de leitura apagado"
    } catch { Aviso "o app de leitura não conseguiu se apagar sozinho" }
    Disconnect-MgGraph | Out-Null
}

# ---------------------------------------------------------------- leitura: Exchange Online
function Chaves-Pastas($fs) {
    # pastas conhecidas mudam de nome conforme o idioma da caixa ("Inbox" ou "Caixa de Entrada"),
    # então a chave usa o tipo da pasta no lugar do nome
    $raiz = @{}
    foreach ($f in $fs) {
        $partes = @($f.FolderPath.Trim("/").Split("/"))
        if ($partes.Count -eq 1 -and $f.FolderType -and $f.FolderType -ne "User Created") { $raiz[$partes[0]] = "[" + $f.FolderType + "]" }
    }
    foreach ($f in $fs) {
        if (-not $f.FolderPath -or $f.FolderPath -eq "/" -or $f.FolderPath -like "/Recoverable Items*" -or [string]$f.FolderType -match $IGNORAR_PASTA) { continue }
        $partes = @($f.FolderPath.Trim("/").Split("/"))
        if ($raiz.ContainsKey($partes[0])) { $partes[0] = $raiz[$partes[0]] }
        [pscustomobject]@{
            Chave   = ($partes -join "/").ToLower()
            Caminho = $f.FolderPath
            Tipo    = [string]$f.FolderType
            Itens   = [int]$f.ItemsInFolder
            Bytes   = Bytes $f.FolderSize
        }
    }
}
function Ler-Exchange($pares, [string]$lado, $camadas) {
    $i = 0
    foreach ($p in $pares) {
        $i++
        $upn = $p.$lado
        $d = $script:dados[$p.Nome][$lado]
        Write-Progress -Activity "Lendo o $($lado.ToLower()) pelo Exchange Online" -Status "$upn ($i de $($pares.Count))" -PercentComplete ((($i - 1) / $pares.Count) * 100)
        try { $mbx = Get-EXOMailbox -Identity $upn -PropertySets All -ErrorAction Stop }
        catch { $d.Caixa = @{ Existe = $false }; Aviso "$upn : caixa não encontrada"; continue }
        $st = Get-EXOMailboxStatistics -Identity $upn -ErrorAction Stop
        $fs = @(Get-MailboxFolderStatistics -Identity $upn -ErrorAction Stop)
        if ("Pastas" -in $camadas) { $d.Pastas = @(Chaves-Pastas $fs) }
        if ("Caixa" -in $camadas) {
            $temArquivo = [bool]([string]$mbx.ArchiveGuid -and [string]$mbx.ArchiveGuid -notmatch '^0{8}-0{4}')
            $arq = $null
            if ($temArquivo) { try { $arq = Get-EXOMailboxStatistics -Identity $upn -Archive -ErrorAction Stop } catch { } }
            $cal = @($fs | Where-Object FolderType -eq "Calendar")[0]
            $calPerm = @()
            if ($cal) {
                $idCal = "{0}:{1}" -f $upn, ($cal.FolderPath -replace '/', '\')
                $calPerm = @(Get-EXOMailboxFolderPermission -Identity $idCal -ErrorAction SilentlyContinue |
                             ForEach-Object { "{0}={1}" -f (Prefixo ([string]$_.User)), ($_.AccessRights -join ",") })
            }
            $reg = $null
            try { $reg = Get-MailboxRegionalConfiguration -Identity $upn -ErrorAction Stop } catch { }
            $enc = if ($mbx.ForwardingSmtpAddress) { [string]$mbx.ForwardingSmtpAddress } elseif ($mbx.ForwardingAddress) { [string]$mbx.ForwardingAddress } else { "" }
            $perm = @(Get-EXOMailboxPermission -Identity $upn -ErrorAction SilentlyContinue |
                      Where-Object { -not $_.IsInherited -and [string]$_.User -notmatch '^NT AUTHORITY|^S-1-|DiscoverySearchMailbox' } |
                      ForEach-Object { "{0} ({1})" -f (Prefixo ([string]$_.User)), ($_.AccessRights -join ",") })
            $sendAs = @(Get-EXORecipientPermission -Identity $upn -ErrorAction SilentlyContinue |
                        Where-Object { [string]$_.Trustee -notmatch '^NT AUTHORITY|^S-1-' } |
                        ForEach-Object { Prefixo ([string]$_.Trustee) })
            $d.Caixa = @{
                Existe    = $true
                Tipo      = [string]$mbx.RecipientTypeDetails
                Smtp      = [string]$mbx.PrimarySmtpAddress
                LegacyDN  = [string]$mbx.LegacyExchangeDN
                X500      = @($mbx.EmailAddresses | Where-Object { $_ -like "x500:*" } | ForEach-Object { ([string]$_).Substring(5) })
                Arquivo   = $temArquivo
                ArqItens  = $(if ($arq) { [int]$arq.ItemCount } else { $null })
                ArqBytes  = $(if ($arq) { Bytes $arq.TotalItemSize } else { $null })
                Hold      = [bool]$mbx.LitigationHoldEnabled
                Encaminha = ($enc -replace '^smtp:', '')
                Idioma    = $(if ($reg -and $reg.Language) { [string]$reg.Language } else { "não configurado" })
                Fuso      = $(if ($reg -and $reg.TimeZone) { [string]$reg.TimeZone } else { "não configurado" })
                Itens     = [int]$st.ItemCount
                Bytes     = Bytes $st.TotalItemSize
                Excluidos = [int]$st.DeletedItemCount
                Perm      = $perm
                SendAs    = $sendAs
                CalPerm   = $calPerm
            }
        }
        Ok ("{0} : {1} itens em {2} pastas" -f $upn, $st.ItemCount, $fs.Count)
    }
    Write-Progress -Activity "Lendo o $($lado.ToLower()) pelo Exchange Online" -Completed
}

# ---------------------------------------------------------------- leitura: Microsoft Graph
function Item-Kit([string]$tipo, [string]$chave) {
    [pscustomobject]@{ Tipo = $tipo; Chave = $chave; Pasta = ""; Rascunho = $false; Anexos = 0; AnexoHash = ""; Data = $null; Fim = $null; Email = "" }
}
function Nome-Pasta([string]$upn, [string]$id, $cache) {
    if (-not $cache.ContainsKey($id)) {
        try { $cache[$id] = (Graph GET "v1.0/users/$upn/mailFolders/$($id)?`$select=displayName" -Tentativas 2).displayName } catch { $cache[$id] = "?" }
    }
    return $cache[$id]
}
function Procurar-Email([string]$upn, $s) {
    $sel = "&`$select=subject,hasAttachments,receivedDateTime&`$top=5"
    $achado = @()
    try { $achado = @((Graph GET ("v1.0/users/$upn/messages?`$filter=" + (Url ("internetMessageId eq '" + $s.Id.Replace("'", "''") + "'")) + $sel) -Tentativas 2).value) } catch { }
    $como = "Message-ID"
    if (-not $achado -and $s.Data) {
        $ini = $s.Data.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $fim = $s.Data.AddMinutes(1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        try {
            $achado = @((Graph GET ("v1.0/users/$upn/messages?`$filter=" + (Url "receivedDateTime ge $ini and receivedDateTime le $fim") + $sel) -Tentativas 2).value |
                        Where-Object { $_.subject -eq $s.Assunto })
        } catch { }
        $como = "data e assunto"
    }
    if ($achado) {
        $a = $achado[0]
        return [pscustomobject]@{ Id = $s.Id; Achado = $true; Como = $como; Copias = $achado.Count; Anexo = [bool]$a.hasAttachments; Data = ParaData $a.receivedDateTime }
    }
    return [pscustomobject]@{ Id = $s.Id; Achado = $false; Como = ""; Copias = 0; Anexo = $false; Data = $null }
}
function Inventario-Drive([string]$upn, $drv) {
    $arqs   = New-Object System.Collections.Generic.List[object]
    $pastas = New-Object System.Collections.Generic.List[string]
    $fila   = New-Object System.Collections.Queue
    $fila.Enqueue(@("root", ""))
    $truncado = $false
    while ($fila.Count -gt 0) {
        $atual = $fila.Dequeue()
        $base = if ($atual[0] -eq "root") { "v1.0/users/$upn/drive/root/children" } else { "v1.0/users/$upn/drive/items/$($atual[0])/children" }
        foreach ($f in (Todos ($base + "?`$select=id,name,size,file,folder,fileSystemInfo,shared&`$top=999"))) {
            $caminho = if ($atual[1]) { $atual[1] + "/" + $f.name } else { $f.name }
            if ($f.folder) { $pastas.Add($caminho); $fila.Enqueue(@($f.id, $caminho)) }
            elseif ($f.file) {
                if ($arqs.Count -ge $MaxArquivos) { $truncado = $true; break }
                $hash = ""
                if ($f.file.hashes) { $hash = [string]$f.file.hashes.quickXorHash }
                $mod = $null
                if ($f.fileSystemInfo) { $mod = ParaData $f.fileSystemInfo.lastModifiedDateTime }
                $arqs.Add([pscustomobject]@{ Caminho = $caminho; Bytes = [int64]$f.size; Hash = $hash; Modificado = $mod; Compartilhado = [bool]$f.shared })
            }
        }
        if ($truncado) { break }
    }
    $usado = $null
    if ($drv.quota) { $usado = [int64]$drv.quota.used }
    return [pscustomobject]@{ Usado = $usado; Arquivos = $arqs; Pastas = $pastas; Truncado = $truncado }
}
function Ler-Graph($pares, [string]$lado, $camadas) {
    $skus = @{}
    if ("Conta" -in $camadas) {
        try { foreach ($s in (Graph GET "v1.0/subscribedSkus?`$select=skuId,skuPartNumber" -Tentativas 3).value) { $skus[[string]$s.skuId] = $s.skuPartNumber } } catch { }
    }
    $i = 0
    foreach ($p in $pares) {
        $i++
        $upn = $p.$lado
        $d = $script:dados[$p.Nome][$lado]
        Write-Progress -Activity "Lendo o $($lado.ToLower()) pelo Microsoft Graph" -Status "$upn ($i de $($pares.Count))" -PercentComplete ((($i - 1) / $pares.Count) * 100)

        # conta e licença
        if ("Conta" -in $camadas) {
            try {
                $u = Graph GET ("v1.0/users/{0}?`$select=displayName,accountEnabled,usageLocation,assignedLicenses,assignedPlans,onPremisesSyncEnabled,onPremisesImmutableId" -f $upn) -Tentativas 2
                $planos = @($u.assignedPlans | Where-Object { $_.capabilityStatus -eq "Enabled" })
                $d.Conta = @{
                    Existe       = $true
                    Habilitada   = [bool]$u.accountEnabled
                    Usage        = [string]$u.usageLocation
                    Licencas     = (@($u.assignedLicenses | ForEach-Object { $k = [string]$_.skuId; if ($skus.ContainsKey($k)) { $skus[$k] } else { $k } }) -join ", ")
                    Exchange     = [bool](@($planos | Where-Object { $_.service -eq "exchange" }).Count)
                    SharePoint   = [bool](@($planos | Where-Object { $_.service -eq "SharePoint" }).Count)
                    Sincronizada = [bool]$u.onPremisesSyncEnabled
                    ImmutableId  = [string]$u.onPremisesImmutableId
                }
            } catch { $d.Conta = @{ Existe = $false } }
            try { Graph GET "v1.0/users/$upn/mailboxSettings" -Tentativas 2 | Out-Null; $d.CaixaGraph = $true } catch { $d.CaixaGraph = $false }
        }

        $inbox = $null
        if ("Itens" -in $camadas -or "Amostra" -in $camadas) {
            try { $inbox = Graph GET "v1.0/users/$upn/mailFolders/inbox?`$select=id" -Tentativas 2 } catch { }
        }

        # itens do kit
        if ("Itens" -in $camadas -and $inbox) {
            $kit = New-Object System.Collections.Generic.List[object]
            $cache = @{}
            $cache[$inbox.id] = "Caixa de Entrada"
            $f = Url "startswith(subject,'Teste migracao')"
            foreach ($m in (Todos "v1.0/users/$upn/messages?`$filter=$f&`$select=id,subject,parentFolderId,isDraft,hasAttachments,receivedDateTime&`$top=100")) {
                $it = Item-Kit "E-mail" $m.subject
                $it.Pasta    = Nome-Pasta $upn $m.parentFolderId $cache
                $it.Rascunho = [bool]$m.isDraft
                $it.Data     = ParaData $m.receivedDateTime
                if ($m.hasAttachments) {
                    $ax = @((Graph GET "v1.0/users/$upn/messages/$($m.id)/attachments" -Tentativas 2).value)
                    $it.Anexos = $ax.Count
                    $it.AnexoHash = (@($ax | ForEach-Object {
                        if ($_.contentBytes) { "{0} ({1})" -f $_.name, (Sha ([Convert]::FromBase64String($_.contentBytes))) } else { $_.name }
                    }) -join "; ")
                }
                $kit.Add($it)
            }
            $f = Url "subject eq 'Reuniao de validacao da migracao'"
            foreach ($e in (Todos "v1.0/users/$upn/events?`$filter=$f&`$select=subject,start,end&`$top=50")) {
                $it = Item-Kit "Reunião" $e.subject
                $it.Pasta = "Calendário"; $it.Data = ParaData $e.start.dateTime; $it.Fim = ParaData $e.end.dateTime
                $kit.Add($it)
            }
            $f = Url "surname eq 'Validacao'"
            foreach ($c in (Todos "v1.0/users/$upn/contacts?`$filter=$f&`$select=displayName,companyName,emailAddresses&`$top=50")) {
                $it = Item-Kit "Contato" $c.displayName
                $it.Pasta = "Contatos"; $it.Email = (@($c.emailAddresses | ForEach-Object { $_.address }) -join ", ")
                $kit.Add($it)
            }
            $d.Kit = $kit
        }

        # amostra de e-mails reais
        if ("Amostra" -in $camadas -and $Amostra -gt 0 -and $inbox) {
            if ($lado -eq "Origem") {
                $r = (Graph GET "v1.0/users/$upn/messages?`$top=$Amostra&`$orderby=receivedDateTime%20desc&`$select=internetMessageId,subject,hasAttachments,receivedDateTime,isDraft" -Tentativas 2).value
                $d.Amostra = @($r | Where-Object { -not $_.isDraft -and $_.internetMessageId -and $_.subject -notlike "Teste migracao*" } | ForEach-Object {
                    [pscustomobject]@{ Id = $_.internetMessageId; Assunto = [string]$_.subject; Anexo = [bool]$_.hasAttachments; Data = ParaData $_.receivedDateTime } })
            } else {
                $lista = @($script:dados[$p.Nome]["Origem"].Amostra | Where-Object { $_ })
                $d.Amostra = @(foreach ($s in $lista) { Procurar-Email $upn $s })
            }
        }

        # OneDrive
        if ("OneDrive" -in $camadas -or "Conta" -in $camadas) {
            $drv = $null
            try { $drv = Graph GET "v1.0/users/$upn/drive?`$select=id,quota" -Tentativas 2 } catch { }
            $d.OneDriveExiste = [bool]$drv
            if ($drv -and "OneDrive" -in $camadas) {
                Info "$upn : inventariando o OneDrive..."
                $d.OneDrive = Inventario-Drive $upn $drv
            }
        }

        $resumo = @()
        if ($d.Conta)                { $resumo += $(if ($d.Conta.Existe) { "conta encontrada" } else { "conta não existe" }) }
        if ("Itens" -in $camadas)    { $resumo += $(if ($null -ne $d.Kit) { "{0} itens do kit" -f $d.Kit.Count } else { "sem caixa" }) }
        if ($null -ne $d.Amostra) {
            if ($lado -eq "Origem") { $resumo += "{0} e-mails na amostra" -f @($d.Amostra).Count }
            else { $resumo += "{0} de {1} e-mails da amostra achados" -f @($d.Amostra | Where-Object { $_.Achado }).Count, @($d.Amostra).Count }
        }
        if ($d.OneDrive)             { $resumo += "{0} arquivos no OneDrive" -f $d.OneDrive.Arquivos.Count }
        elseif ("OneDrive" -in $camadas) { $resumo += "sem OneDrive" }
        Ok ("{0} : {1}" -f $upn, ($resumo -join ", "))
    }
    Write-Progress -Activity "Lendo o $($lado.ToLower()) pelo Microsoft Graph" -Completed
}

# ---------------------------------------------------------------- leitura: simulação
function Dados-Simulados($p, [string]$lado) {
    $pref = $p.Nome
    $t = if ($lado -eq "Origem") { $Tenant } else { $TenantDestino }
    $v = "origem"
    if ($lado -eq "Destino") { $v = switch ($pref) { "exemplo1" { "completo" } "exemplo2" { "parcial" } default { "vazio" } } }
    $d = $script:dados[$pref][$lado]
    $base = (Get-Date).ToUniversalTime().Date.AddDays(-3).AddHours(13)
    $dnOrigem = "/o=ExchangeLabs/ou=Exchange Administrative Group (FYDIBOHF23SPDLT)/cn=Recipients/cn=a1b2c3d4-$pref"
    $vazio = $v -eq "vazio"; $parcial = $v -eq "parcial"

    $d.Conta = @{ Existe = $true; Habilitada = ($lado -eq "Origem"); Usage = "BR"; Licencas = "SPE_E5"
                  Exchange = $true; SharePoint = (-not $vazio); Sincronizada = ($lado -eq "Origem"); ImmutableId = $(if ($v -eq "parcial") { "" } else { "mT3x9Qk$pref==" }) }
    $d.CaixaGraph = $true
    $d.OneDriveExiste = (-not $vazio)

    $pasta = { param($ch, $cam, $tipo, $n, $b) [pscustomobject]@{ Chave = $ch; Caminho = $cam; Tipo = $tipo; Itens = $n; Bytes = $b } }
    $d.Pastas = @(
        & $pasta "[inbox]"       "/Caixa de Entrada" "Inbox"        $(if ($vazio) { 0 } elseif ($parcial) { 3 } else { 4 }) $(if ($vazio) { 0 } else { 41200 })
        & $pasta "[sentitems]"   "/Itens Enviados"   "SentItems"    $(if ($vazio) { 0 } else { 2 }) $(if ($vazio) { 0 } else { 18400 })
        & $pasta "[calendar]"    "/Calendário"       "Calendar"     $(if ($vazio) { 0 } else { 1 }) $(if ($vazio) { 0 } else { 6100 })
        & $pasta "[contacts]"    "/Contatos"         "Contacts"     $(if ($vazio -or $parcial) { 0 } else { 1 }) $(if ($vazio -or $parcial) { 0 } else { 2900 })
    )
    if (-not $vazio) { $d.Pastas += & $pasta "projeto nexus" "/Projeto Nexus" "User Created" 1 9800 }

    $d.Caixa = @{
        Existe = $true; Tipo = "UserMailbox"; Smtp = "$pref@$t"
        LegacyDN = $(if ($lado -eq "Origem") { $dnOrigem } else { "/o=ExchangeLabs/ou=Exchange Administrative Group (FYDIBOHF23SPDLT)/cn=Recipients/cn=e5f6a7b8-$pref" })
        X500 = $(if ($v -eq "completo") { @($dnOrigem) } else { @() })
        Arquivo = $false; ArqItens = $null; ArqBytes = $null; Hold = $false
        Encaminha = $(if ($lado -eq "Origem" -and $pref -eq "exemplo1") { "$pref@$TenantDestino" } else { "" })
        Idioma = "pt-BR"; Fuso = "E. South America Standard Time"
        Itens = $(if ($vazio) { 0 } elseif ($parcial) { 9 } else { 12 }); Bytes = $(if ($vazio) { 0 } elseif ($parcial) { 251000 } else { 328000 }); Excluidos = 0
        Perm = $(if ($v -in "origem", "completo") { @("exemplo2 (FullAccess)") } else { @() })
        SendAs = @()
        CalPerm = @("default=AvailabilityOnly", "anonymous=None")
    }

    $kit = New-Object System.Collections.Generic.List[object]
    if (-not $vazio) {
        foreach ($k in 1..3) {
            if ($parcial -and $k -eq 3) { continue }
            $it = Item-Kit "E-mail" ("Teste migracao {0:D2}" -f $k); $it.Pasta = "Caixa de Entrada"; $it.Data = $base.AddMinutes($k); $kit.Add($it)
        }
        $it = Item-Kit "E-mail" "Teste migracao - com anexo"; $it.Pasta = "Caixa de Entrada"; $it.Data = $base.AddMinutes(4)
        $it.Anexos = 1; $it.AnexoHash = "anexo-teste.txt (9F2C41A07B3E55D1)"; $kit.Add($it)
        $it = Item-Kit "E-mail" "Teste migracao - dentro da pasta"; $it.Pasta = "Projeto Nexus"; $it.Data = $base.AddMinutes(5); $kit.Add($it)
        $it = Item-Kit "Reunião" "Reuniao de validacao da migracao"; $it.Pasta = "Calendário"
        $it.Data = $base.Date.AddDays(10).AddHours(13); $it.Fim = $it.Data.AddHours(1); $kit.Add($it)
        if (-not $parcial) { $it = Item-Kit "Contato" "Contato Validacao"; $it.Pasta = "Contatos"; $it.Email = "contato.validacao@exemplo.com"; $kit.Add($it) }
    }
    $d.Kit = $kit

    if ($lado -eq "Origem") {
        $assuntos = "Proposta comercial revisada", "Ata da reunião de kickoff", "Teste migracao - com anexo", "Teste migracao 01", "Fatura de novembro", "Agenda da próxima semana"
        $j = 0
        $d.Amostra = @($assuntos | ForEach-Object { $j++
            [pscustomobject]@{ Id = "<sim-$pref-$j@contoso.prod.outlook.com>"; Assunto = $_; Anexo = ($j -eq 3); Data = $base.AddHours(-$j) } })
    } else {
        $j = 0
        $d.Amostra = @($script:dados[$pref]["Origem"].Amostra | ForEach-Object { $j++
            $achou = -not $vazio -and -not ($parcial -and $j -eq 5)
            $como = if ($parcial -and $j -eq 2) { "data e assunto" } else { "Message-ID" }
            [pscustomobject]@{ Id = $_.Id; Achado = $achou; Como = $(if ($achou) { $como } else { "" }); Copias = $(if ($achou) { 1 } else { 0 }); Anexo = $_.Anexo; Data = $(if ($achou) { $_.Data } else { $null }) } })
    }

    if ($vazio) { $d.OneDrive = $null } else {
        $arq = { param($c, $b, $h) [pscustomobject]@{ Caminho = $c; Bytes = $b; Hash = $h; Modificado = $base.AddDays(-20); Compartilhado = ($c -like "Documentos/*") } }
        $arqs = New-Object System.Collections.Generic.List[object]
        $arqs.Add((& $arq "Kit-Validacao.txt" 28 "q8XoA1"))
        $arqs.Add((& $arq "Projeto Nexus/Planilha.csv" 20 "b7RtZ2"))
        $arqs.Add((& $arq "Documentos/Proposta.docx" 48211 $(if ($parcial) { "zz91Kp" } else { "c3MmW9" })))
        if (-not $parcial) { $arqs.Add((& $arq "Fotos/evento.jpg" 1250331 "d4LpQ0")) }
        $pastas = New-Object System.Collections.Generic.List[string]
        "Projeto Nexus", "Documentos", "Fotos" | ForEach-Object { $pastas.Add($_) }
        if (-not $parcial) { $pastas.Add("Arquivo antigo") }
        $d.OneDrive = [pscustomobject]@{ Usado = (Soma $arqs); Arquivos = $arqs; Pastas = $pastas; Truncado = $false }
    }
}

function Ler-Lado([string]$lado, [string]$t, $pares, $camadas) {
    $querGraph = [bool](@($camadas | Where-Object { $_ -in "Conta", "Itens", "Amostra", "OneDrive" }).Count)
    $querExo   = [bool](@($camadas | Where-Object { $_ -in "Caixa", "Pastas" }).Count)
    $papel = $lado.ToLower()
    if ($Simular) {
        if ($querGraph) { Sim "abriria o login de admin do Microsoft Graph do $t e criaria um app só de leitura" }
        if ($querExo)   { Sim "abriria o login de admin do Exchange Online do $t" }
        foreach ($p in $pares) { Dados-Simulados $p $lado; Sim ("leria " + $p.$lado); Start-Sleep -Milliseconds 200 }
        if ($querGraph) { Sim "apagaria o app de leitura" }
        return
    }
    $info = $null
    if ($querGraph) { $info = Criar-AppLeitura $t $papel $camadas }
    if ($querExo) {
        Conectar-Exchange $t $papel
        Ler-Exchange $pares $lado $camadas
        Disconnect-ExchangeOnline -Confirm:$false | Out-Null
    }
    if ($info) {
        $falta = 60 - [int]((Get-Date) - $info.Criado).TotalSeconds
        if ($falta -gt 0) { Info "esperando $falta s para as permissões do app valerem..."; Start-Sleep -Seconds $falta }
        Connect-MgGraph -TenantId $t -ClientSecretCredential $info.Cred -NoWelcome
        Graph GET "v1.0/users?`$top=1&`$select=id" | Out-Null
        Ler-Graph $pares $lado $camadas
        Apagar-AppLeitura $info
    }
}

# ---------------------------------------------------------------- comparação
function Desc-Kit($x) {
    switch ($x.Tipo) {
        "E-mail"  { $t = $x.Pasta; if ($x.Anexos) { $t += " · {0} anexo(s)" -f $x.Anexos }; return $t }
        "Reunião" { return (Dt $x.Data) }
        default   { if ($x.Email) { return $x.Email } else { return "-" } }
    }
}
function Comparar-Lista($n, $cam, $item, $lo, $ld, [string]$explica) {
    $lo = @($lo | Where-Object { $_ }); $ld = @($ld | Where-Object { $_ })
    $txtD = if ($ld.Count) { $ld -join "; " } else { "nenhuma" }
    if (-not $lo.Count) { Reg $n $cam $item "nenhuma" $txtD "Info" "nada para migrar"; return }
    $faltam = @($lo | Where-Object { $ld -notcontains $_ })
    if (-not $faltam.Count) { Reg $n $cam $item ($lo -join "; ") $txtD "OK" "todas presentes no destino" -Dados }
    else { Reg $n $cam $item ($lo -join "; ") $txtD "Atenção" ("faltam: " + ($faltam -join "; ") + ". " + $explica) -Dados }
}

function Comparar($p) {
    $n = $p.Nome
    $o = $script:dados[$n]["Origem"]; $d = $script:dados[$n]["Destino"]
    $c = $script:camadasVal

    # ---- Conta
    if ("Conta" -in $c) {
        $cam = "Conta"; $oc = $o.Conta; $dc = $d.Conta
        if (-not $oc.Existe) { Reg $n $cam "Conta na origem" "não existe" "-" "Falha" "conta não encontrada na origem: confira o UPN" }
        elseif (-not $o.CaixaGraph) { Reg $n $cam "Caixa na origem" "não existe" "-" "Atenção" "sem caixa na origem não há e-mail para migrar" }
        if (-not $dc.Existe) {
            Reg $n $cam "Conta no destino" "-" "não existe" "Falha" "crie ou sincronize a conta no destino antes de migrar" -Prereq
        } else {
            Reg $n $cam "Conta no destino" "-" "existe" "OK" "encontrada" -Prereq
            if ($dc.Exchange) { Reg $n $cam "Exchange Online na licença" (SN $oc.Exchange) "Sim" "OK" "a caixa do destino pode existir" -Prereq }
            else { Reg $n $cam "Exchange Online na licença" (SN $oc.Exchange) "Não" "Falha" "sem Exchange Online não existe caixa no destino e a migração de e-mail falha" -Prereq }
            if ($dc.SharePoint) { Reg $n $cam "SharePoint na licença" (SN $oc.SharePoint) "Sim" "OK" "o OneDrive do destino pode existir" -Prereq }
            else { Reg $n $cam "SharePoint na licença" (SN $oc.SharePoint) "Não" "Falha" "sem SharePoint Online não existe OneDrive para receber os arquivos" -Prereq }
            if ($dc.Usage) { Reg $n $cam "Local de uso (usage location)" $oc.Usage $dc.Usage "OK" "definido" -Prereq }
            else { Reg $n $cam "Local de uso (usage location)" $oc.Usage "vazio" "Falha" "sem usage location a licença não pode ser atribuída" -Prereq }
            if ($d.CaixaGraph) { Reg $n $cam "Caixa criada no destino" (SN $o.CaixaGraph) "Sim" "OK" "pronta para receber e-mail" -Prereq }
            else { Reg $n $cam "Caixa criada no destino" (SN $o.CaixaGraph) "Não" "Falha" "a caixa ainda não existe; se a licença é recente, espere alguns minutos" -Prereq }
            if ($d.OneDriveExiste) { Reg $n $cam "OneDrive criado no destino" (SN $o.OneDriveExiste) "Sim" "OK" "pronto para receber arquivos" -Prereq }
            else { Reg $n $cam "OneDrive criado no destino" (SN $o.OneDriveExiste) "Não" "Atenção" "crie com a opção [2] do kit ou com Request-SPOPersonalSite" -Prereq }
            Reg $n $cam "Conta habilitada" (SN $oc.Habilitada) (SN $dc.Habilitada) "Info" $(if (-not $dc.Habilitada) { "no destino é comum ficar desabilitada até o corte" } else { "-" })
            Reg $n $cam "Licenças" $oc.Licencas $dc.Licencas "Info" "-"
            Reg $n $cam "Sincronizada do AD local" (SN $oc.Sincronizada) (SN $dc.Sincronizada) "Info" "-"
            $imm = if ($oc.ImmutableId -and $oc.ImmutableId -eq $dc.ImmutableId) { "iguais: o Match do ODM pode usar o immutableId" }
                   else { "diferentes ou vazios: use outro atributo no Match ou o Map from File" }
            Reg $n $cam "ImmutableId" $(if ($oc.ImmutableId) { $oc.ImmutableId } else { "vazio" }) $(if ($dc.ImmutableId) { $dc.ImmutableId } else { "vazio" }) "Info" $imm
        }
    }

    # ---- Caixa
    if ("Caixa" -in $c) {
        $cam = "Caixa"; $ob = $o.Caixa; $db = $d.Caixa
        if (-not $ob.Existe -or -not $db.Existe) {
            Reg $n $cam "Caixa de correio" $(if ($ob.Existe) { "existe" } else { "não existe" }) $(if ($db.Existe) { "existe" } else { "não existe" }) "Falha" "sem caixa nos dois lados não dá para comparar" -Prereq:(-not $db.Existe)
        } else {
            $nt = if ($db.Tipo -eq $ob.Tipo) { "OK" } else { "Atenção" }
            Reg $n $cam "Tipo da caixa" $ob.Tipo $db.Tipo $nt $(if ($nt -eq "OK") { "mesmo tipo" } else { "tipos diferentes: confira a licença e o tipo no destino" })
            Reg $n $cam "Itens na caixa" $ob.Itens $db.Itens "Info" ((Pct $db.Itens $ob.Itens) + "; inclui itens de sistema, vale como referência")
            Reg $n $cam "Tamanho da caixa" (Tam $ob.Bytes) (Tam $db.Bytes) "Info" (Pct $db.Bytes $ob.Bytes)
            Reg $n $cam "Itens excluídos" $ob.Excluidos $db.Excluidos "Info" "-"
            if ($ob.Arquivo) {
                if ($db.Arquivo) {
                    Reg $n $cam "Arquivo morto" "ativo" "ativo" "OK" "habilitado nos dois lados"
                    if ($null -ne $ob.ArqItens) {
                        $na = if ($db.ArqItens -ge $ob.ArqItens) { "OK" } else { "Falha" }
                        Reg $n $cam "Itens do arquivo morto" ("{0} · {1}" -f $ob.ArqItens, (Tam $ob.ArqBytes)) ("{0} · {1}" -f $db.ArqItens, (Tam $db.ArqBytes)) $na (Pct $db.ArqItens $ob.ArqItens) -Dados -Sinal
                    }
                } else { Reg $n $cam "Arquivo morto" "ativo" "inativo" "Atenção" "habilite o arquivo morto no destino antes de migrar o arquivo" }
            } else { Reg $n $cam "Arquivo morto" "inativo" $(if ($db.Arquivo) { "ativo" } else { "inativo" }) "Info" "não usado na origem" }
            if ($ob.Hold -and -not $db.Hold) { Reg $n $cam "Retenção (litigation hold)" "Sim" "Não" "Atenção" "a retenção não migra junto: aplique no destino se o cliente exigir" }
            else { Reg $n $cam "Retenção (litigation hold)" (SN $ob.Hold) (SN $db.Hold) "Info" "-" }
            $enc = $ob.Encaminha
            if ($enc -and ((Prefixo $enc) -eq (Prefixo $p.Destino) -or $enc -eq $db.Smtp -or $enc -like "*@$TenantDestino")) {
                Reg $n $cam "Encaminhamento da origem" $enc "-" "OK" "a origem encaminha para o destino: a troca de caixa (Switch) foi feita"
            } elseif ($enc) { Reg $n $cam "Encaminhamento da origem" $enc "-" "Info" "a origem encaminha para outro endereço" }
            else { Reg $n $cam "Encaminhamento da origem" "nenhum" "-" "Info" "a troca de caixa (Switch) ainda não foi feita" }
            if ($db.Encaminha) { Reg $n $cam "Encaminhamento do destino" "-" $db.Encaminha "Atenção" "o destino encaminha e-mail: confira se não é o caminho inverso" }
            if ($ob.LegacyDN) {
                if ($db.X500 -contains $ob.LegacyDN) { Reg $n $cam "X500 da origem no destino" "LegacyExchangeDN" "presente" "OK" "respostas a e-mails e reuniões antigas chegam no destino" $ob.LegacyDN -Dados }
                else { Reg $n $cam "X500 da origem no destino" "LegacyExchangeDN" "ausente" "Atenção" "sem esse X500, responder e-mails e reuniões antigas pode voltar com NDR (IMCEAEX)" $ob.LegacyDN -Dados }
            }
            Comparar-Lista $n $cam "Acesso total (FullAccess)" $ob.Perm $db.Perm "Recrie no destino ou use a migração de permissões."
            Comparar-Lista $n $cam "Enviar como (SendAs)" $ob.SendAs $db.SendAs "Recrie no destino."
            Comparar-Lista $n $cam "Permissões do calendário" $ob.CalPerm $db.CalPerm "Confira a delegação de calendário."
            $idi = if ($ob.Idioma -ne $db.Idioma) { "idiomas diferentes: os nomes das pastas mudam, por isso a comparação de pastas usa o tipo da pasta" }
                   elseif ($db.Idioma -eq "não configurado") { "a caixa ainda não foi aberta no Outlook; as pastas ficam em inglês até o primeiro acesso" } else { "-" }
            Reg $n $cam "Idioma e fuso" ("{0} · {1}" -f $ob.Idioma, $ob.Fuso) ("{0} · {1}" -f $db.Idioma, $db.Fuso) "Info" $idi
        }
    }

    # ---- Pastas
    if ("Pastas" -in $c) {
        $cam = "Pastas"
        if ($null -eq $o.Pastas -or $null -eq $d.Pastas) {
            Reg $n $cam "Pastas" $(if ($null -eq $o.Pastas) { "sem caixa" } else { "lidas" }) $(if ($null -eq $d.Pastas) { "sem caixa" } else { "lidas" }) "Falha" "não foi possível ler as pastas dos dois lados" -Dados
        } else {
            $mapaD = @{}; foreach ($f in $d.Pastas) { $mapaD[$f.Chave] = $f }
            $chavesO = @{}; $somaO = 0; $somaD = 0
            foreach ($f in ($o.Pastas | Sort-Object Caminho)) {
                $chavesO[$f.Chave] = $true
                $criada = $f.Tipo -eq "User Created"
                if ($f.Itens -eq 0 -and -not $criada) { continue }
                $sinal = $f.Tipo -match $PASTA_SINAL
                $g = $mapaD[$f.Chave]
                $somaO += $f.Itens
                $txtO = "{0} itens · {1}" -f $f.Itens, (Tam $f.Bytes)
                if (-not $g) { Reg $n $cam $f.Caminho $txtO "não existe" "Falha" "pasta não existe no destino" -Dados -Sinal:$sinal; continue }
                $somaD += $g.Itens
                $txtD = "{0} itens · {1}" -f $g.Itens, (Tam $g.Bytes)
                if ($g.Itens -ge $f.Itens) {
                    $s = if ($g.Itens -gt $f.Itens) { "OK; o destino tem {0} a mais (itens que já existiam ou duplicados)" -f ($g.Itens - $f.Itens) } else { "mesma quantidade" }
                    Reg $n $cam $f.Caminho $txtO $txtD "OK" $s -Dados -Sinal:$sinal
                } else {
                    Reg $n $cam $f.Caminho $txtO $txtD "Falha" ("faltam {0} ({1})" -f ($f.Itens - $g.Itens), (Pct $g.Itens $f.Itens)) -Dados -Sinal:$sinal
                }
            }
            foreach ($g in @($d.Pastas | Where-Object { -not $chavesO.ContainsKey($_.Chave) -and $_.Itens -gt 0 })) {
                Reg $n $cam $g.Caminho "não existe" ("{0} itens · {1}" -f $g.Itens, (Tam $g.Bytes)) "Info" "só no destino"
            }
            Reg $n $cam "Total nas pastas comparadas" $somaO $somaD "Info" (Pct $somaD $somaO)
        }
    }

    # ---- Itens do kit
    if ("Itens" -in $c) {
        $cam = "Itens do kit"
        if ($null -eq $o.Kit) { Reg $n $cam "Kit" "sem caixa" "-" "Falha" "não foi possível ler a caixa da origem" }
        elseif (-not $o.Kit.Count) { Reg $n $cam "Kit" "não encontrado" "-" "Info" "rode a opção [1] do kit na origem para ter itens conhecidos" }
        else {
            $gd = @{}
            if ($d.Kit) { foreach ($x in $d.Kit) { $k = $x.Tipo + "|" + $x.Chave; if (-not $gd.ContainsKey($k)) { $gd[$k] = @() }; $gd[$k] += $x } }
            foreach ($grupo in ($o.Kit | Group-Object { $_.Tipo + "|" + $_.Chave } | Sort-Object Name)) {
                $a = $grupo.Group[0]; $qo = $grupo.Count
                $lista = if ($gd.ContainsKey($grupo.Name)) { @($gd[$grupo.Name]) } else { @() }
                $rot = "{0}: {1}" -f $a.Tipo, $a.Chave
                if (-not $lista.Count) {
                    $s = if ($null -eq $d.Kit) { "sem caixa no destino" } else { "não chegou no destino" }
                    Reg $n $cam $rot (Desc-Kit $a) "não existe" "Falha" $s -Dados -Sinal; continue
                }
                $b = $lista[0]; $prob = @(); $grave = $false
                if ($a.Pasta -and $b.Pasta -ne $a.Pasta) { $prob += "está em '$($b.Pasta)', na origem estava em '$($a.Pasta)'" }
                if ($b.Rascunho -and -not $a.Rascunho) { $prob += "chegou como rascunho"; $grave = $true }
                if ($a.Anexos -ne $b.Anexos) { $prob += "anexos: $($a.Anexos) na origem, $($b.Anexos) no destino"; $grave = $true }
                elseif ($a.AnexoHash -ne $b.AnexoHash) { $prob += "conteúdo do anexo diferente (hash)"; $grave = $true }
                if ($a.Data -and -not (Perto $a.Data $b.Data)) { $prob += "data mudou para $(Dt $b.Data)"; if ($a.Tipo -eq "Reunião") { $grave = $true } }
                if ($a.Fim -and -not (Perto $a.Fim $b.Fim)) { $prob += "fim mudou para $(Dt $b.Fim)"; $grave = $true }
                if ($a.Email -ne $b.Email) { $prob += "e-mail do contato diferente" }
                if ($lista.Count -gt $qo) { $prob += "duplicado no destino ({0} cópias)" -f $lista.Count }
                elseif ($lista.Count -lt $qo) { $prob += "faltam {0} cópia(s)" -f ($qo - $lista.Count) }
                if (-not $prob.Count) {
                    $s = if ($a.AnexoHash) { "chegou igual; anexo conferido por hash" } else { "chegou igual" }
                    Reg $n $cam $rot (Desc-Kit $a) (Desc-Kit $b) "OK" $s $a.AnexoHash -Dados -Sinal
                } else {
                    Reg $n $cam $rot (Desc-Kit $a) (Desc-Kit $b) $(if ($grave) { "Falha" } else { "Atenção" }) ($prob -join "; ") $a.AnexoHash -Dados -Sinal
                }
            }
        }
    }

    # ---- Amostra
    if ("Amostra" -in $c -and $Amostra -gt 0) {
        $cam = "Amostra"
        if ($null -eq $o.Amostra) { Reg $n $cam "Amostra" "sem caixa" "-" "Falha" "não foi possível ler a caixa da origem" }
        elseif (-not @($o.Amostra).Count) { Reg $n $cam "Amostra" "vazia" "-" "Info" "a origem não tem e-mails" }
        else {
            $res = @{}; foreach ($x in @($d.Amostra)) { if ($x) { $res[$x.Id] = $x } }
            foreach ($s in $o.Amostra) {
                $rot = "{0} · {1}" -f (Curto $s.Assunto 55), (Dt $s.Data)
                $x = $res[$s.Id]
                if (-not $x -or -not $x.Achado) {
                    Reg $n $cam $rot "existe" "não achado" "Falha" "não achado nem pelo Message-ID nem por data e assunto" ("Message-ID: " + $s.Id) -Dados -Sinal; continue
                }
                $prob = @()
                if ($x.Anexo -ne $s.Anexo) { $prob += "anexo diferente" }
                if (-not (Perto $s.Data $x.Data)) { $prob += "data de recebimento mudou" }
                if ($x.Copias -gt 1) { $prob += "duplicado no destino ({0} cópias)" -f $x.Copias }
                if (-not $prob.Count) { Reg $n $cam $rot "existe" "achado" "OK" ("achado pelo " + $x.Como) ("Message-ID: " + $s.Id) -Dados -Sinal }
                else { Reg $n $cam $rot "existe" "achado" "Atenção" ($prob -join "; ") ("Message-ID: " + $s.Id) -Dados -Sinal }
            }
        }
    }

    # ---- OneDrive
    if ("OneDrive" -in $c) {
        $cam = "OneDrive"; $oo = $o.OneDrive; $dd = $d.OneDrive
        if (-not $oo) {
            Reg $n $cam "OneDrive" $(if ($o.OneDriveExiste) { "não lido" } else { "não existe" }) $(if ($d.OneDriveExiste) { "existe" } else { "-" }) "Info" "nada para migrar"
        } elseif (-not $dd) {
            Reg $n $cam "OneDrive" ("{0} arquivos" -f $oo.Arquivos.Count) "não existe" "Falha" "o OneDrive do destino não foi criado: use a opção [2] do kit ou Request-SPOPersonalSite" -Dados
        } else {
            $comArq = @{}
            foreach ($f in $oo.Arquivos) { $partes = $f.Caminho.Split("/"); for ($k = 1; $k -lt $partes.Count; $k++) { $comArq[($partes[0..($k - 1)] -join "/").ToLower()] = $true } }
            $mapaD = @{}; foreach ($f in $dd.Arquivos) { $mapaD[$f.Caminho.ToLower()] = $f }
            $vistos = @{}
            foreach ($f in ($oo.Arquivos | Sort-Object Caminho)) {
                $k = $f.Caminho.ToLower(); $vistos[$k] = $true
                $g = $mapaD[$k]
                if (-not $g) { Reg $n $cam $f.Caminho (Tam $f.Bytes) "não existe" "Falha" "arquivo não chegou" -Dados -Sinal; continue }
                $niv = "OK"
                if ($f.Hash -and $g.Hash -and $f.Hash -eq $g.Hash) { $s = "conteúdo idêntico (hash)" }
                elseif ($f.Caminho -match $EXT_OFFICE) { $niv = "Atenção"; $s = "conteúdo diferente; comum em arquivos do Office, porque o SharePoint grava metadados dentro do arquivo. Abra e confira" }
                elseif (-not $f.Hash -or -not $g.Hash) {
                    if ($f.Bytes -eq $g.Bytes) { $s = "mesmo tamanho (sem hash para comparar)" } else { $niv = "Falha"; $s = "tamanho diferente" }
                } else { $niv = "Falha"; $s = "conteúdo diferente (hash)" }
                if ($f.Modificado -and -not (Perto $f.Modificado $g.Modificado)) { if ($niv -eq "OK") { $niv = "Atenção" }; $s += "; data de modificação não preservada" }
                if ($f.Compartilhado -and -not $g.Compartilhado) { if ($niv -eq "OK") { $niv = "Atenção" }; $s += "; o compartilhamento não migrou" }
                Reg $n $cam $f.Caminho (Tam $f.Bytes) (Tam $g.Bytes) $niv $s ("hash origem {0} · destino {1}" -f $f.Hash, $g.Hash) -Dados -Sinal
            }
            $pd = @{}; foreach ($x in $dd.Pastas) { $pd[$x.ToLower()] = $true }
            foreach ($x in $oo.Pastas) {
                if (-not $pd.ContainsKey($x.ToLower()) -and -not $comArq.ContainsKey($x.ToLower())) { Reg $n $cam ("[pasta vazia] " + $x) "existe" "não existe" "Falha" "pasta vazia não chegou" -Dados }
            }
            $extras = @($dd.Arquivos | Where-Object { -not $vistos.ContainsKey($_.Caminho.ToLower()) })
            if ($extras.Count) {
                $ex = (@($extras | Select-Object -First 5 | ForEach-Object { $_.Caminho }) -join "; ") + $(if ($extras.Count -gt 5) { "; ..." } else { "" })
                Reg $n $cam "Arquivos só no destino" "-" $extras.Count "Info" $ex
            }
            if ($oo.Truncado -or $dd.Truncado) { Reg $n $cam "Inventário incompleto" "-" "-" "Atenção" "parou em $MaxArquivos arquivos; rode com -MaxArquivos maior" }
            Reg $n $cam "Inventário" ("{0} arquivos · {1} pastas · {2}" -f $oo.Arquivos.Count, $oo.Pastas.Count, (Tam (Soma $oo.Arquivos))) ("{0} arquivos · {1} pastas · {2}" -f $dd.Arquivos.Count, $dd.Pastas.Count, (Tam (Soma $dd.Arquivos))) "Info" ("espaço usado: {0} na origem, {1} no destino" -f (Tam $oo.Usado), (Tam $dd.Usado))
        }
    }
}

function Fase([string]$n) {
    $linhas = @($script:linhasVal | Where-Object { $_.Conta -eq $n })
    $ld     = @($linhas | Where-Object { $_.Dados })
    $sinais = @($linhas | Where-Object { $_.Sinal })
    $base   = if ($sinais.Count) { $sinais } else { $ld }
    if (-not $base.Count) { $fase = "Só pré-requisitos" }
    elseif (-not @($base | Where-Object { $_.Nivel -eq "OK" }).Count) {
        $fase = "Antes da migração"
        foreach ($l in $ld) { if ($l.Nivel -in "Falha", "Atenção") { $l.Nivel = "Pendente" } }
    }
    elseif (@($ld | Where-Object { $_.Nivel -eq "Falha" }).Count) { $fase = "Migração parcial" }
    elseif (@($ld | Where-Object { $_.Nivel -eq "Atenção" }).Count) { $fase = "Migrado com avisos" }
    else { $fase = "Migrado" }
    $pre = @($linhas | Where-Object { $_.Prereq })
    $pronto = "-"; $motivo = ""
    if ($pre.Count) {
        $f = @($pre | Where-Object { $_.Nivel -eq "Falha" })
        if ($f.Count) { $pronto = "Não"; $motivo = ($f | ForEach-Object { $_.Item }) -join ", " } else { $pronto = "Sim" }
    }
    return @{ Fase = $fase; Pronto = $pronto; Motivo = $motivo }
}

# ---------------------------------------------------------------- saída na tela
function Mostrar-Conta($p, $r) {
    $n = $p.Nome
    $linhas = @($script:linhasVal | Where-Object { $_.Conta -eq $n })
    Write-Host ""
    Write-Host ("   > {0}" -f $n) -ForegroundColor White -NoNewline
    Write-Host ("   {0}  ->  {1}" -f $p.Origem, $p.Destino) -ForegroundColor DarkGray
    Write-Host "     Fase: " -ForegroundColor DarkGray -NoNewline
    Write-Host $r.Fase -ForegroundColor (Cor-Fase $r.Fase) -NoNewline
    if ($r.Pronto -ne "-") {
        Write-Host "     Pronto para migrar: " -ForegroundColor DarkGray -NoNewline
        Write-Host $r.Pronto -ForegroundColor $(if ($r.Pronto -eq "Sim") { "Green" } else { "Red" })
    } else { Write-Host "" }
    foreach ($g in ($linhas | Group-Object Camada)) {
        $h = Contagem $g.Group
        Write-Host ("     {0,-14}" -f $g.Name) -ForegroundColor Gray -NoNewline
        Write-Host (Placar $h) -ForegroundColor (Cor-Placar $h)
        $prob = @($g.Group | Where-Object { $_.Nivel -in "Falha", "Atenção" } | Sort-Object @{ Expression = { [array]::IndexOf($NIVEIS, $_.Nivel) } }, Ordem)
        foreach ($l in ($prob | Select-Object -First 8)) {
            $cor = if ($l.Nivel -eq "Falha") { "Red" } else { "Yellow" }
            $tag = if ($l.Nivel -eq "Falha") { "XX" } else { "!!" }
            Write-Host ("        [{0}] {1}: {2}" -f $tag, (Curto $l.Item 42), $l.Situacao) -ForegroundColor $cor
        }
        if ($prob.Count -gt 8) { Write-Host ("        ... e mais {0} no relatório" -f ($prob.Count - 8)) -ForegroundColor DarkGray }
        $pend = @($g.Group | Where-Object { $_.Nivel -eq "Pendente" }).Count
        if ($pend) { Write-Host ("        {0} pendente(s): o que ainda vai chegar com a migração" -f $pend) -ForegroundColor DarkCyan }
    }
}
function Mostrar-Placar($pares, $res) {
    $cams = @($script:camadasVal)
    Write-Host ""
    Write-Host ("   {0,-16}{1,-21}{2,-8}" -f "Conta", "Fase", "Pronto") -ForegroundColor DarkGray -NoNewline
    foreach ($c in $cams) { Write-Host ("{0,-10}" -f $c) -ForegroundColor DarkGray -NoNewline }
    Write-Host ""
    foreach ($p in $pares) {
        $r = $res[$p.Nome]
        Write-Host ("   {0,-16}" -f (Curto $p.Nome 15)) -ForegroundColor White -NoNewline
        Write-Host ("{0,-21}" -f $r.Fase) -ForegroundColor (Cor-Fase $r.Fase) -NoNewline
        Write-Host ("{0,-8}" -f $r.Pronto) -ForegroundColor $(if ($r.Pronto -eq "Sim") { "Green" } elseif ($r.Pronto -eq "Não") { "Red" } else { "DarkGray" }) -NoNewline
        foreach ($c in $cams) {
            $h = Contagem @($script:linhasVal | Where-Object { $_.Conta -eq $p.Nome -and $_.Camada -eq $ROTULO_CAMADA[$c] })
            $t = $h["OK"] + $h["Atenção"] + $h["Falha"] + $h["Pendente"]
            $txt = if ($t) { "{0}/{1}" -f $h["OK"], $t } else { "info" }
            Write-Host ("{0,-10}" -f $txt) -ForegroundColor (Cor-Placar $h) -NoNewline
        }
        Write-Host ""
    }
}

# ---------------------------------------------------------------- relatório HTML
function Gerar-Html($pares, $res, [string]$arquivo, [string]$arqCsv, [timespan]$duracao) {
    $sb = New-Object System.Text.StringBuilder
    $tot = Contagem $script:linhasVal
    $prontas = @($res.Values | Where-Object { $_.Pronto -eq "Sim" }).Count
    $migradas = @($res.Values | Where-Object { $_.Fase -like "Migrado*" }).Count
    $quando = Get-Date -Format "dd/MM/yyyy HH:mm"
    $selo = if ($Simular) { '<span class="sim">SIMULAÇÃO: dados de exemplo</span>' } else { "" }
    [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Validação da migração · $(Esc $Tenant)</title>
<style>
:root{--bg:#f4f6f9;--card:#fff;--txt:#1d2733;--muted:#66717f;--line:#e2e7ed;
--ok:#18794e;--okbg:#e3f5ea;--at:#946200;--atbg:#fff3d1;--fa:#c42b2b;--fabg:#fde6e6;--pe:#0a6a96;--pebg:#e1f1fa;--in:#56606b;--inbg:#eceff3}
*{box-sizing:border-box}
body{margin:0;font-family:"Segoe UI",system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--txt);font-size:14px;line-height:1.45}
header{background:#0e2233;color:#fff;padding:28px 40px 24px}
header h1{margin:0 0 6px;font-size:22px;font-weight:600}
header .sub{color:#b6c5d4;font-size:13px}
header .rota{margin-top:10px;font-size:15px}
header .rota b{font-weight:600}
.sim{display:inline-block;background:#8e24aa;color:#fff;padding:2px 10px;border-radius:12px;font-size:12px;margin-left:10px;vertical-align:middle}
main{max-width:1240px;margin:0 auto;padding:26px 40px 60px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.card .v{font-size:26px;font-weight:600;line-height:1.2}
.card .r{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.05em;margin-top:2px}
.card.ok .v{color:var(--ok)} .card.at .v{color:var(--at)} .card.fa .v{color:var(--fa)} .card.pe .v{color:var(--pe)}
h2{font-size:16px;margin:30px 0 10px}
h3{font-size:14px;margin:20px 0 8px;display:flex;gap:10px;align-items:center}
h3 .pl{font-weight:400;color:var(--muted);font-size:13px}
table{width:100%;border-collapse:separate;border-spacing:0;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th{background:#f0f3f7;text-align:left;font-weight:600;font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;padding:8px 10px;border-bottom:1px solid var(--line)}
td{padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:none}
td.it{font-weight:500;word-break:break-word}
td.det{color:var(--muted);font-size:12px;word-break:break-all}
.b{display:inline-block;padding:1px 9px;border-radius:10px;font-size:12px;font-weight:600;white-space:nowrap}
.b.ok{color:var(--ok);background:var(--okbg)} .b.at{color:var(--at);background:var(--atbg)} .b.fa{color:var(--fa);background:var(--fabg)}
.b.pe{color:var(--pe);background:var(--pebg)} .b.in{color:var(--in);background:var(--inbg)}
details.conta{background:var(--card);border:1px solid var(--line);border-radius:12px;margin:14px 0;padding:0 18px 16px}
details.conta>summary{cursor:pointer;list-style:none;padding:16px 0 6px;display:flex;flex-wrap:wrap;gap:10px;align-items:center}
details.conta>summary::-webkit-details-marker{display:none}
details.conta>summary .nome{font-size:16px;font-weight:600}
details.conta>summary .par{color:var(--muted);font-size:12px;width:100%}
.motivo{color:var(--fa);font-size:12px;margin:4px 0 0}
.nota{color:var(--muted);font-size:12px;margin:6px 0 0}
.leg{display:grid;grid-template-columns:110px 1fr;gap:6px 14px;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
.dicas li{margin:4px 0}
footer{color:var(--muted);font-size:12px;margin-top:34px;border-top:1px solid var(--line);padding-top:14px}
@media print{details.conta{break-inside:avoid} header{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
</style></head><body>
<header>
<h1>Relatório de validação da migração $selo</h1>
<div class="sub">Quest On Demand Migration · gerado em $quando · duração $([int]$duracao.TotalMinutes) min $($duracao.Seconds) s</div>
<div class="rota"><b>$(Esc $Tenant)</b> &rarr; <b>$(Esc $TenantDestino)</b></div>
</header>
<main>
<div class="cards">
<div class="card"><div class="v">$($pares.Count)</div><div class="r">contas</div></div>
<div class="card ok"><div class="v">$prontas</div><div class="r">prontas para migrar</div></div>
<div class="card ok"><div class="v">$migradas</div><div class="r">migradas</div></div>
<div class="card ok"><div class="v">$($tot["OK"])</div><div class="r">conferências OK</div></div>
<div class="card at"><div class="v">$($tot["Atenção"])</div><div class="r">atenção</div></div>
<div class="card fa"><div class="v">$($tot["Falha"])</div><div class="r">falhas</div></div>
<div class="card pe"><div class="v">$($tot["Pendente"])</div><div class="r">pendentes</div></div>
</div>
<h2>Resumo por conta</h2>
<table><tr><th>Conta</th><th>Fase</th><th>Pronto para migrar</th>
"@)
    foreach ($c in $script:camadasVal) { [void]$sb.Append("<th>$(Esc $ROTULO_CAMADA[$c])</th>") }
    [void]$sb.Append("</tr>")
    foreach ($p in $pares) {
        $r = $res[$p.Nome]
        $cf = switch -Wildcard ($r.Fase) { "Migrado*" { "ok" } "Migração parcial" { "fa" } "Antes*" { "pe" } default { "in" } }
        $cp = switch ($r.Pronto) { "Sim" { "ok" } "Não" { "fa" } default { "in" } }
        [void]$sb.Append("<tr><td class=`"it`">$(Esc $p.Nome)</td><td><span class=`"b $cf`">$(Esc $r.Fase)</span></td><td><span class=`"b $cp`">$(Esc $r.Pronto)</span></td>")
        foreach ($c in $script:camadasVal) {
            $h = Contagem @($script:linhasVal | Where-Object { $_.Conta -eq $p.Nome -and $_.Camada -eq $ROTULO_CAMADA[$c] })
            $t = $h["OK"] + $h["Atenção"] + $h["Falha"] + $h["Pendente"]
            $cl = if ($h["Falha"]) { "fa" } elseif ($h["Atenção"]) { "at" } elseif ($h["Pendente"]) { "pe" } elseif ($h["OK"]) { "ok" } else { "in" }
            $tx = if ($t) { "{0}/{1}" -f $h["OK"], $t } else { "info" }
            [void]$sb.Append("<td><span class=`"b $cl`">$tx</span></td>")
        }
        [void]$sb.Append("</tr>")
    }
    [void]$sb.Append("</table>")

    [void]$sb.Append("<h2>Detalhes por conta</h2>")
    foreach ($p in $pares) {
        $r = $res[$p.Nome]
        $cf = switch -Wildcard ($r.Fase) { "Migrado*" { "ok" } "Migração parcial" { "fa" } "Antes*" { "pe" } default { "in" } }
        $abre = if ($pares.Count -le 5) { " open" } else { "" }
        [void]$sb.Append("<details class=`"conta`"$abre><summary><span class=`"nome`">$(Esc $p.Nome)</span><span class=`"b $cf`">$(Esc $r.Fase)</span>")
        if ($r.Pronto -ne "-") { [void]$sb.Append($(if ($r.Pronto -eq "Sim") { "<span class=`"b ok`">pronto para migrar</span>" } else { "<span class=`"b fa`">não está pronto para migrar</span>" })) }
        [void]$sb.Append("<span class=`"par`">$(Esc $p.Origem) &rarr; $(Esc $p.Destino)</span></summary>")
        if ($r.Motivo) { [void]$sb.Append("<p class=`"motivo`">Falta resolver: $(Esc $r.Motivo)</p>") }
        foreach ($g in (@($script:linhasVal | Where-Object { $_.Conta -eq $p.Nome }) | Group-Object Camada)) {
            $h = Contagem $g.Group
            [void]$sb.Append("<h3>$(Esc $g.Name) <span class=`"pl`">$(Esc (Placar $h))</span></h3>")
            [void]$sb.Append("<table><tr><th style=`"width:96px`">Situação</th><th>Item</th><th>Origem</th><th>Destino</th><th>Observação</th></tr>")
            $ordenadas = @($g.Group | Sort-Object @{ Expression = { [array]::IndexOf($NIVEIS, $_.Nivel) } }, Ordem)
            foreach ($l in ($ordenadas | Select-Object -First 300)) {
                $det = if ($l.Detalhe) { "<div class=`"det`">$(Esc $l.Detalhe)</div>" } else { "" }
                [void]$sb.Append("<tr><td><span class=`"b $(Classe $l.Nivel)`">$(Esc $l.Nivel)</span></td><td class=`"it`">$(Esc $l.Item)</td><td>$(Esc $l.Origem)</td><td>$(Esc $l.Destino)</td><td>$(Esc $l.Situacao)$det</td></tr>")
            }
            [void]$sb.Append("</table>")
            if ($ordenadas.Count -gt 300) { [void]$sb.Append("<p class=`"nota`">Mostrando 300 de $($ordenadas.Count) linhas. A lista completa está no CSV.</p>") }
        }
        [void]$sb.Append("</details>")
    }

    [void]$sb.Append("<h2>Como ler este relatório</h2><div class=`"leg`">")
    [void]$sb.Append("<span><span class=`"b ok`">OK</span></span><span>conferido e igual nos dois lados.</span>")
    [void]$sb.Append("<span><span class=`"b at`">Atenção</span></span><span>chegou, mas com diferença que vale olhar (data, pasta, permissão, arquivo do Office).</span>")
    [void]$sb.Append("<span><span class=`"b fa`">Falha</span></span><span>não chegou, chegou diferente ou falta um pré-requisito.</span>")
    [void]$sb.Append("<span><span class=`"b pe`">Pendente</span></span><span>a conta ainda não foi migrada; é o que precisa chegar.</span>")
    [void]$sb.Append("<span><span class=`"b in`">Info</span></span><span>informação para contexto, não entra na contagem.</span></div>")
    [void]$sb.Append("<ul class=`"dicas`">")
    [void]$sb.Append("<li><b>Itens na caixa</b> inclui itens de sistema que cada tenant cria por conta própria; a prova da migração está nas pastas, nos itens do kit e na amostra.</li>")
    [void]$sb.Append("<li><b>Pastas</b> são comparadas pelo tipo (Inbox, Calendar...) e não pelo nome, porque o nome muda com o idioma da caixa.</li>")
    [void]$sb.Append("<li><b>Amostra</b> procura no destino os e-mails mais recentes da origem pelo Message-ID, o identificador que o e-mail carrega desde o envio. Se não achar, tenta por data e assunto.</li>")
    [void]$sb.Append("<li><b>OneDrive</b> compara o hash (quickXorHash) de cada arquivo. Arquivos do Office podem ter hash diferente porque o SharePoint grava metadados dentro do arquivo; nesses casos abra e confira.</li>")
    [void]$sb.Append("<li><b>X500</b>: o destino precisa do LegacyExchangeDN da origem como endereço X500 para que respostas a e-mails e reuniões antigas não voltem com NDR.</li>")
    [void]$sb.Append("</ul><h2>Camadas conferidas</h2><ul class=`"dicas`">")
    foreach ($c in $script:camadasVal) { [void]$sb.Append("<li><b>$(Esc $ROTULO_CAMADA[$c])</b>: $(Esc $DESC_CAMADAS[$c])</li>") }
    [void]$sb.Append("</ul>")
    [void]$sb.Append("<footer>Gerado pelo kit-validacao-odm.ps1 · somente leitura, nada foi alterado nas contas · detalhes completos em $(Esc (Split-Path $arqCsv -Leaf))</footer>")
    [void]$sb.Append("</main></body></html>")
    [IO.File]::WriteAllText($arquivo, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

# ---------------------------------------------------------------- fluxo
function Invoke-Validacao {
    $T = 5
    $inicioVal = Get-Date
    $script:linhasVal = New-Object System.Collections.Generic.List[object]
    $script:ordemVal = 0
    $script:appsVal = @()

    # ---- 1. contas e camadas
    Etapa 1 "Contas e camadas" $T
    if (-not $TenantDestino) { $script:TenantDestino = Pergunta "Tenant de DESTINO (ex.: fabrikam.onmicrosoft.com):" }
    $vistos = @{}; $pares = @()
    foreach ($x in @(Escolher-Pares)) { if ($x -and $x.Origem -and -not $vistos.ContainsKey($x.Origem.ToLower())) { $vistos[$x.Origem.ToLower()] = $true; $pares += $x } }
    if (-not $pares.Count) { Encerrar "Nenhuma conta escolhida." }
    foreach ($g in @($pares | Group-Object Nome | Where-Object { $_.Count -gt 1 })) { foreach ($x in $g.Group) { $x.Nome = $x.Origem.ToLower() } }
    foreach ($p in $pares) { Ok ("{0}  ->  {1}" -f $p.Origem, $p.Destino) }
    $script:camadasVal = @(Escolher-Camadas)
    if (-not $script:camadasVal.Count) { Encerrar "Nenhuma camada escolhida." }
    $logins = 0
    if (@($script:camadasVal | Where-Object { $_ -in "Conta", "Itens", "Amostra", "OneDrive" }).Count) { $logins += 2 }
    if (@($script:camadasVal | Where-Object { $_ -in "Caixa", "Pastas" }).Count) { $logins += 2 }
    Write-Host ""
    Campo "Camadas" (($script:camadasVal | ForEach-Object { $ROTULO_CAMADA[$_] }) -join ", ")
    Campo "Logins"  ("{0}, sempre com o admin de cada tenant" -f $logins)
    if ("Amostra" -in $script:camadasVal) { Campo "Amostra" ("{0} e-mails mais recentes por conta" -f $Amostra) }
    Info "a validação só lê. Nada é alterado nas caixas nem nos OneDrives."
    if (-not $Simular -and (Pergunta "Começar? (S/N):") -notmatch "^[sS]") { Encerrar "Cancelado." }

    $script:dados = @{}
    foreach ($p in $pares) { $script:dados[$p.Nome] = @{ Origem = @{}; Destino = @{} } }

    # ---- 2 e 3. leitura
    Etapa 2 "Ler a origem" $T
    Ler-Lado "Origem" $Tenant $pares $script:camadasVal
    Etapa 3 "Ler o destino" $T
    Ler-Lado "Destino" $TenantDestino $pares $script:camadasVal

    # ---- 4. comparação
    Etapa 4 "Comparar" $T
    $res = @{}
    foreach ($p in $pares) {
        Comparar $p
        $res[$p.Nome] = Fase $p.Nome
        Mostrar-Conta $p $res[$p.Nome]
    }

    # ---- 5. resultado
    Etapa 5 "Resultado" $T
    Mostrar-Placar $pares $res
    $tot = Contagem $script:linhasVal
    $fases = @($res.Values | ForEach-Object { $_.Fase })
    Write-Host ""
    Write-Host ("   {0} OK · {1} atenção · {2} falha(s) · {3} pendente(s) · {4} informativas" -f $tot["OK"], $tot["Atenção"], $tot["Falha"], $tot["Pendente"], $tot["Info"]) -ForegroundColor (Cor-Placar $tot)
    Write-Host ""
    if ($fases -contains "Antes da migração") { Info "Antes da migração: todas as contas precisam estar 'Pronto: Sim'. Os pendentes são o que tem que chegar." }
    if (@($res.Values | Where-Object { $_.Pronto -eq "Não" }).Count) { Aviso "Há contas sem pré-requisito. Resolva antes de migrar (veja 'Falta resolver' no relatório)." }
    if ($fases -contains "Migração parcial") { Info "Migração parcial: se a migração ainda roda ou falta o incremental, valide de novo no fim." }
    if (@($fases | Where-Object { $_ -like "Migrado*" }).Count) { Info "Migrado: guarde o relatório HTML como evidência da migração." }

    $c = Get-Date -Format "yyyyMMdd-HHmmss"
    $nomeBase = if ($Simular) { "validacao-SIMULACAO-$c" } else { "validacao-{0}-{1}" -f $Tenant.Split(".")[0], $c }
    $arqCsv  = Join-Path $pastaBase "$nomeBase.csv"
    $arqHtml = Join-Path $pastaBase "$nomeBase.html"
    $script:linhasVal | Select-Object Conta, Camada, Item, Origem, Destino, Nivel, Situacao, Detalhe |
        Export-Csv $arqCsv -NoTypeInformation -Encoding UTF8 -UseCulture
    Gerar-Html $pares $res $arqHtml $arqCsv ((Get-Date) - $inicioVal)

    Write-Host ""
    Linha "═" "DarkCyan"
    if ($Simular) { Write-Host "   SIMULAÇÃO CONCLUÍDA: relatório de exemplo, nada foi lido nem alterado" -ForegroundColor Magenta }
    else          { Write-Host "   VALIDAÇÃO CONCLUÍDA" -ForegroundColor Green }
    Campo "Relatório"  $arqHtml
    Campo "Detalhes"   $arqCsv
    Campo "Log"        $arqLog
    Campo "Duração"    ("{0:mm\:ss}" -f ((Get-Date) - $inicioVal))
    Linha "═" "DarkCyan"
    try { Start-Process $arqHtml } catch { }
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
$script:appsVal = @()
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
        if (-not $Simular) { Write-Host "     [3]  Simular        " -ForegroundColor Magenta -NoNewline; Write-Host "mostra tudo o que seria feito, sem login e sem mudar nada" -ForegroundColor Gray }
        Write-Host "     [4]  Validar        " -ForegroundColor Cyan -NoNewline; Write-Host "confere a migração em 6 camadas e gera relatório HTML" -ForegroundColor Gray
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
        Tentar-Login "Microsoft Graph" { Connect-MgGraph -TenantId $Tenant -NoWelcome -ErrorAction Stop -Scopes `
            "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All", "User.Read.All", "Organization.Read.All" }
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
    Limpar-AppsEsquecidos
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
    foreach ($a in @($script:appsVal | Where-Object { $_ })) {
        Aviso "o app de leitura '$($a.Nome)' pode ter ficado no tenant $($a.Tenant)."
        Info "a próxima execução encontra e oferece apagar; ou apague em Entra ID > App registrations > All applications."
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
