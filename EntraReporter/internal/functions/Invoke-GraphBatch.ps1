<#
	.SYNOPSIS
	Executes a Microsoft Graph batch request and optionally fails on any non-success status code.

	.DESCRIPTION
	Sends a batch of individual Graph API requests in a single HTTP POST to reduce round-trips. Returns the full Graph batch response.

	.PARAMETER Requests
	An array of hashtables representing Graph batch requests. Each hashtable must include id, method, and url.

	.PARAMETER GraphVersion
	Graph API version to call (default: 'v1.0').

	.PARAMETER ThrowOnAnyError
	If specified, throws an exception when any response entry has HTTP status 400 or greater.

	.OUTPUTS
	System.Object (Graph batch response)

	.EXAMPLE
	$batch = @(
		@{ id = '1'; method = 'GET'; url = '/users' }
		@{ id = '2'; method = 'GET'; url = '/groups' }
	)
	Invoke-GraphBatch -Requests $batch -GraphVersion 'v1.0' -ThrowOnAnyError

	Performs the specified batch request against Microsoft Graph and throws if any individual request fails.

	.NOTES
	Used by EntraReporter internal routines to perform Graph batch calls.
#>
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

