function Get-EntraIdGroupScheduleBatch {
	param(
		[Parameter(Mandatory = $true)]
		[string[]]
		$GroupId,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Assigned', 'Eligible')]
		[string]
		$State
	)

	switch ($State) {
		'Assigned' {
			$urlTemplate = "/identityGovernance/privilegedAccess/group/assignmentSchedules?`$filter=groupId eq '{Id}'&`$expand=principal"
		}
		'Eligible' {
			$urlTemplate = "/identityGovernance/privilegedAccess/group/eligibilitySchedules?`$filter=groupId eq '{Id}'&`$expand=principal"
		}
	}
	
	# Split the GroupId array into chunks of 20
	$chunks = Split-ArrayIntoChunks -InputObject $GroupId -ChunkSize 20

	$allResponses = foreach ($chunk in $chunks) {
		try {
			$requests = foreach ($id in $chunk) {
				@{
					id     = $id
					method = 'GET'
					url    = $urlTemplate.Replace('{Id}', $id)
				}
			}
			Invoke-GraphBatch -Requests $requests -ThrowOnAnyError
		}
		catch {
			Write-Warning ("Failed to process chunk of group IDs '{0}': {1}" -f ($chunk -join ', '), $_.Exception.Message)
		}
	}

	$allResponses.responses | ForEach-Object { $_.body.value }
}

