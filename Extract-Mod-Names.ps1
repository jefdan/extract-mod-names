# Define the directory containing the .jar files
$directory = ""

# Output file for mod names
$outputFile = ""

# Array to collect all mod information
$modInfoCollection = @()

# Get all .jar files in the directory
$jarFiles = Get-ChildItem -Path $directory -Filter *.jar

# Add assembly for ZIP operations
Add-Type -AssemblyName "System.IO.Compression.FileSystem"

# Function to extract mod information from mcmod.info
function Get-ModInfoFromMcmodInfo {
    param (
        [string]$mcmodInfoContent,
        [string]$jarFileName,
        [ref]$results
    )

    try {
        # Try to parse as JSON array first
        try {
            $modInfo = $mcmodInfoContent | ConvertFrom-Json
            
            # Check if it's an array or object
            if ($modInfo -is [System.Array]) {
                foreach ($mod in $modInfo) {
                    if ($mod.modid -and $mod.name) {
                        $output = "Mod Name: $($mod.name) (ID: $($mod.modid))"
                        Write-Output $output
                        $results.Value += $output
                    }
                }
            } 
            elseif ($modInfo.modList -is [System.Array]) {
                # Some mods use a modList property
                foreach ($mod in $modInfo.modList) {
                    if ($mod.modid -and $mod.name) {
                        $output = "Mod Name: $($mod.name) (ID: $($mod.modid))"
                        Write-Output $output
                        $results.Value += $output
                    }
                }
            }
            else {
                # Single mod info
                if ($modInfo.modid -and $modInfo.name) {
                    $output = "Mod Name: $($modInfo.name) (ID: $($modInfo.modid))"
                    Write-Output $output
                    $results.Value += $output
                }
            }
        }
        catch {
            Write-Warning "Failed to parse mcmod.info for $jarFileName as standard JSON: $($_.Exception.Message)"
            
            # Fallback to file name if parsing fails
            $modName = [System.IO.Path]::GetFileNameWithoutExtension($jarFileName)
            $output = "Mod Name: $modName (ID: unknown - using filename)"
            Write-Output $output
            $results.Value += $output
        }
    }
    catch {
        Write-Warning "Error processing mcmod.info for $jarFileName - $($_.Exception.Message)"
    }
}

# Function to extract mod information from mods.toml
function Get-ModInfoFromModsToml {
    param (
        [string]$modsTomlContent,
        [string]$jarFileName,
        [ref]$results
    )

    try {
        $modId = $null
        $modName = $null

        $lines = $modsTomlContent -split "`n"
        $inModsBlock = $false
        
        foreach ($line in $lines) {
            # Trim the line to handle whitespace
            $line = $line.Trim()
            
            # Check if we're entering a [[mods]] section
            if ($line -eq "[[mods]]") {
                $inModsBlock = $true
                # Reset variables for a new mod section
                $modId = $null
                $modName = $null
                continue
            }
            
            # If we're in a mods block, look for modId and displayName
            if ($inModsBlock) {
                # Different formats for modId
                if ($line -match '^modId\s*=\s*"([^"]+)"' -or 
                    $line -match "^modId\s*=\s*'([^']+)'") {
                    $modId = $matches[1]
                }
                
                # Different formats for displayName
                if ($line -match '^displayName\s*=\s*"([^"]+)"' -or 
                    $line -match "^displayName\s*=\s*'([^']+)'") {
                    $modName = $matches[1]
                }
                
                # If we have both modId and modName, output them
                if ($modId -and $modName) {
                    # Skip if modName contains unreplaced variables
                    if ($modName -notmatch '\${.*?}') {
                        $output = "Mod Name: $modName (ID: $modId)"
                        Write-Output $output
                        $results.Value += $output
                    }
                    else {
                        # Try to extract a useful name from the jar filename
                        $simpleName = [System.IO.Path]::GetFileNameWithoutExtension($jarFileName)
                        $output = "Mod Name: $simpleName (ID: $modId) [Name had variables]"
                        Write-Output $output
                        $results.Value += $output
                    }
                    
                    # Reset for next mod in the same file
                    $modId = $null
                    $modName = $null
                }
            }
        }
        
        # If we found modId but not modName (or vice versa), use what we have
        if (($modId -and -not $modName) -or (-not $modId -and $modName)) {
            $simpleName = if ($modName) { $modName } else { [System.IO.Path]::GetFileNameWithoutExtension($jarFileName) }
            $simpleId = if ($modId) { $modId } else { "unknown" }
            
            $output = "Mod Name: $simpleName (ID: $simpleId) [Incomplete info]"
            Write-Output $output
            $results.Value += $output
        }
        
        # If we didn't find anything, use the filename
        if (-not $modId -and -not $modName) {
            $simpleName = [System.IO.Path]::GetFileNameWithoutExtension($jarFileName)
            $output = "Mod Name: $simpleName (ID: unknown - from filename)"
            Write-Output $output
            $results.Value += $output
        }
    }
    catch {
        Write-Warning "Error processing mods.toml for $jarFileName - $($_.Exception.Message)"
        
        # Fallback to the jar filename
        $simpleName = [System.IO.Path]::GetFileNameWithoutExtension($jarFileName)
        $output = "Mod Name: $simpleName (ID: unknown - exception fallback)"
        Write-Output $output
        $results.Value += $output
    }
}

# Show progress bar
$totalJars = $jarFiles.Count
$currentJar = 0

# Iterate through each .jar file
foreach ($jarFile in $jarFiles) {
    # Update progress
    $currentJar++
    $percentComplete = [int]($currentJar / $totalJars * 100)
    Write-Progress -Activity "Extracting Mod Information" -Status "$currentJar of $totalJars - $($jarFile.Name)" -PercentComplete $percentComplete
    
    $processed = $false
    
    try {
        # Open the jar file as a zip archive without extracting
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($jarFile.FullName)
        
        # Check for mcmod.info
        $mcmodInfoEntry = $zipArchive.Entries | Where-Object { $_.FullName -eq "mcmod.info" } | Select-Object -First 1
        if ($mcmodInfoEntry) {
            $stream = $mcmodInfoEntry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $content = $reader.ReadToEnd()
            $reader.Close()
            $stream.Close()
            
            Get-ModInfoFromMcmodInfo -mcmodInfoContent $content -jarFileName $jarFile.Name -results ([ref]$modInfoCollection)
            $processed = $true
        }
        
        # Check for mods.toml if mcmod.info didn't exist or didn't contain valid mod info
        if (-not $processed) {
            $modsTomlEntry = $zipArchive.Entries | Where-Object { $_.FullName -eq "META-INF/mods.toml" } | Select-Object -First 1
            if ($modsTomlEntry) {
                $stream = $modsTomlEntry.Open()
                $reader = New-Object System.IO.StreamReader($stream)
                $content = $reader.ReadToEnd()
                $reader.Close()
                $stream.Close()
                
                Get-ModInfoFromModsToml -modsTomlContent $content -jarFileName $jarFile.Name -results ([ref]$modInfoCollection)
                $processed = $true
            }
        }
        
        # If no info found, just use the filename
        if (-not $processed) {
            $simpleName = [System.IO.Path]::GetFileNameWithoutExtension($jarFile.Name)
            $output = "Mod Name: $simpleName (ID: unknown - no metadata found)"
            Write-Output $output
            $modInfoCollection += $output
        }
        
        # Close the archive
        $zipArchive.Dispose()
    }
    catch {
        Write-Warning "Error processing $($jarFile.Name) - $($_.Exception.Message)"
        
        # Add fallback for completely failed mods
        $simpleName = [System.IO.Path]::GetFileNameWithoutExtension($jarFile.Name)
        $output = "Mod Name: $simpleName (ID: unknown - processing error)"
        Write-Output $output
        $modInfoCollection += $output
    }
}

# Clear progress bar
Write-Progress -Activity "Extracting Mod Information" -Completed

# Write all collected information to the output file at once
try {
    $modInfoCollection | Out-File -FilePath $outputFile -Encoding utf8
    Write-Output "Mod extraction completed. Results saved to $outputFile"
}
catch {
    Write-Error "Failed to write results to $outputFile - $($_.Exception.Message)"
}