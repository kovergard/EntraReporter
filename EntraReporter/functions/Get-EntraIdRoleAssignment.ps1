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
			PSTypeName           = 'EntraReporter.RoleAssignment'
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
				Scope                = $administrativeUnits | Where-Object { $_.directoryScopeId -eq $Schedule.directoryScopeId } | Select-Object -ExpandProperty displayName
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
				Scope                = $administrativeUnits | Where-Object { $_.directoryScopeId -eq $Schedule.directoryScopeId } | Select-Object -ExpandProperty displayName
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

	#endregion Internal Functions

	#region MAIN

	#
	## Connect-MgGraph -Scopes 'RoleManagement.Read.Directory','RoleEligibilitySchedule.Read.Directory','PrivilegedEligibilitySchedule.Read.AzureADGroup', 'PrivilegedAssignmentSchedule.Read.AzureADGroup', 'GroupMember.Read.All'
	
	# Current:
	## Connect-MgGraph -Scopes 'RoleEligibilitySchedule.Read.Directory','PrivilegedEligibilitySchedule.Read.AzureADGroup', 'PrivilegedAssignmentSchedule.Read.AzureADGroup'
	#

	# Always stop on errors to avoid emitting incomplete data. Errors should be handled at the command level to allow for more granular error handling (e.g. skipping individual entries that fail to resolve rather than failing the entire command).
	$ErrorActionPreference = 'Stop'     

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

	# If Rolename has been specified, filter out any assigments not in the specified role(s).
	if ($RoleName) {
		$roleAssignmentSchedules = $roleAssignmentSchedules | Where-Object { $_.roleDefinition.displayName -in $RoleName }
		$roleEligibilitySchedules = $roleEligibilitySchedules | Where-Object { $_.roleDefinition.displayName -in $RoleName }
	}

	# If any scopes are used in the role schedules (i.e. scope is not just the entire directory), fetch information about the scopes to allow for better reporting (e.g. resolving administrative unit names). 
	Write-Progress -Activity $activityName -Status 'Fetching scope information' -PercentComplete 60
	$scopeIds = @()
	$scopeIds += $roleAssignmentSchedules | Select-Object -ExpandProperty directoryScopeId
	$scopeIds += $roleEligibilitySchedules | Select-Object -ExpandProperty directoryScopeId
	$scopeIds = $scopeIds | Where-Object { $_.id -ne '/' } | Select-Object -Unique
	$script:administrativeUnits = Get-AdministrativeUnit

	# Extract unique group IDs from all role schedules for prefetching group schedule information in bulk to reduce number of API calls later on.
	$groupIds = @()
	$groupIds += $roleAssignmentSchedules | Select-Object -ExpandProperty principal | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } | Select-Object -ExpandProperty Id
	$groupIds += $roleEligibilitySchedules | Select-Object -ExpandProperty principal | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } | Select-Object -ExpandProperty Id
	$groupIds = $groupIds | Select-Object -Unique

	# Prefetch group schedules for all groups used groups
	Write-Progress -Activity $activityName -Status 'Fetching assigned group schedules' -PercentComplete 65
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