function Invoke-GraphBatch {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[hashtable[]]$Requests,

		[Parameter()]
		[string]$GraphVersion = 'v1.0',

		[Parameter()]
		[switch]$ThrowOnAnyError
	)

	$uri = "$GraphVersion/`$batch"
	$body = @{ requests = $Requests }

	$resp = Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -Verbose:$false

	if ($ThrowOnAnyError) {
		$errors = $resp.responses | Where-Object { $_.status -ge 400 }
		if ($errors) {
			$codes = ($errors | ForEach-Object { "$($_.id):$($_.status)" }) -join ', '
			throw "One or more batch requests failed: $codes"
		}
	}
	return $resp
}

