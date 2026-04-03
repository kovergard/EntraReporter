<#
	.SYNOPSIS
	Splits an array into multiple chunks of a specified size.

	.DESCRIPTION
	Takes an input array and divides it into smaller arrays (chunks). Each returned chunk is a fixed-size object[] (except the last chunk) and the function returns a collection of chunk arrays. Useful for batching operations.

	.PARAMETER InputObject
	The array of values to split into chunks. Cannot be null or empty.

	.PARAMETER ChunkSize
	The maximum number of items per chunk. Must be an integer greater than or equal to 1.

	.OUTPUTS
	System.Collections.Generic.List[object[]]
	A list of object arrays, where each array is a chunk from the original input.

	.EXAMPLE
	Split-ArrayIntoChunk -InputObject @(1,2,3,4,5) -ChunkSize 2
	
	Returns chunks: @(1,2), @(3,4), @(5)

	.NOTES
	Used by EntraReporter helpers for batching Graph requests.
#>
function Split-ArrayIntoChunk {
	[CmdletBinding()]
	[OutputType([System.Array])]
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
