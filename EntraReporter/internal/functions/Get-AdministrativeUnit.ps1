# Generate a list of all administrative units in the directory for resolving scope information in role assignments.
function Get-AdministrativeUnit {
	[CmdletBinding()]

	$results = @()

	# Get all administrative units from directory to avoid making multiple calls 
	$allAdministrativeUnits = Invoke-MgGraphRequest -Method GET -Uri 'v1.0/directory/administrativeUnits' -Verbose:$false | Select-Object -ExpandProperty value 
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