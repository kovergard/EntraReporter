<#
	.SYNOPSIS
	Retrieves membership role assignment or eligibility schedules for multiple Azure AD groups using batched Graph API requests.

	.DESCRIPTION
	Fetches PIM group membership schedules for a collection of group IDs. Supports both active assignments and eligible
	memberships. The function splits the input group IDs into chunks of 20 to optimize Graph API batch requests and handles
	error recovery per chunk to avoid total failure if some group IDs fail.

	.PARAMETER GroupId
	One or more Azure AD group IDs for which to retrieve schedules. The function will batch these requests for efficiency.

	.PARAMETER State
	The type of schedule to retrieve: 'Assigned' for active membership schedules, or 'Eligible' for eligible membership schedules.

	.OUTPUTS
	PSCustomObject array containing schedule records with principal expansion. Each record includes properties like principalId,
	groupId, scheduleInfo, and principal (expanded user/group details).

	.EXAMPLE
	Get-EntraIdGroupScheduleBatch -GroupId @('group-id-1', 'group-id-2') -State 'Assigned'
	
	Retrieves active membership assignment schedules for the specified groups.

	.NOTES
	Requires an active Microsoft Graph connection. Uses batched requests (20 IDs per batch) to optimize API throughput.
	Errors on individual chunks are logged as warnings but do not halt the overall operation.

#>
function Get-EntraIdGroupScheduleBatch {
	param(
		# Array of Azure AD group IDs to fetch schedules for
		[Parameter(Mandatory = $true)]
		[string[]]
		$GroupId,

		# Type of schedule: 'Assigned' for active, 'Eligible' for eligible memberships
		[Parameter(Mandatory = $true)]
		[ValidateSet('Assigned', 'Eligible')]
		[string]
		$State
	)

	# Select the appropriate Graph API endpoint based on the requested state
	switch ($State) {
		'Assigned' {
			# Endpoint for active group membership assignments
			$urlTemplate = "/identityGovernance/privilegedAccess/group/assignmentSchedules?`$filter=groupId eq '{Id}'&`$expand=principal"
		}
		'Eligible' {
			# Endpoint for eligible group membership schedules
			$urlTemplate = "/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$filter=groupId eq '{Id}'&`$expand=principal"
		}
	}

	# Split the GroupId array into chunks of 20 for batch processing (Graph API batch limit optimization)
	$chunks = Split-ArrayIntoChunks -InputObject $GroupId -ChunkSize 20

	# Process each chunk through the Graph batch API and collect all responses
	$allResponses = foreach ($chunk in $chunks) {
		try {
			# Build batch request objects for each group ID in the current chunk
			$requests = foreach ($id in $chunk) {
				@{
					id     = $id
					method = 'GET'
					url    = $urlTemplate.Replace('{Id}', $id)
				}
			}
			# Submit batch request for this chunk and retrieve responses
			Invoke-GraphBatch -Requests $requests -ThrowOnAnyError
		}
		catch {
			# Log warning if chunk processing fails, but continue with remaining chunks
			Write-Warning ("Failed to process chunk of group IDs '{0}': {1}" -f ($chunk -join ', '), $_.Exception.Message)
		}
	}

	# Extract the actual schedule data from batch responses and flatten the results
	$allResponses.responses | ForEach-Object { $_.body.value }
}

