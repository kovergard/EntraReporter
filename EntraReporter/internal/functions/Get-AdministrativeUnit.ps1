<#
	.SYNOPSIS
	Returns a list of Azure AD administrative units (plus the root directory scope) formatted for EntraReporter.

	.DESCRIPTION
	Retrieves all administrative units from Microsoft Graph using Invoke-MgGraphRequest and converts each item into a PSCustomObject with directoryScopeId and displayName.

	.PARAMETER None
	This cmdlet does not take any parameters.

	.OUTPUTS
	System.Management.Automation.PSCustomObject
	Contains properties:
	- directoryScopeId: String, e.g. '/administrativeUnits/{id}' or '/'
	- displayName: String, administrative unit display name or 'Directory'

	.EXAMPLE
	Get-AdministrativeUnit

	Returns all administrative units and the root directory scope.

	.NOTES
	Part of EntraReporter internal functions.
#>
function Get-AdministrativeUnit {
	[CmdletBinding()]

	$results = @()

	# Get all administrative units from directory to avoid making multiple calls
	$allAdministrativeUnits = (Invoke-MgGraphRequest -Method GET -Uri 'v1.0/directory/administrativeUnits' -Verbose:$false)['value']
	foreach ($adminUnit in $allAdministrativeUnits) {
		$results += [pscustomobject] @{
			directoryScopeId = "/administrativeUnits/$($adminUnit.id)"
			displayName      = $adminUnit.displayName
		}
	}
	$results += [pscustomobject] @{
		directoryScopeId = '/'
		displayName      = 'Directory'
	}

	return $results
}