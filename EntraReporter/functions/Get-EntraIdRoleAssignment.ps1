<#

TODO: Comment based help

#>
function Get-EntraIdRoleAssignment {
	[CmdletBinding()]
	param(
		[Parameter()]
		[string[]]
		$RoleName
	)

	# TODO: Support tenants with without PIM / Privileged Access enabled (currently the command relies on fetching role assignments via the privileged access API, which only returns results for tenants with PIM / Privileged Access enabled)

	#region Configuiration

	# TODO: Move to module initialization when prototyping is done

	$ErrorActionPreference = 'Stop'     # Always stop on errors

	#endregion

	#region Private functions
	# TODO: Move these to separate files when prototyping is done


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

	#endregion

	#region Public functions
	# TODO: Move these to separate files when prototyping is done

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

	function Get-EntraIdLevel {
		[CmdletBinding()]
		param(
			# If set, include diagnostic details (enabled/assigned counts and SKU part numbers).
			[switch] $IncludeDetails
		)

		# Ensure we're using v1.0 for stability (this affects URL only, not the module profile).
		$skus = Invoke-GraphPaged -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus' -Verbose:$false

		# Defensive: if tenant has no SKUs (rare), treat as Free
		if (-not $skus -or $skus.Count -eq 0) {
			$result = [ordered]@{
				Level         = 'Free'
				IsP1Available = $false
				IsP2Available = $false
			}
			if ($IncludeDetails) {
				$result.P1EnabledCount = 0
				$result.P2EnabledCount = 0
				$result.P1AssignedCount = 0
				$result.P2AssignedCount = 0
				$result.P1SkuPartNumbers = @()
				$result.P2SkuPartNumbers = @()
			}
			return [PSCustomObject]$result
		}

		# Filter SKUs by service plans (provisioned and active)
		$p1Skus = $skus | Where-Object {
			$_.servicePlans | Where-Object {
				$_.servicePlanName -eq 'AAD_PREMIUM' -and $_.provisioningStatus -eq 'Success'
			}
		}
		$p2Skus = $skus | Where-Object {
			$_.servicePlans | Where-Object {
				$_.servicePlanName -eq 'AAD_PREMIUM_P2' -and $_.provisioningStatus -eq 'Success'
			}
		}

		# Enabled capacity (what you own)
		$p1Enabled = ($p1Skus | ForEach-Object { $_.prepaidUnits.enabled } | Measure-Object -Sum).Sum
		$p2Enabled = ($p2Skus | ForEach-Object { $_.prepaidUnits.enabled } | Measure-Object -Sum).Sum

		# Assigned units (how many are currently consumed)
		$p1Assigned = ($p1Skus | ForEach-Object { $_.consumedUnits } | Measure-Object -Sum).Sum
		$p2Assigned = ($p2Skus | ForEach-Object { $_.consumedUnits } | Measure-Object -Sum).Sum

		# Determine the “portal-equivalent” level
		$level = if ($p2Enabled -gt 0) { 'P2' }
		elseif ($p1Enabled -gt 0) { 'P1' }
		else { 'Free' }

		$result = [ordered]@{
			Level         = $level
			IsP1Available = ($p1Enabled -gt 0)
			IsP2Available = ($p2Enabled -gt 0)
		}

		if ($IncludeDetails) {
			$result.P1EnabledCount = [int]($p1Enabled | ForEach-Object { $_ } )
			$result.P2EnabledCount = [int]($p2Enabled | ForEach-Object { $_ } )
			$result.P1AssignedCount = [int]($p1Assigned | ForEach-Object { $_ } )
			$result.P2AssignedCount = [int]($p2Assigned | ForEach-Object { $_ } )
			$result.P1SkuPartNumbers = $p1Skus.skuPartNumber | Sort-Object -Unique
			$result.P2SkuPartNumbers = $p2Skus.skuPartNumber | Sort-Object -Unique
		}

		[PSCustomObject]$result
	}


	#endregion


	#region Internal functions 

	function Resolve-AssignmentWindow {
		param(
			[Nullable[datetime]] $PrincipalStart,
			[Nullable[datetime]] $PrincipalEnd,
			[Nullable[datetime]] $UserStart,
			[Nullable[datetime]] $UserEnd
		)

		if ($null -eq $UserEnd -and $null -eq $PrincipalEnd) {
			return [pscustomobject]@{
				Start       = $null
				End         = $null
				IsPermanent = $true
			}
		}

		if ($null -eq $PrincipalEnd) {
			return [pscustomobject]@{
				Start       = $UserStart
				End         = $UserEnd
				IsPermanent = $false
			}
		}

		if ($null -eq $UserEnd) {
			return [pscustomobject]@{
				Start       = $PrincipalStart
				End         = $PrincipalEnd
				IsPermanent = $false
			}
		}

		# Intersection logic
		return [pscustomobject]@{
			Start       = if ($PrincipalStart -gt $UserStart) { $PrincipalStart } else { $UserStart }
			End         = if ($PrincipalEnd -lt $UserEnd) { $PrincipalEnd } else { $UserEnd }
			IsPermanent = $false
		}
	}

	function New-RoleAssignmentEntry {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)] [string]$RoleId,
			[Parameter(Mandatory)] [string]$RoleName,
			[Parameter(Mandatory)] [string]$PrincipalId,
			[Parameter(Mandatory)] [string]$PrincipalDisplayName,
			[Parameter(Mandatory)] [string]$AssignmentType,
			[Parameter(Mandatory)] [string]$Scope,
			[Parameter(Mandatory)] [string]$PrincipalState,
			[Nullable[datetime]] $PrincipalStartTime,
			[Nullable[datetime]] $PrincipalEndTime,
			[Parameter(Mandatory)] [string]$UserId,
			[Parameter(Mandatory)] [string]$UserDisplayName,
			[Parameter(Mandatory)] [string]$UserPrincipalName,
			[Parameter(Mandatory)] [string]$UserState,
			[Nullable[datetime]] $UserStartTime,
			[Nullable[datetime]] $UserEndTime
		)

		# Resolve effective assignment window by calculating the intersection of the principal and user assignment windows. If either of the windows is permanent (i.e. has no end time), the effective window will be determined by the other window. If both windows are permanent, the effective window will also be permanent.
		$window = Resolve-AssignmentWindow -PrincipalStart $PrincipalStartTime -PrincipalEnd $PrincipalEndTime -UserStart $UserStartTime -UserEnd $UserEndTime

		# Determine effective state. If both principal and user are assigned, the effective state is assigned. In all other cases (e.g. one of them is eligible or both are eligible), the effective state is eligible.
		$effectiveState = if ($PrincipalState -eq 'Assigned' -and $UserState -eq 'Assigned') {
			'Assigned'
		}
		else {
			'Eligible'
		}

		# Emit a single entry for the combination of principal and user with the resolved effective assignment window and state. 
		[PSCustomObject]@{
			RoleId               = $RoleId
			RoleName             = $RoleName
			PrincipalId          = $PrincipalId
			PrincipalDisplayName = $PrincipalDisplayName
			AssignmentType       = $AssignmentType
			Scope                = $Scope
			PrincipalState       = $PrincipalState
			PrincipalStartTime   = $PrincipalStartTime
			PrincipalEndTime     = $PrincipalEndTime
			UserId               = $UserId
			UserDisplayName      = $UserDisplayName
			UserPrincipalName    = $UserPrincipalName
			UserState            = $UserState
			UserStartTime        = $UserStartTime
			UserEndTime          = $UserEndTime
			EffectiveState       = $effectiveState
			EffectiveStartTime   = $window.Start
			EffectiveEndTime     = $window.End
			IsPermanent          = $window.IsPermanent
		}
	}

	function Resolve-RoleAssignedGroup {
		param(
			[Parameter(Mandatory = $true)]
			[psobject]
			$Schedule,

			[Parameter(Mandatory = $true)]
			[ValidateSet('Assigned', 'Eligible')]
			[string]
			$GroupState,

			[Parameter(Mandatory = $true)]
			[ValidateSet('Assigned', 'Eligible')]
			[string]
			$UserState
		)

		if ($UserState -eq 'Assigned') {
			$scheduleEntries = $script:groupAssignmentSchedules | Where-Object { $_.groupId -eq $principal.id } 
		}
		else {
			$scheduleEntries = $script:groupEligibilitySchedules | Where-Object { $_.groupId -eq $principal.id } 
		}

		foreach ($scheduleEntry in $scheduleEntries ) {
			$roleEntrySplat = @{
				RoleId               = $Schedule.roleDefinitionId
				RoleName             = $Schedule.roleDefinition.displayName
				PrincipalId          = $Schedule.principal.id
				PrincipalDisplayName = $Schedule.principal.displayName
				AssignmentType       = 'Group'
				Scope                = $Schedule.directoryScopeId
				PrincipalState       = $GroupState
				PrincipalStartTime   = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.startDateTime } else { $null }
				PrincipalEndTime     = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.expiration.endDateTime } else { $null }
				UserId               = $scheduleEntry.principalId
				UserDisplayName      = $scheduleEntry.principal.displayName
				UserPrincipalName    = $scheduleEntry.principal.userPrincipalName
				UserState            = $UserState
				UserStartTime        = if ($scheduleEntry.scheduleInfo.expiration.endDateTime) { $scheduleEntry.scheduleInfo.startDateTime } else { $null }
				UserEndTime          = if ($scheduleEntry.scheduleInfo.expiration.endDateTime) { $scheduleEntry.scheduleInfo.expiration.endDateTime } else { $null }
			}
			New-RoleAssignmentEntry @roleEntrySplat
		}
	}

	function Resolve-EntraIDRoleSchedule {
		param(
			[Parameter(Mandatory = $true)]
			[psobject]
			$Schedule,

			[Parameter(Mandatory = $true)]
			[ValidateSet('Assigned', 'Eligible')]
			[string]
			$State
		)

		# Resolve principal to allow for individual handling of user vs group principals (e.g. resolving group members for group principals since Graph API does not currently provide a way to see effective role assignments for group members)
		$principal = $Schedule.principal

		if ($principal.'@odata.type' -eq '#microsoft.graph.user') {
			$roleEntrySplat = @{
				RoleId               = $Schedule.roleDefinitionId
				RoleName             = $Schedule.roleDefinition.displayName
				PrincipalId          = $Schedule.principal.id
				PrincipalDisplayName = $Schedule.principal.displayName
				AssignmentType       = 'User'
				Scope                = $Schedule.directoryScopeId
				PrincipalState       = $State
				PrincipalStartTime   = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.startDateTime } else { $null }
				PrincipalEndTime     = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.expiration.endDateTime } else { $null }
				UserId               = $Schedule.principalId
				UserDisplayName      = $Schedule.principal.displayName
				UserPrincipalName    = $Schedule.principal.userPrincipalName
				UserState            = $State
				UserStartTime        = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.startDateTime } else { $null }
				UserEndTime          = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.expiration.endDateTime } else { $null }
			}
			New-RoleAssignmentEntry @roleEntrySplat
		}
		elseif ($principal.'@odata.type' -eq '#microsoft.graph.group') {
			Resolve-RoleAssignedGroup -Schedule $Schedule -GroupState $State -UserState 'Assigned'
			Resolve-RoleAssignedGroup -Schedule $Schedule -GroupState $State -UserState 'Eligible'
		}
		else {
			Write-Warning "Principal with ID '$($principal.id)' is of type $($principal.'@odata.type'), which is currently not supported by the command. Skipping entry."
			continue
		}
	}

	#endregion Helper Functions

	#region MAIN

	#
	## Connect-mgGraph -Scopes 'RoleManagement.Read.Directory','RoleEligibilitySchedule.Read.Directory','PrivilegedEligibilitySchedule.Read.AzureADGroup', 'PrivilegedAssignmentSchedule.Read.AzureADGroup', 'GroupMember.Read.All'
	# Current:
	## Connect-mgGraph -Scopes 'RoleEligibilitySchedule.Read.Directory','PrivilegedEligibilitySchedule.Read.AzureADGroup', 'PrivilegedAssignmentSchedule.Read.AzureADGroup'
	#

	if (!(Test-GraphConnection)) {
		throw 'No active connection to Microsoft Graph. Run Connect-MgGraph to sign in and then retry.'
	}

	Get-EntraIdLevel -IncludeDetails | ConvertTo-Json -Depth 5 | Write-Verbose


	$timer = [Diagnostics.Stopwatch]::StartNew()
	$activityName = 'Fetching Entra ID role assignments'

	# Fetch all role schedules, assigned and eligible.
	Write-Progress -Activity $activityName -Status 'Fetching assigned role schedules' -PercentComplete 20
	$roleAssignmentSchedules = Invoke-MgGraphRequest -Method GET -Uri "v1.0/roleManagement/directory/roleAssignmentSchedules?`$filter=assignmentType eq 'Assigned'&`$expand=principal,roleDefinition" -Verbose:$false | Select-Object -ExpandProperty value 
	Write-Progress -Activity $activityName -Status 'Fetching eligible role schedules' -PercentComplete 40
	$roleEligibilitySchedules = Invoke-MgGraphRequest -Method GET -Uri "v1.0/roleManagement/directory/roleEligibilitySchedules?`$expand=principal,roleDefinition" -Verbose:$false | Select-Object -ExpandProperty value


	# TODO: Test for nested groups???

	# TODO: Test with scopes other than the directory (e.g. administrative units)

	# TODO: Test with Azure RBAC roles (if possible - not sure if these are returned by the API when listing directory role assignments?)

	# If Rolename has been specified, filter out any assigments not in the specified role(s).
	if ($RoleName) {
		$roleAssignmentSchedules = $roleAssignmentSchedules | Where-Object { $_.roleDefinition.displayName -in $RoleName }
		$roleEligibilitySchedules = $roleEligibilitySchedules | Where-Object { $_.roleDefinition.displayName -in $RoleName }
	}

	# Extract unique group IDs from all role schedules for prefetching group schedule information in bulk to reduce number of API calls later on.
	$groupIds = @()
	$groupIds += $roleAssignmentSchedules | Select-Object -ExpandProperty principal | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } | Select-Object -ExpandProperty Id
	$groupIds += $roleEligibilitySchedules | Select-Object -ExpandProperty principal | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } | Select-Object -ExpandProperty Id
	$groupIds = $groupIds | Select-Object -Unique

	# Prefetch group schedules for all groups used groups
	Write-Progress -Activity $activityName -Status 'Fetching assigned group schedules' -PercentComplete 60
	$script:groupAssignmentSchedules = Get-EntraIdGroupScheduleBatch -GroupId $groupIds -State 'Assigned' 
	Write-Progress -Activity $activityName -Status 'Fetching eligible group schedules' -PercentComplete 80
	$script:groupEligibilitySchedules = Get-EntraIdGroupScheduleBatch -GroupId $groupIds -State 'Eligible' 

	Write-Progress -Activity $activityName -Status 'Consolidating results' -PercentComplete 95
	$resolvedGroupSchedules = @()
	$resolvedGroupSchedules += foreach ($schedule in $roleAssignmentSchedules) {
		Resolve-EntraIDRoleSchedule -Schedule $schedule -State 'Assigned'
	}
	$resolvedGroupSchedules += foreach ($schedule in $roleEligibilitySchedules) {
		Resolve-EntraIDRoleSchedule -Schedule $schedule -State 'Eligible'
	}

	Write-Progress -Activity $activityName -Completed

	$resolvedGroupSchedules | Sort-Object -Property RoleName, UserDisplayName

	Write-Verbose "Total execution time: $($timer.Elapsed.TotalSeconds) seconds"
}
#endregion