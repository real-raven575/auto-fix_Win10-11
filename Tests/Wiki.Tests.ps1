# docs/wiki/ is published to the GitHub Wiki tab when it merges
# (.github/workflows/wiki.yml). Broken links there would go public, so
# check every link between pages and every README section they point to.

BeforeDiscovery {
    $script:wikiDir = Join-Path $PSScriptRoot '..\docs\wiki'
    $script:pages = @(Get-ChildItem -LiteralPath $wikiDir -Filter '*.md' | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    $script:wikiDir = Join-Path $PSScriptRoot '..\docs\wiki'
    $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\README.md') -Raw
    # GitHub anchor: lower case, drop punctuation except - and space, spaces become -.
    $script:anchors = @([regex]::Matches($readme, '(?m)^#{1,6}\s+(.+?)\s*$') | ForEach-Object {
            ($_.Groups[1].Value.ToLowerInvariant() -replace '[^a-z0-9 \-]', '') -replace ' ', '-'
        })
}

Describe 'Wiki pages' {
    It 'has a Home page' {
        Test-Path -LiteralPath (Join-Path $wikiDir 'Home.md') | Should -BeTrue
    }

    It '<Name> links only to wiki pages that exist' -ForEach $pages {
        $text = Get-Content -LiteralPath $Path -Raw
        foreach ($m in [regex]::Matches($text, '\]\(([A-Za-z0-9\-]+)\)')) {
            $target = Join-Path $wikiDir ($m.Groups[1].Value + '.md')
            $target | Should -Exist -Because "$Name links to $($m.Groups[1].Value)"
        }
    }

    It '<Name> links only to README sections that exist' -ForEach $pages {
        $text = Get-Content -LiteralPath $Path -Raw
        foreach ($m in [regex]::Matches($text, 'auto-fix_Win10-11#([a-z0-9\-]+)\)')) {
            $anchors | Should -Contain $m.Groups[1].Value -Because "$Name links to README #$($m.Groups[1].Value)"
        }
    }

    It '<Name> is plain ASCII or UTF-8 without a byte order mark' -ForEach $pages {
        $bytes = [IO.File]::ReadAllBytes($Path)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }
}
