# Pester 5: проверка чистых функций из scripts\*.ps1 (без запуска самих скриптов).
# Функции вынимаются из файлов через AST, поэтому скрипты остаются самодостаточными.
BeforeAll {
    $script:scripts = Join-Path $PSScriptRoot '..\..\scripts'
    function Get-ScriptFunctionText([string]$File, [string]$Name) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:scripts $File), [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
        if (-not $fn) { throw "Функция $Name не найдена в $File" }
        return $fn.Extent.Text
    }
    # точка перед scriptblock: функции определяются в текущей области (BeforeAll), а не во вложенной
    . ([scriptblock]::Create((Get-ScriptFunctionText 'load-and-start.ps1' 'ConvertFrom-Sha256Sums')))
    . ([scriptblock]::Create((Get-ScriptFunctionText 'load-and-start.ps1' 'Test-Sha256Sums')))
    . ([scriptblock]::Create((Get-ScriptFunctionText 'virtualbox-create-vm.ps1' 'ConvertFrom-BridgedIfs')))
    . ([scriptblock]::Create((Get-ScriptFunctionText 'hyperv-install.ps1' 'Test-WimImageMatch')))
}

Describe 'SHA256SUMS (load-and-start.ps1)' {
    BeforeAll {
        $script:root = Join-Path $env:TEMP ('sums-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Force "$script:root\installers\sub dir" | Out-Null
        [IO.File]::WriteAllBytes("$script:root\images.tar", [byte[]](1..50))
        [IO.File]::WriteAllBytes("$script:root\installers\sub dir\a b.exe", [byte[]](7, 8, 9))
        [IO.File]::WriteAllBytes("$script:root\bad.bin", [byte[]](1, 2, 3))
        $h1 = (Get-FileHash "$script:root\images.tar" -Algorithm SHA256).Hash.ToLower()
        $h2 = (Get-FileHash "$script:root\installers\sub dir\a b.exe" -Algorithm SHA256).Hash.ToLower()
        $zero = '0' * 64
        # формат sha256sum: две пробела и ./ в пути, пути со слэшами; CRLF и BOM как после копирования через Windows
        $script:lines = @(
            "$h1  ./images.tar",
            "$($h2.ToUpper()) *./installers/sub dir/a b.exe",
            "$zero  ./bad.bin",
            "$h1  ./missing.txt",
            ''
        )
    }
    AfterAll { Remove-Item -Recurse -Force $script:root -ErrorAction SilentlyContinue }

    It 'разбирает хэш и путь, убирает ./ и меняет / на \' {
        $e = @(ConvertFrom-Sha256Sums $script:lines)
        $e.Count | Should -Be 4
        $e[0].Path | Should -Be 'images.tar'
        $e[1].Path | Should -Be 'installers\sub dir\a b.exe'
        $e[1].Hash | Should -BeExactly $e[1].Hash.ToLower()
    }
    It 'игнорирует пустые и посторонние строки, CRLF и BOM' {
        $e = @(ConvertFrom-Sha256Sums @(([string][char]0xFEFF + ('a' * 64) + "  ./x.txt`r"), '# comment', ''))
        $e.Count | Should -Be 1
        $e[0].Path | Should -Be 'x.txt'
    }
    It 'находит файлы, считает Ok / Mismatch / Missing' {
        $r = @(Test-Sha256Sums $script:root $script:lines)
        ($r | Where-Object Path -eq 'images.tar').Status | Should -Be 'Ok'
        ($r | Where-Object Path -eq 'installers\sub dir\a b.exe').Status | Should -Be 'Ok'
        ($r | Where-Object Path -eq 'bad.bin').Status | Should -Be 'Mismatch'
        ($r | Where-Object Path -eq 'missing.txt').Status | Should -Be 'Missing'
    }
}

Describe 'VBoxManage list bridgedifs (virtualbox-create-vm.ps1)' {
    It 'разбирает имена, статус и Wi-Fi' {
        $out = @(
            'Name:            Intel(R) Ethernet Connection (2) I219-V',
            'GUID:            11111111-2222-3333-4444-555555555555',
            'DHCP:            Disabled',
            'Status:          Up',
            'Wireless:        No',
            '',
            'Name:            Intel(R) Wi-Fi 6 AX201 160MHz',
            'GUID:            66666666-2222-3333-4444-555555555555',
            'Status:          Down',
            'Wireless:        Yes'
        )
        $l = @(ConvertFrom-BridgedIfs $out)
        $l.Count | Should -Be 2
        $l[0].Name | Should -Be 'Intel(R) Ethernet Connection (2) I219-V'
        $l[0].Status | Should -Be 'Up'
        $l[1].Wireless | Should -Be 'Yes'
    }
    It 'пустой вывод даёт пустой список' {
        @(ConvertFrom-BridgedIfs @()).Count | Should -Be 0
    }
}

Describe 'Выбор образа в install.wim (hyperv-install.ps1)' {
    It 'LTSC 2019: версия 10.0.17763 без четвёртого числа' {
        Test-WimImageMatch -Version '10.0.17763' -EditionId 'EnterpriseS' -Build 17763 | Should -BeTrue
    }
    It 'версия с четвёртым числом' {
        Test-WimImageMatch -Version '10.0.17763.1' -EditionId 'Enterprise' -Build 17763 | Should -BeTrue
    }
    It 'другая сборка не подходит' {
        Test-WimImageMatch -Version '10.0.19044' -EditionId 'EnterpriseS' -Build 17763 | Should -BeFalse
        Test-WimImageMatch -Version '10.0.177630' -EditionId 'EnterpriseS' -Build 17763 | Should -BeFalse
    }
    It 'не Enterprise не подходит' {
        Test-WimImageMatch -Version '10.0.17763' -EditionId 'Professional' -Build 17763 | Should -BeFalse
    }
}
