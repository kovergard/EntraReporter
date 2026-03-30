function Split-ArrayIntoChunks {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[object[]]$InputObject,

		[ValidateRange(1, [int]::MaxValue)]
		[int]$ChunkSize = 20
	)

	$items = @($InputObject)
	# Always return a collection object
	$result = New-Object System.Collections.Generic.List[object[]]

	if ($items.Count -gt 0) {
		for ($i = 0; $i -lt $items.Count; $i += $ChunkSize) {
			$end = [Math]::Min($i + $ChunkSize - 1, $items.Count - 1)
			[void]$result.Add(@($items[$i..$end]))   # ensure each chunk is an object[]
		}
	}

	# Emit the *collection* as a single object so callers get one wrapper
	, $result
}
