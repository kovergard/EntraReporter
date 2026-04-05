<#
	.SYNOPSIS
	Retrieves Entra ID role assignments and eligibility information for users, groups, and service principals.

	.DESCRIPTION
	The command queries Microsoft Graph Privileged Identity Management (PIM) role assignment and role eligibility schedules, resolves group member assignments, and returns a consolidated set of role assignment records.

	.PARAMETER RoleName
	Optional filter for one or more role names. If provided, only role assignments and eligibilities matching the specified role names are returned.

	.EXAMPLE
	Get-EntraIdRoleAssignment
	
	Retrieves all role assignments and eligibilities in the connected tenant (requires Entra P2).

	.EXAMPLE
	Get-EntraIdRoleAssignment -RoleName 'Global Administrator'

	Retrieves assignments and eligibilities for the Global Administrator role only.

	.NOTES
	Requires an active connection to Microsoft Graph (`Connect-MgGraph`) and Entra P2 license level.
	This module does not yet support nested group role assignments completely; a warning is emitted when nested groups are present.

	.LINK
	https://learn.microsoft.com/graph/api/rolemanagement-root
#>
function Get-EntraIdRoleAssignment {
	[CmdletBinding()]
	[OutputType([PSCustomObject[]])]
	param(
		[Parameter()]
		[string[]]
		$RoleName
	)

	#region Internal functions

	# Resolve-AssignmentWindow: compute the effective assignment window from principal and user time windows
	function Resolve-AssignmentWindow {
		[CmdletBinding()]
		param(
			[Nullable[datetime]] $PrincipalStart, # Start datetime from principal assignment schedule
			[Nullable[datetime]] $PrincipalEnd,   # End datetime from principal assignment schedule
			[Nullable[datetime]] $UserStart,      # Start datetime from user assignment schedule
			[Nullable[datetime]] $UserEnd         # End datetime from user assignment schedule
		)

		if ($null -eq $UserEnd -and $null -eq $PrincipalEnd) {
			# Both are permanent (no end date); assignment is permanent
			return [pscustomobject]@{
				Start       = $null
				End         = $null
				IsPermanent = $true
			}
		}

		if ($null -eq $PrincipalEnd) {
			# Principal is permanent; use user window
			return [pscustomobject]@{
				Start       = $UserStart
				End         = $UserEnd
				IsPermanent = $false
			}
		}

		if ($null -eq $UserEnd) {
			# User is permanent; use principal window
			return [pscustomobject]@{
				Start       = $PrincipalStart
				End         = $PrincipalEnd
				IsPermanent = $false
			}
		}

		# Both have end dates; return intersection (most restrictive window)
		return [pscustomobject]@{
			Start       = if ($PrincipalStart -gt $UserStart) { $PrincipalStart } else { $UserStart }
			End         = if ($PrincipalEnd -lt $UserEnd) { $PrincipalEnd } else { $UserEnd }
			IsPermanent = $false
		}
	}

	# New-RoleAssignmentEntry: build and normalize a role assignment output record
	function New-RoleAssignmentEntry {
		[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Doesnt really change state, just normalizes output')]
		[CmdletBinding()]
		param(
			[Parameter(Mandatory)] [string]$RoleId,              # Role definition ID
			[Parameter(Mandatory)] [string]$RoleName,            # Role display name
			[Parameter(Mandatory)] [string]$PrincipalId,         # Assigned principal ID (user/group/servicePrincipal)
			[Parameter(Mandatory)] [string]$PrincipalDisplayName,# Assigned principal display name
			[Parameter(Mandatory)] [string]$AssignmentType,      # Assignment type (User/Group/Service principal)
			[Parameter(Mandatory)] [string]$Scope,               # Scope/administrative unit for assignment
			[Parameter(Mandatory)] [string]$PrincipalState,      # Principal state (Assigned/Eligible)
			[Nullable[datetime]] $PrincipalStartTime,            # Principal assignment start
			[Nullable[datetime]] $PrincipalEndTime,              # Principal assignment end
			[Parameter(Mandatory)] [string]$UserId,              # User ID (expanded member if group schedule)
			[Parameter(Mandatory)] [string]$UserDisplayName,     # User display name
			[Parameter(Mandatory)] [string]$UserPrincipalName,   # User principal name/appId
			[Parameter(Mandatory)] [string]$UserState,           # User state (Assigned/Eligible)
			[Nullable[datetime]] $UserStartTime,                 # User assignment start
			[Nullable[datetime]] $UserEndTime                    # User assignment end
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

	# Resolve-RoleAssignedGroup: expand group principal schedules into per-member entries
	# This function reads the preloaded group schedule entries, maps each member to user-level
	# role assignment/eligibility and then calls New-RoleAssignmentEntry to normalize output.
	function Resolve-RoleAssignedGroup {
		[CmdletBinding()]
		param(
			# Graph schedule object for group role assignment/eligibility
			[Parameter(Mandatory = $true)]
			[psobject]
			$Schedule,

			# Group state context being processed
			[Parameter(Mandatory = $true)]
			[ValidateSet('Assigned', 'Eligible')]
			[string]
			$GroupState,

			# Resulting user-level state for group members
			[Parameter(Mandatory = $true)]
			[ValidateSet('Assigned', 'Eligible')]
			[string]
			$UserState
		)

		$principal = $Schedule.principal

		# Choose group schedule entries based on whether we are resolving assigned or eligible members
		if ($UserState -eq 'Assigned') {
			$scheduleEntries = $script:groupAssignmentSchedules | Where-Object { $_.groupId -eq $principal.id }
		}
		else {
			$scheduleEntries = $script:groupEligibilitySchedules | Where-Object { $_.groupId -eq $principal.id }
		}

		foreach ($scheduleEntry in $scheduleEntries ) {
			if ($scheduleEntry.principal.'@odata.type' -eq '#microsoft.graph.user') {
				# User member found; create normalized assignment entry
				$roleEntrySplat = @{
					RoleId               = $Schedule.roleDefinitionId
					RoleName             = $Schedule.roleDefinition.displayName
					PrincipalId          = $Schedule.principal.id
					PrincipalDisplayName = $Schedule.principal.displayName
					AssignmentType       = 'Group'
					Scope                = ($administrativeUnits | Where-Object { $_.directoryScopeId -eq $Schedule.directoryScopeId }).displayName
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
			elseif ($scheduleEntry.principal.'@odata.type' -eq '#microsoft.graph.group') {
				# Nested group found; recursion not yet supported
				Write-Verbose "Skipping nested group with ID '$($scheduleEntry.principal.id)' since nested groups are currently not supported by the command."
			}
			else {
				Write-Warning "Principal with ID '$($scheduleEntry.principal.id)' is of type $($scheduleEntry.principal.'@odata.type'), which is currently not supported by the command. Skipping entry."
				$scheduleEntry | ConvertTo-Json -Depth 5 | Write-Verbose
			}
		}
	}

	# Resolve-EntraIDRoleSchedule: normalize a schedule entry into 1+ role assignment rows
	# Handles user/servicePrincipal directly and delegates group principals to Resolve-RoleAssignedGroup.
	function Resolve-EntraIDRoleSchedule {
		param(
			# The Graph role schedule to resolve into output entries
			[Parameter(Mandatory = $true)]
			[psobject]
			$Schedule,

			# The schedule state to apply for this resolution pass
			[Parameter(Mandatory = $true)]
			[ValidateSet('Assigned', 'Eligible')]
			[string]
			$State
		)

		# Resolve principal to allow handling of different principal types
		# (user, servicePrincipal, group) and convert each to normalized rows.
		try {
			$principal = $Schedule.principal

			if ($principal.'@odata.type' -eq '#microsoft.graph.user') {
				# User principal; create entry with user as both principal and assignee
				$roleEntrySplat = @{
					RoleId               = $Schedule.roleDefinitionId
					RoleName             = $Schedule.roleDefinition.displayName
					PrincipalId          = $Schedule.principal.id
					PrincipalDisplayName = $Schedule.principal.displayName
					AssignmentType       = 'User'
					Scope                = ($administrativeUnits | Where-Object { $_.directoryScopeId -eq $Schedule.directoryScopeId }).displayName
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
			elseif ($principal.'@odata.type' -eq '#microsoft.graph.servicePrincipal') {
				# Service principal; create entry with appId as principal name
				$roleEntrySplat = @{
					RoleId               = $Schedule.roleDefinitionId
					RoleName             = $Schedule.roleDefinition.displayName
					PrincipalId          = $Schedule.principal.id
					PrincipalDisplayName = $Schedule.principal.displayName
					AssignmentType       = 'Service principal'
					Scope                = ($administrativeUnits | Where-Object { $_.directoryScopeId -eq $Schedule.directoryScopeId }).displayName
					PrincipalState       = $State
					PrincipalStartTime   = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.startDateTime } else { $null }
					PrincipalEndTime     = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.expiration.endDateTime } else { $null }
					UserId               = $Schedule.principalId
					UserDisplayName      = $Schedule.principal.displayName
					UserPrincipalName    = $Schedule.principal.appId
					UserState            = $State
					UserStartTime        = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.startDateTime } else { $null }
					UserEndTime          = if ($Schedule.scheduleInfo.expiration.endDateTime) { $Schedule.scheduleInfo.expiration.endDateTime } else { $null }
				}
				New-RoleAssignmentEntry @roleEntrySplat
			}

			elseif ($principal.'@odata.type' -eq '#microsoft.graph.group') {
				# Group principal; expand into per-member entries, handling both assigned and eligible
				Resolve-RoleAssignedGroup -Schedule $Schedule -GroupState $State -UserState 'Assigned'
				Resolve-RoleAssignedGroup -Schedule $Schedule -GroupState $State -UserState 'Eligible'
			}
			else {
				Write-Warning "Principal with ID '$($principal.id)' is of type $($principal.'@odata.type'), which is currently not supported by the command. Skipping entry."
				$Schedule | ConvertTo-Json -Depth 5 -Compress | Write-Verbose
			}
		}
		catch {
			Write-Warning "An error occurred while processing principal with ID '$($principal.id)' for role assignment with role ID '$($Schedule.roleDefinitionId)'. Skipping entry. Error details: $_"
			$Schedule | ConvertTo-Json -Depth 5 -Compress | Write-Verbose
		}
	}

	#endregion Internal Functions

	#region MAIN

	# Always stop on errors to avoid emitting incomplete data. Errors should be handled at the command level to allow for more granular error handling (e.g. skipping individual entries that fail to resolve rather than failing the entire command).
	$ErrorActionPreference = 'Stop'

	if (!(Test-GraphConnection)) {
		throw 'No active connection to Microsoft Graph. Run Connect-MgGraph to sign in and then retry.'
	}

	$EntraIdLevel = Get-EntraIdLevel
	if ($EntraIdLevel.Level -ne 'P2') {
		throw 'This command requires at P2 level to run since it relies on APIs that are not available for Entra P1 or Free tenants.'
		# TODO: Add support for P1 tenants by falling back to fetching role assignments via the standard directory role assignments API for tenants that do not have PIM / Privileged Access enabled. This will likely require significant changes to the command logic since the standard directory role assignments API does not return future-dated assignments or eligible assignments, so it will require fetching all role assignments and then checking each assignment against the role eligibility schedules to determine eligibility and future-dated status. In the meantime, we will throw an error for non-P2 tenants to avoid emitting incomplete data.
	}

	$timer = [Diagnostics.Stopwatch]::StartNew()
	$activityName = 'Fetching Entra ID role assignments'

	# Fetch all role schedules, assigned and eligible.
	Write-Progress -Activity $activityName -Status 'Fetching assigned role schedules' -PercentComplete 20
	$roleAssignmentSchedules = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/roleManagement/directory/roleAssignmentSchedules?`$filter=assignmentType eq 'Assigned'&`$expand=principal,roleDefinition" -Verbose:$false)['value']
	Write-Progress -Activity $activityName -Status 'Fetching eligible role schedules' -PercentComplete 40
	$roleEligibilitySchedules = (Invoke-MgGraphRequest -Method GET -Uri "v1.0/roleManagement/directory/roleEligibilitySchedules?`$expand=principal,roleDefinition" -Verbose:$false)['value']

	# If Rolename has been specified, filter out any assigments not in the specified role(s).
	if ($RoleName) {
		$roleAssignmentSchedules = $roleAssignmentSchedules | Where-Object { $_.roleDefinition.displayName -in $RoleName }
		$roleEligibilitySchedules = $roleEligibilitySchedules | Where-Object { $_.roleDefinition.displayName -in $RoleName }
	}

	# If any scopes are used in the role schedules (i.e. scope is not just the entire directory), fetch information about the scopes to allow for better reporting (e.g. resolving administrative unit names).
	Write-Progress -Activity $activityName -Status 'Fetching scope information' -PercentComplete 60
	$script:administrativeUnits = Get-AdministrativeUnit

	# Extract unique group IDs from all role schedules for prefetching group schedule information in bulk to reduce number of API calls later on.
	$groupIds = @()
	$groupIds += ($roleAssignmentSchedules.principal | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }).Id
	$groupIds += ($roleEligibilitySchedules.principal | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }).Id
	$groupIds = $groupIds | Select-Object -Unique

	# Prefetch group schedules for all groups used groups
	if ($groupIds.Count -gt 0) {
		Write-Progress -Activity $activityName -Status 'Fetching assigned group schedules' -PercentComplete 65
		$script:groupAssignmentSchedules = Get-EntraIdGroupScheduleBatch -GroupId $groupIds -State 'Assigned'
		Write-Progress -Activity $activityName -Status 'Fetching eligible group schedules' -PercentComplete 80
		$script:groupEligibilitySchedules = Get-EntraIdGroupScheduleBatch -GroupId $groupIds -State 'Eligible'
	}
	else {
		$script:groupAssignmentSchedules = @()
		$script:groupEligibilitySchedules = @()
	}

	if (($groupAssignmentSchedules | Where-Object { $_.principal.'@odata.type' -eq '#microsoft.graph.group' }) -or ($groupEligibilitySchedules | Where-Object { $_.principal.'@odata.type' -eq '#microsoft.graph.group' })) {
		Write-Warning 'One or more role assignment uses nested groups, which is currently not supported by the command. This may lead to incomplete reporting.'
		# TODO: Add support for nested groups by recursively resolving group memberships until only user principals are left. This will likely require a significant increase in the number of API calls, so it should be implemented with caution and ideally with some form of caching to avoid hitting API limits. In the meantime, we will emit a warning to alert users of potential incompleteness in the reporting.
	}

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
#endregion MAIN