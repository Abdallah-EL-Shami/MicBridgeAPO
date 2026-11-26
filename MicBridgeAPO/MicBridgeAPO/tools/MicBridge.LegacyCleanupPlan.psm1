Set-StrictMode -Version Latest

function New-MBLegacyCleanupPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Audit,
        [Parameter(Mandatory)][string]$InstallDirectory
    )

    # Read-only planning only. Never mutates registry, files, ACLs, or services.
    $installFull = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $items = [Collections.Generic.List[object]]::new()
    $blockers = [Collections.Generic.List[string]]::new()

    if (-not $Audit.IsReadOnly) { $blockers.Add('Audit is not explicitly read-only.') }
    if ($Audit.CleanupAllowed -ne $false) { $blockers.Add('Audit does not explicitly deny direct cleanup.') }
    if ($Audit.OriginalWindowsBaselineProven -ne $false) { $blockers.Add('Original Windows baseline must not be assumed.') }
    if ($Audit.Outcome -eq 'ReviewRequired') { $blockers.Add('Ambiguous or invalid audit evidence blocks cleanup review.') }

    foreach ($finding in @($Audit.Findings)) {
        $classification = [string]$finding.Classification
        $path = [string]$finding.Path
        $action = 'Preserve'
        $reason = 'Ownership is not independently established; preserve this item.'

        if ($classification -eq 'Absent') {
            $action = 'NoOp'
            $reason = 'Item is absent.'
        }
        elseif ($classification -eq 'MicBridgeCandidate') {
            $serverFull = $null
            $serverHashValid = $false
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$finding.ServerPath)) {
                    $serverFull = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$finding.ServerPath).Trim('"')))
                }
                if ($serverFull -and (Test-Path -LiteralPath $serverFull -PathType Leaf)) {
                    $serverItem = Get-Item -LiteralPath $serverFull -Force -ErrorAction Stop
                    if (($serverItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and [string]$finding.Sha256 -match '^[A-Fa-f0-9]{64}$') {
                        $actualHash = (Get-FileHash -LiteralPath $serverFull -Algorithm SHA256 -ErrorAction Stop).Hash
                        $serverHashValid = $actualHash.Equals([string]$finding.Sha256,[StringComparison]::OrdinalIgnoreCase)
                    }
                }
            } catch {}
            if ($serverFull -and $serverFull.StartsWith($installFull + '\',[StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($serverFull) -ieq 'MicBridgeAPO.dll' -and $serverHashValid) {
                $action = 'CandidateForReviewedRemoval'
                $reason = 'Verified product server path and current file hash qualify for human review only; shared registration ownership remains unproven.'
            } else {
                $blockers.Add("Registration lacks a verified product server path: $path")
                $reason = 'Registration path or current file hash does not meet the narrow review rule.'
            }
        }
        elseif ($classification -eq 'MicBridgeBinaryCandidate') {
            $binaryFull = $null
            $binaryHashValid = $false
            try {
                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    $binaryFull = [IO.Path]::GetFullPath($path)
                }
                if ($binaryFull -and (Test-Path -LiteralPath $binaryFull -PathType Leaf)) {
                    $binaryItem = Get-Item -LiteralPath $binaryFull -Force -ErrorAction Stop
                    if (($binaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
                        [string]$finding.Sha256 -match '^[A-Fa-f0-9]{64}$') {
                        $currentBinaryHash = (Get-FileHash -LiteralPath $binaryFull -Algorithm SHA256 -ErrorAction Stop).Hash
                        $binaryHashValid = $currentBinaryHash.Equals([string]$finding.Sha256,[StringComparison]::OrdinalIgnoreCase)
                    }
                }
            } catch {}
            if ($binaryFull -and
                $binaryFull.StartsWith($installFull + '\',[StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($binaryFull) -ieq 'MicBridgeAPO.dll' -and
                $binaryHashValid) {
                $action = 'CandidateForReviewedRemoval'
                $reason = 'Canonical product DLL path and matching current SHA-256 qualify for human review only; this does not prove ownership or authorize removal.'
            } else {
                $blockers.Add("Product binary lacks a canonical install path or matching current hash: $path")
                $reason = 'Path, filename, reparse-point status, or current hash does not meet the narrow review-candidate rule.'
            }
        }
        elseif ($classification -eq 'MicBridgeSupportFileCandidate') {
            $blockers.Add("Support-file ownership is not proven by a signed/known manifest: $path")
            $reason = 'Filename/location alone is insufficient to authorize deletion.'
        }
        elseif ($classification -in @('MicBridgeRecoveryEvidence','PreserveDataFile','ReparsePointPreserved')) {
            $reason = 'Recovery evidence, user data, or reparse point is preserved by policy.'
        }
        else {
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

    [pscustomobject]@{
        SchemaVersion = 1
        IsReadOnly = $true
        InstallDirectory = $installFull
        CanProceedToCleanupReview = ($blockers.Count -eq 0)
        CleanupExecutionAllowed = $false
        InstallAllowed = $false
        Items = @($items)
        Blockers = @($blockers)
        Warnings = @(
            'This is a review plan, not executable cleanup authorization.',
            'No registry, file, ACL, service, or endpoint mutation is performed.',
            'Never restore old backups as a Windows baseline.'
        )
    }
}

Export-ModuleMember -Function New-MBLegacyCleanupPlan
