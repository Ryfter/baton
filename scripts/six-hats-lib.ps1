#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build the six role-prefixed tasks for an Edward de Bono Six Thinking Hats run.

.DESCRIPTION
  Pure function: takes a question + a provider roster, returns an array of
  task hashtables shaped for Invoke-FleetEnsembleTasks. The six canonical
  role preambles live here; providers are rotated across the six hats.
#>

# NOTE: Preambles are SINGLE-LINE on purpose. Plan 4's command_template
# substitution naively interpolates {{prompt}} into a shell-quoted string,
# so embedded newlines and certain Unicode (em-dash, smart-quotes) break
# the CLI invocation. Plan 5 deferred the stdin-passing fix. Keep these
# concise and ASCII-only. The "Question: <q>" delimiter is appended by
# Build-SixHatsTasks with a literal space, not a newline.
$script:HatPreambles = @{
    white  = 'You are wearing the WHITE HAT. Respond using ONLY facts, data, and known information about this question. Identify what is known, what is unknown, and what data would be needed to decide well. Be neutral and objective. No opinions, no emotions, no risk/benefit analysis - those are other hats.'
    red    = "You are wearing the RED HAT. Respond with your gut reactions, feelings, hunches, and intuitions about this question. No justification needed - emotional response is the point. Speak in first person ('I feel...', 'My gut says...'). Be brief and visceral."
    black  = "You are wearing the BLACK HAT. Respond by identifying the risks, problems, weaknesses, failure modes, and reasons this could go badly. Be specific about what could break, who could be hurt, what assumptions might be wrong. Devil's advocate. Do not balance with positives - that is the Yellow Hat's job."
    yellow = "You are wearing the YELLOW HAT. Respond by identifying the benefits, opportunities, upsides, and reasons this could go well. Be specific about what could be gained, who could be helped, what new possibilities open up. Optimistic but grounded. Do not balance with risks - that is the Black Hat's job."
    green  = 'You are wearing the GREEN HAT. Respond with creative alternatives, novel angles, lateral moves, and unconventional ideas about this question. Generate options, not judgments. What would the obvious answer miss? What if the framing is wrong? Be playful.'
    blue   = 'You are wearing the BLUE HAT. Respond by stepping back from the content to the process: what frame should we use here, what process should we follow, what big-picture pattern applies, what does a good decision procedure look like for this kind of question? Meta-level.'
}

$script:HatOrder = @('white', 'red', 'black', 'yellow', 'green', 'blue')

function Build-SixHatsTasks {
    <#
    .SYNOPSIS
      Return the six hat tasks shaped for Invoke-FleetEnsembleTasks.

    .PARAMETER Question
      The user's question. Prefixed with each hat's preamble.

    .PARAMETER Providers
      Roster array. Rotated across the six hats (providers[i % count]).
      Must be non-empty.
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][string[]]$Providers
    )
    if (-not $Providers -or $Providers.Count -eq 0) {
        throw "Build-SixHatsTasks requires a non-empty provider roster."
    }
    $tasks = @()
    for ($i = 0; $i -lt $script:HatOrder.Count; $i++) {
        $hat = $script:HatOrder[$i]
        $preamble = $script:HatPreambles[$hat]
        $provider = $Providers[$i % $Providers.Count]
        # Single-line concatenation — no newlines, see HatPreambles note above.
        $prompt = "$preamble Question: $Question"
        $tasks += @{ label = $hat; provider = $provider; prompt = $prompt }
    }
    return $tasks
}

function Get-SixHatsOrder {
    <# Return the canonical hat ordering as a string[]. #>
    return $script:HatOrder
}
