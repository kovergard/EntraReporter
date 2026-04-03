<#
	.SYNOPSIS
	Retrieves all items from a paged Microsoft Graph endpoint by following @odata.nextLink.

	.DESCRIPTION
	Performs repeated GET calls to the provided Graph URI and collects results from each page. Appends all `value` arrays into a single output array. This supports Graph endpoints that return paged data.

	.PARAMETER Uri
	The initial Microsoft Graph URI to request (e.g. 'https://graph.microsoft.com/v1.0/users').

	.OUTPUTS
	System.Object[]
	An array of objects returned from Graph pages.

	.EXAMPLE
	Invoke-GraphPaged -Uri 'https://graph.microsoft.com/v1.0/users'

	Returns all users from the tenant by following pagination links.

	.NOTES
	Uses Invoke-MgGraphRequest to perform each request and expects standard Graph pagination (`@odata.nextLink`).
#>
function Invoke-GraphPaged {
	[CmdletBinding()]
	[OutputType([System.Object[]])]
	param(
		[Parameter(Mandatory)]
		[string]$Uri
	)
	$items = @()
	$next = $Uri
	while ($next) {
		$resp = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
		if ($resp.value) { $items += $resp.value }
		$next = $resp.'@odata.nextLink'
	}
	return , $items
}

