<#
    .SYNOPSIS
    Test Microsoft Graph connection
    .DESCRIPTION
    Verifies that the Microsoft.Graph.Authentication module is installed and that the session is connected to Microsoft Graph. 
    .EXAMPLE
    Test-GraphConnection
#>
function Test-GraphConnection {
	[CmdletBinding()]
	param ()

	# Check if Graph module is installed
	if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication -Verbose:$false)) {
		Write-Verbose 'Microsoft.Graph.Authentication module is not installed.'
		return $false
	}

	# Check if connected
	$mgContext = Get-MgContext -ErrorAction SilentlyContinue
	if (-not $mgContext) {
		Write-Verbose 'Not connected to Microsoft Graph.'
		return $false
	}

	Write-Verbose 'Connected to Microsoft Graph.'
	return $true
}