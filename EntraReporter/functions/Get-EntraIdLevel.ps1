<#
	.SYNOPSIS
	Determines the Entra ID license level (Free, P1, or P2) for the connected tenant.

	.DESCRIPTION
	Queries the tenant's Microsoft Graph SKU information to determine which premium Entra ID licenses are enabled.
	Returns the highest available license level (P2 > P1 > Free). Optionally includes detailed information about
	provisioned and consumed license units.

	.PARAMETER IncludeDetails
	When specified, includes detailed license counts (enabled and assigned units) and SKU part numbers for P1 and P2 plans.

	.OUTPUTS
	PSCustomObject with properties:
		- Level: 'Free', 'P1', or 'P2' (highest available)
		- IsP1Available: $true if P1 is licensed and active
		- IsP2Available: $true if P2 is licensed and active
		- P1EnabledCount: (with -IncludeDetails) Total P1 licenses enabled
		- P2EnabledCount: (with -IncludeDetails) Total P2 licenses enabled
		- P1AssignedCount: (with -IncludeDetails) Currently consumed P1 units
		- P2AssignedCount: (with -IncludeDetails) Currently consumed P2 units
		- P1SkuPartNumbers: (with -IncludeDetails) Unique P1 SKU part numbers
		- P2SkuPartNumbers: (with -IncludeDetails) Unique P2 SKU part numbers

	.EXAMPLE
	Get-EntraIdLevel

	Returns the license level for the tenant.

	.EXAMPLE
	Get-EntraIdLevel -IncludeDetails
	
	Returns the license level along with detailed unit and SKU information.

	.NOTES
	Requires an active Microsoft Graph connection. Uses v1.0 subscription API endpoint.

#>
function Get-EntraIdLevel {
	[CmdletBinding()]
	param(
		# When set, includes enabled/assigned counts and SKU part numbers in output
		[switch] $IncludeDetails
	)

	# Fetch all subscribed SKUs from Graph API using v1.0 endpoint for stability
	$skus = Invoke-GraphPaged -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -Verbose:$false

	# Handle edge case: if tenant has no SKUs (rare), default to Free tier
	if (-not $skus -or $skus.Count -eq 0) {
		# No SKUs found; initialize result with Free tier
		$result = [ordered]@{
			Level         = 'Free'
			IsP1Available = $false
			IsP2Available = $false
		}
		if ($IncludeDetails) {
			# Add detailed counts and SKU info (all zeros/empty for Free tier)
			$result.P1EnabledCount = 0
			$result.P2EnabledCount = 0
			$result.P1AssignedCount = 0
			$result.P2AssignedCount = 0
			$result.P1SkuPartNumbers = @()
			$result.P2SkuPartNumbers = @()
		}
		return [PSCustomObject]$result
	}

	# Identify P1 and P2 licensed SKUs (filter by service plan and provisioning status)
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

	# Sum total enabled licenses (capacity purchased for each tier)
	$p1Enabled = ($p1Skus | ForEach-Object { $_.prepaidUnits.enabled } | Measure-Object -Sum).Sum
	$p2Enabled = ($p2Skus | ForEach-Object { $_.prepaidUnits.enabled } | Measure-Object -Sum).Sum

	# Sum consumed/assigned units (how many are currently in use)
	$p1Assigned = ($p1Skus | ForEach-Object { $_.consumedUnits } | Measure-Object -Sum).Sum
	$p2Assigned = ($p2Skus | ForEach-Object { $_.consumedUnits } | Measure-Object -Sum).Sum

	# Determine the effective license level: P2 (highest) > P1 > Free
	$level = if ($p2Enabled -gt 0) { 'P2' }
	elseif ($p1Enabled -gt 0) { 'P1' }
	else { 'Free' }

	# Build the result object with availability flags
	$result = [ordered]@{
		Level         = $level
		IsP1Available = ($p1Enabled -gt 0)
		IsP2Available = ($p2Enabled -gt 0)
	}

	if ($IncludeDetails) {
		# Convert sums to int and populate unit counts
		$result.P1EnabledCount = [int]($p1Enabled | ForEach-Object { $_ } )
		$result.P2EnabledCount = [int]($p2Enabled | ForEach-Object { $_ } )
		$result.P1AssignedCount = [int]($p1Assigned | ForEach-Object { $_ } )
		$result.P2AssignedCount = [int]($p2Assigned | ForEach-Object { $_ } )
		# Extract and deduplicate SKU part numbers for reporting
		$result.P1SkuPartNumbers = $p1Skus.skuPartNumber | Sort-Object -Unique
		$result.P2SkuPartNumbers = $p2Skus.skuPartNumber | Sort-Object -Unique
	}

	# Return the result as a PowerShell custom object with all properties
	[PSCustomObject]$result
}

