# The restart countdown. Nothing restarts here: shutdown.exe, the keyboard and the
# clock are fakes. Each fake key arrives on one poll; the clock moves 1 s per sleep.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AutoFixer\AutoFixer.psd1') -Force

    # Runs the countdown with keys that arrive in order (a blank means no key on that
    # poll) and returns the shutdown.exe calls it made.
    function Invoke-Countdown([string[]] $Keys = @(), [int] $ExitCode = 0) {
        $calls = [System.Collections.ArrayList]::new()
        $queue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $queue.Enqueue($k) }
        $clock = @{ Now = [datetime]'2026-10-30 12:00:00' }
        $shutdown = { param([string[]] $Arguments) $null = $calls.Add(($Arguments[0..2] -join ' ').Trim()); $ExitCode }.GetNewClosure()
        $poll = { if ($queue.Count) { $queue.Dequeue() } }.GetNewClosure()
        $now = { $clock.Now }.GetNewClosure()
        $sleep = { $clock.Now = $clock.Now.AddSeconds(1) }.GetNewClosure()
        InModuleScope AutoFixer -Parameters @{ Sd = $shutdown; P = $poll; N = $now; Sl = $sleep } {
            param($Sd, $P, $N, $Sl)
            Invoke-AfRestart -DelaySeconds 5 -Shutdown $Sd -PollKey $P -Now $N -Sleep $Sl 6>$null
        }
        return $calls.ToArray()
    }
}

Describe 'Invoke-AfRestart' {
    It 'lets Windows restart when the countdown runs out' {
        Invoke-Countdown | Should -Be @('/r /t 5')
    }

    It 'restarts at once on R' {
        Invoke-Countdown -Keys '', 'r' | Should -Be @('/r /t 5', '/a', '/r /t 0')
    }

    It 'cancels on C, Esc or any other key' {
        foreach ($key in 'c', 'Escape', 'x') {
            Invoke-Countdown -Keys $key | Should -Be @('/r /t 5', '/a')
        }
    }

    It 'stops when Windows refuses the restart' {
        Invoke-Countdown -Keys 'r' -ExitCode 1190 | Should -Be @('/r /t 5')
    }
}
