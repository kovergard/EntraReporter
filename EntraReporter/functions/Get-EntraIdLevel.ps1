function Get-EntraIdLevel {
	[CmdletBinding()]
	param(
		# If set, include diagnostic details (enabled/assigned counts and SKU part numbers).
		[switch] $IncludeDetails
	)

	# Ensure we're using v1.0 for stability (this affects URL only, not the module profile).
	$skus = Invoke-GraphPaged -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -Verbose:$false

	# Defensive: if tenant has no SKUs (rare), treat as Free
	if (-not $skus -or $skus.Count -eq 0) {
		$result = [ordered]@{
			Level         = 'Free'
			IsP1Available = $false
			IsP2Available = $false
		}
		if ($IncludeDetails) {
			$result.P1EnabledCount = 0
			$result.P2EnabledCount = 0
			$result.P1AssignedCount = 0
			$result.P2AssignedCount = 0
			$result.P1SkuPartNumbers = @()
			$result.P2SkuPartNumbers = @()
		}
		return [PSCustomObject]$result
	}

	# Filter SKUs by service plans (provisioned and active)
	$p1Skus = $skus | Where-Object {
		$_.servicePlans | Where-Object {
			$_.servicePlanName -eq 'AAD_PREMIUM' -and $_.provisioningStatus -eq 'Success'
		}
	}
	$p2Skus = $skus | Where-Object {
		$_.servicePlans | Where-Object {
			$_.servicePlanName -eq 'AAD_PREMIUM_P2' -and $_.provisioningStatus -eq 'Success'
		}
	}

	# Enabled capacity (what you own)
	$p1Enabled = ($p1Skus | ForEach-Object { $_.prepaidUnits.enabled } | Measure-Object -Sum).Sum
	$p2Enabled = ($p2Skus | ForEach-Object { $_.prepaidUnits.enabled } | Measure-Object -Sum).Sum

	# Assigned units (how many are currently consumed)
	$p1Assigned = ($p1Skus | ForEach-Object { $_.consumedUnits } | Measure-Object -Sum).Sum
	$p2Assigned = ($p2Skus | ForEach-Object { $_.consumedUnits } | Measure-Object -Sum).Sum

	# Determine the “portal-equivalent” level
	$level = if ($p2Enabled -gt 0) { 'P2' }
	elseif ($p1Enabled -gt 0) { 'P1' }
	else { 'Free' }

	$result = [ordered]@{
		Level         = $level
		IsP1Available = ($p1Enabled -gt 0)
		IsP2Available = ($p2Enabled -gt 0)
	}

	if ($IncludeDetails) {
		$result.P1EnabledCount = [int]($p1Enabled | ForEach-Object { $_ } )
		$result.P2EnabledCount = [int]($p2Enabled | ForEach-Object { $_ } )
		$result.P1AssignedCount = [int]($p1Assigned | ForEach-Object { $_ } )
		$result.P2AssignedCount = [int]($p2Assigned | ForEach-Object { $_ } )
		$result.P1SkuPartNumbers = $p1Skus.skuPartNumber | Sort-Object -Unique
		$result.P2SkuPartNumbers = $p2Skus.skuPartNumber | Sort-Object -Unique
	}

	[PSCustomObject]$result
}

