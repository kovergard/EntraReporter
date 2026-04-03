# Robust pagination helper
function Invoke-GraphPaged {
	param(
		[Parameter(Mandatory)][string] $Uri
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

