<#
    Kit de validacao para o piloto do ODM M365.
    Cria um conteudo conhecido (e-mails, pasta, anexo, reuniao, contato e arquivos no OneDrive)
    nas contas de teste do tenant de origem, para comparar depois da migracao.

    Como funciona:
      0. Pede a criacao antecipada dos OneDrives na origem e no destino (SharePoint Online).
      1. Login de admin (permissao delegada) para criar um app temporario no tenant de origem.
      2. O app recebe permissoes de aplicacao no Microsoft Graph (consentimento de admin).
      3. Login como o app e criacao do conteudo em cada usuario. Espera o OneDrive ficar pronto.
      4. Novo login de admin para apagar o app temporario.

    Logins que aparecem (todos com admin):
      SharePoint da origem, SharePoint do destino, Graph da origem (2 vezes).

    Rodar no PowerShell do notebook (nao precisa ser nas VMs).
#>
param(
    [string]  $Tenant        = "<tenant-origem>.onmicrosoft.com",
    [string]  $TenantDestino = "<tenant-destino>.onmicrosoft.com",
    [string[]]$Usuarios = @("teste.nexus1", "teste.nexus2", "teste.nexus3"),
    # Cria so os arquivos do OneDrive (para rodar de novo sem duplicar e-mails)
    [switch]  $SoOneDrive,
    # Pula o pedido de criacao dos OneDrives (se ja foi feito antes)
    [switch]  $SemProvisionar,
    # Quanto tempo esperar o OneDrive de cada usuario ficar pronto
    [int]     $EsperaOneDriveMin = 40
)

$ErrorActionPreference = "Stop"

if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph.Authentication

function Graph {
    param([string]$Metodo, [string]$Uri, $Corpo, [string]$Tipo = "application/json", [int]$Tentativas = 6)
    for ($i = 1; $i -le $Tentativas; $i++) {
        try {
            if ($null -eq $Corpo) { return Invoke-MgGraphRequest -Method $Metodo -Uri $Uri }
            if ($Tipo -eq "application/json") { $Corpo = $Corpo | ConvertTo-Json -Depth 10 }
            return Invoke-MgGraphRequest -Method $Metodo -Uri $Uri -Body $Corpo -ContentType $Tipo
        } catch {
            $msg = $_.Exception.Message
            if ($i -lt $Tentativas -and $msg -match "403|401|Forbidden|Unauthorized|429|503|ErrorAccessDenied") {
                Write-Host "   aguardando permissoes ($i/$Tentativas)..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 20
            } else { throw }
        }
    }
}

# ---------------------------------------------------------------- 0. OneDrive antecipado
if (-not $SemProvisionar) {
    if (-not (Get-Module -ListAvailable Microsoft.Online.SharePoint.PowerShell)) {
        Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser -Force
    }
    Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking
    foreach ($t in @($Tenant, $TenantDestino)) {
        $prefixo = $t.Split('.')[0]
        Write-Host "`n[0/4] Pedindo os OneDrives no $t (login de admin do SharePoint desse tenant)..." -ForegroundColor Cyan
        Connect-SPOService -Url "https://$prefixo-admin.sharepoint.com"
        Request-SPOPersonalSite -UserEmails ($Usuarios | ForEach-Object { "$_@$t" }) -NoWait
        Disconnect-SPOService
        Write-Host "   pedido feito para: $($Usuarios -join ', ')"
    }
}

function Esperar-OneDrive($upn) {
    $limite = (Get-Date).AddMinutes($EsperaOneDriveMin)
    while ((Get-Date) -lt $limite) {
        try { Graph GET "v1.0/users/$upn/drive?`$select=id" -Tentativas 1 | Out-Null; return $true }
        catch {
            Write-Host "   OneDrive ainda sendo criado, nova tentativa em 1 min..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 60
        }
    }
    return $false
}

# ---------------------------------------------------------------- 1. App temporario
Write-Host "`n[1/4] Login de admin no $Tenant (janela da Microsoft)..." -ForegroundColor Cyan
Connect-MgGraph -TenantId $Tenant -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -NoWelcome
Write-Host "   conectado como $((Get-MgContext).Account)"

$graphSp = Graph GET "v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')"
$perms   = "Mail.ReadWrite", "Calendars.ReadWrite", "Contacts.ReadWrite", "Files.ReadWrite.All", "User.Read.All"
$roles   = $graphSp.appRoles | Where-Object { $_.value -in $perms -and $_.allowedMemberTypes -contains "Application" }

$app = Graph POST "v1.0/applications" @{
    displayName            = "Lab-Kit-Validacao-ODM (temporario)"
    requiredResourceAccess = @(@{
        resourceAppId  = $graphSp.appId
        resourceAccess = @($roles | ForEach-Object { @{ id = $_.id; type = "Role" } })
    })
}
$sp = Graph POST "v1.0/servicePrincipals" @{ appId = $app.appId }
foreach ($r in $roles) {
    Graph POST "v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" @{
        principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $r.id
    } | Out-Null
}
$segredo = Graph POST "v1.0/applications/$($app.id)/addPassword" @{
    passwordCredential = @{ displayName = "kit"; endDateTime = (Get-Date).ToUniversalTime().AddHours(2).ToString("o") }
}
Disconnect-MgGraph | Out-Null
Write-Host "   app criado ($($app.appId)) com: $($perms -join ', ')"
Write-Host "   aguardando 60 s para o segredo e as permissoes valerem..."
Start-Sleep -Seconds 60

# ---------------------------------------------------------------- 2. Login como o app
Write-Host "`n[2/4] Login como o app..." -ForegroundColor Cyan
$cred = New-Object System.Management.Automation.PSCredential(
    $app.appId, (ConvertTo-SecureString $segredo.secretText -AsPlainText -Force))
Connect-MgGraph -TenantId $Tenant -ClientSecretCredential $cred -NoWelcome

# ---------------------------------------------------------------- 3. Conteudo
Write-Host "`n[3/4] Criando o kit em cada usuario..." -ForegroundColor Cyan
$fuso     = "E. South America Standard Time"
$anexoB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            "Anexo de teste do kit de validacao. Se este texto chegou inteiro, o anexo migrou."))
$manifesto = @()

foreach ($nome in $Usuarios) {
    $upn = "$nome@$Tenant"
    Write-Host "`n -> $upn"
    $item = [ordered]@{ Usuario = $upn; Emails = 0; Anexo = $false; Pasta = $false; Reuniao = $false; Contato = $false; OneDrive = 0; Observacao = "" }

    try { Graph GET "v1.0/users/$upn/mailFolders/inbox?`$select=id" | Out-Null }
    catch {
        $item.Observacao = "Caixa ainda nao existe (licenca recente). Rode de novo mais tarde."
        Write-Host "   $($item.Observacao)" -ForegroundColor Yellow
        $manifesto += [pscustomobject]$item
        continue
    }

    function Novo-Email($pasta, $assunto, $texto, [switch]$ComAnexo) {
        $m = @{
            subject      = $assunto
            body         = @{ contentType = "Text"; content = $texto }
            from         = @{ emailAddress = @{ address = "admin@$Tenant"; name = "Lab Migracao" } }
            toRecipients = @(@{ emailAddress = @{ address = $upn } })
            # PR_MESSAGE_FLAGS = 1: item recebido e lido (sem isso o Outlook trata como rascunho)
            singleValueExtendedProperties = @(@{ id = "Integer 0x0E07"; value = "1" })
        }
        if ($ComAnexo) {
            $m.attachments = @(@{ "@odata.type" = "#microsoft.graph.fileAttachment"; name = "anexo-teste.txt"; contentBytes = $anexoB64 })
        }
        Graph POST "v1.0/users/$upn/mailFolders/$pasta/messages" $m | Out-Null
    }

    if (-not $SoOneDrive) {
    # E-mails numerados na caixa de entrada
    1..3 | ForEach-Object {
        Novo-Email "inbox" ("Teste migracao {0:D2}" -f $_) "E-mail $_ de 3 do kit de validacao."
        $item.Emails++
    }
    # E-mail com anexo
    Novo-Email "inbox" "Teste migracao 04 - com anexo" "Este e-mail tem um anexo de texto." -ComAnexo
    $item.Emails++; $item.Anexo = $true

    # Pasta com um e-mail dentro
    $pastaExistente = @((Graph GET "v1.0/users/$upn/mailFolders?`$top=100").value | Where-Object { $_.displayName -eq "Projeto Nexus" })
    $pasta = if ($pastaExistente) { $pastaExistente[0] } else { Graph POST "v1.0/users/$upn/mailFolders" @{ displayName = "Projeto Nexus" } }
    Novo-Email $pasta.id "Teste migracao 05 - dentro da pasta" "Este e-mail fica na pasta Projeto Nexus."
    $item.Emails++; $item.Pasta = $true

    # Reuniao na semana que vem
    $inicio = (Get-Date).Date.AddDays(7).AddHours(10)
    Graph POST "v1.0/users/$upn/events" @{
        subject = "Reuniao de validacao da migracao"
        body    = @{ contentType = "Text"; content = "Evento do kit de validacao." }
        start   = @{ dateTime = $inicio.ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = $fuso }
        end     = @{ dateTime = $inicio.AddHours(1).ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = $fuso }
    } | Out-Null
    $item.Reuniao = $true

    # Contato pessoal
    Graph POST "v1.0/users/$upn/contacts" @{
        givenName      = "Contato"
        surname        = "Validacao"
        companyName    = "Fornecedor Teste"
        emailAddresses = @(@{ address = "contato.validacao@exemplo.com"; name = "Contato Validacao" })
    } | Out-Null
    $item.Contato = $true

    }

    # OneDrive: um arquivo na raiz e uma pasta com um arquivo
    if (-not (Esperar-OneDrive $upn)) {
        $item.Observacao = "OneDrive nao ficou pronto em $EsperaOneDriveMin min. Rode com -SoOneDrive -SemProvisionar depois."
        Write-Host "   $($item.Observacao)" -ForegroundColor Yellow
    } else { try {
        Graph PUT "v1.0/users/$upn/drive/root:/Kit-Validacao.txt:/content" "Arquivo na raiz do OneDrive." "text/plain" | Out-Null
        $item.OneDrive++
        Graph PUT "v1.0/users/$upn/drive/root:/Projeto%20Nexus/Planilha.csv:/content" "Item;Quantidade`nTeste;1" "text/plain" | Out-Null
        $item.OneDrive++
    } catch {
        $item.Observacao = "Erro ao gravar no OneDrive: $($_.Exception.Message)"
        Write-Host "   $($item.Observacao)" -ForegroundColor Yellow
    } }

    Write-Host "   ok: $($item.Emails) e-mails, $($item.OneDrive) arquivos no OneDrive" -ForegroundColor Green
    $manifesto += [pscustomobject]$item
}

$sufixo  = if ($SoOneDrive) { "-onedrive" } else { "" }
$arquivo = Join-Path (Get-Location) "kit-validacao-$($Tenant.Split('.')[0])$sufixo.csv"
$manifesto | Export-Csv $arquivo -NoTypeInformation -Encoding UTF8
$manifesto | Format-Table -AutoSize
Write-Host "Manifesto salvo em $arquivo"
Disconnect-MgGraph | Out-Null

# ---------------------------------------------------------------- 4. Limpeza
Write-Host "`n[4/4] Login de admin de novo para apagar o app temporario..." -ForegroundColor Cyan
Connect-MgGraph -TenantId $Tenant -Scopes "Application.ReadWrite.All" -NoWelcome
Graph DELETE "v1.0/applications/$($app.id)" | Out-Null
Disconnect-MgGraph | Out-Null
Write-Host "   app apagado. Fim." -ForegroundColor Green

Read-Host "`nPressione Enter para fechar"
