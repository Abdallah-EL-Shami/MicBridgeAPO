Set-StrictMode -Version Latest

function New-MBLegacyCleanupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Audit,
        [Parameter(Mandatory)][string]$InstallDirectory
    )

    # Planning only. This function never writes Registry, files, ACLs, or services.
    $installFull = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $items = [Collections.Generic.List[object]]::new()
    $blockers = [Collections.Generic.List[string]]::new()

    if (-not $Audit.IsReadOnly) {
        $blockers.Add('Audit result is not explicitly read-only.')
    }
    if ($Audit.CleanupAllowed -ne $false) {
        $blockers.Add('Audit does not explicitly deny direct cleanup.')
    }
    if ($Audit.OriginalWindowsBaselineProven -ne $false) {
        $blockers.Add('Unexpected baseline assertion; require manual review.')
    }
    if ($Audit.Outcome -eq 'ReviewRequired') {
        $blockers.Add('Legacy audit contains ambiguous, foreign, missing, or invalid evidence.')
    }

    foreach ($finding in @($Audit.Findings)) {
        $classification = [string]$finding.Classification
        $path = [string]$finding.Path
        $action = 'Preserve'
        $reason = 'No independently validated ownership manifest exists for this item.'

        if ($classification -in @('Absent')) {
            $action = 'NoOp'
            $reason = 'Item is absent.'
        }
        elseif ($classification -eq 'MicBridgeCandidate') {
            $server = [string]$finding.ServerPath
            $serverFull = $null
            try {
                if (-not [string]::IsNullOrWhiteSpace($server)) {
                    $serverFull = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($server.Trim('"')))
                }
            } catch {}

            if ($serverFull -and
                $serverFull.StartsWith($installFull + '\', [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($serverFull) -ieq 'MicBridgeAPO.dll' -and
                $finding.Sha256 -match '^[A-Fa-f0-9]{64}$') {
                $action = 'CandidateForReviewedRemoval'
                $reason = 'Exact product CLSID server path is under the fixed install directory and has a recorded file hash; shared references and registry-tree contents still require independent validation before execution.'
            } else {
                $blockers.Add("Registration lacks a canonical product-owned server path: $path")
                $reason = 'Server path or hash does not meet the narrow product-candidate rule.'
            }
        }
        elseif ($classification -in @('MicBridgeBinaryCandidate','MicBridgeSupportFileCandidate')) {
            $blockers.Add("File ownership is not proven by a signed/known manifest: $path")
            $reason = 'Filename/location alone is insufficient to authorize deletion.'
        }
        elseif ($classification -in @('MicBridgeRecoveryEvidence','PreserveDataFile','ReparsePointPreserved')) {
            $reason = 'Recovery evidence, user data, or reparse point is preserved by policy.'
        }
        elseif ($classification -notin @('Absent')) {
            $blockers.Add("Unresolved or foreign item requires preservation: $path [$classification]")
        }

        $items.Add([pscustomobject]@{
            Kind = [string]$finding.Kind
            Name = [string]$finding.Name
            Path = $path
            Classification = $classification
            ProposedAction = $action
            Reason = $reason
            Sha256 = [string]$finding.Sha256
        })
    }

    $canProceed = ($blockers.Count -eq 0)
    [pscustomobject]@{
        SchemaVersion = 1
        IsReadOnly = $true
        CanProceedToCleanupReview = $canProceed
        CleanupExecutionAllowed = $false
        InstallAllowed = $false
        Items = @($items)
        Blockers = @($blockers)
        Warnings = @(
            'This is a review plan, not an executable cleanup authorization.',
            'No registry or file mutation is performed.',
            'Do not restore old backups as a Windows baseline.'
        )
    }
}

Export-ModuleMember -Function New-MBLegacyCleanupPlan
