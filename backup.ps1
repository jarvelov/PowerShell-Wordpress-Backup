#Backup script for Wordpress installation
#Dependencies: Powershell 2.0+ (required) 7zip (optional), SMTP server without authentication (optional)
#Author: Tobias Järvelöv - @jarvelov
#Author homepage: tobias.jarvelov.se
#Last updated: 2016-03-02

## Config Start ##

#Credentials
$mysqlUser = "user"      #Mysql username
$mysqlPass = "pass"      #Mysql password
$mysqlHost = "localhost" #omit quotes if using IP
$mysqlDatabase = "mydb"  #Name database you want to export
$mysqlCharset = "utf8"   #Change this if your server is not using UTF8 encoding

#Filepaths
$sourceDir = "WPINSTALLDIR"     #e.g. C:\inetpub\wwwroot
$destDir = "ZIPDESTINATIONDIR"  #e.g. D:\Backup
$sqlOutputFile = "mydb.sql"     #Output filename for dumped database (will be placed in root of the zip file)
$mysqlDump = "mysqldump.exe"    #If mysqldump.exe not in PATH use format '"C:\Program Files\MySQL\MySQL Server 5.7\bin\mysqldump.exe"'
$7zip = "7za.exe"               #if 7za.exe not in PATH use format '"C:\Program Files\7zip\7za.exe"'

#Settings
$mailEnabled = $True            #Set to $False if you don't want an email
$zipEnabled = $True             #Set to $False if you don't want to compress the directory and just move it to the destination directory ($destDir)

#Mail settings
$subject = "WP backup - "
$recipients = "user@example.com"
$sender = 'WP backup <user@example.com>'

#Smtp settings
$smtpServer = "localhost"       #Must be an SMTP server WITHOUT authentication
$smtpPort = 25

#Output directory name format
$prefix = "wpbackup_"
$date = (Get-Date -Format "yyyy_MM_dd_HHmm").ToString()

## Config End ##
#No need to configure anything below this line"

## Functions ##

Function Write-Log ($msg){
    $logDate = (Get-Date -Format "yyyy_MM_dd_HHmm").ToString()
    $content = "$logDate : $msg"
    Write-Host $content
    Add-Content -Value $content -Path $logFile
}

## Program Start ##

#Create log and temporary folder
$name = "Create folders"
$logDir =".\logs\"
$logFile = "$logDir$prefix$date.txt"
$tmpName = "$prefix$date"
$tmpDir = ".\$tmpName"
$steps = @()

Try {
    If((Test-Path ($logDir)) -eq $false) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    Write-Log "Info $name : Creating log and temporary directories."

    #Make sure $tmpDir exists
    If((Test-Path ($tmpDir)) -eq $false) {
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
    }

    #Make sure $destDir exists
    If((Test-Path ($destDir)) -eq $false) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
    }

    $status = $true
} Catch [Exception] {
    Write-Log "Failure $name : Could not create temporary directories. Exception: "$_.Exception.Message
    $status = $false
}

$steps += @($status,$name)

#Copy Wordpress installation
$name = "Copy files"

Write-Log "Info $name : Copying Wordpress directory..."

Try {
    Copy-Item -Path $sourceDir -Recurse -Destination "$tmpDir"

    #If copy is done but tmpDir isn't created, report failure
    If((Test-Path ($tmpDir)) -eq $false) {
        Write-Log "Failure $name : Path $tmpDir does not exist"
        $status = $false
        break
    }

    Write-Log "Info $name : Copy complete. Verifying size of dumped file $tmpDir"
    $wpFolder = (Get-ChildItem $tmpDir -Recurse | Measure-Object -Property Length -Sum)
    $wpSizeString = "{0:N0}" -f ($wpFolder.sum / 1MB)
    [int]$wpSize = $wpSizeString -Replace "\s"
    Write-Host $wpSize

    #Check if more than 50 Mb
    If($wpSize -gt 50) {
        Write-Log "Info $name : Wordpress directory copied successfully. Temporary folder size is $wpSize Mb"
        $status = $true
    } else {
        Write-Log "Failure $name : Wordpress directory was not copied successfully. Temporary folder size is less than 50 Mb. Folder size: $wpSize Mb"
        $status = $false
    }
} Catch [Exception] {
    Write-Log "Failure $name : Could not copy Wordpress directory. Exception: "$_.Exception.Message
    $status = $false
}

$steps += @($status,$name)

#Dump databases with mysqldump
$name = "Mysqldump"
[string]$process = $mysqlDump
$sql = "$tmpDir\$sqlOutputFile"
$database = $mysqlDatabase
$jobName = "mysqldump_$date"
[Array]$arguments = "--host=$mysqlHost", "--user=$mysqlUser", "--password=$mysqlPass", "--default-character-set=$mysqlCharset", $database;
$command = "& $process $arguments | Out-File $sql -Encoding UTF8" #Note, this is UTF8 with BOM
Write-Log "Info $name : Dumping database"

Try {
    Start-Job -Name $jobName -ScriptBlock { Invoke-Expression $args[0] } -ArgumentList $command | Out-Null
    Wait-Job $jobName | Out-Null
    $jobState = (Get-Job $jobName).State

    #If job is done but status isn't completed, report failure
    if($jobState -ne "Completed") {
        Write-Log "Failure $name : Database dump job did not complete successfully."
        $status = $false
        break
    }

    Write-Log "Info $name : Database dump complete. Verifying size of dumped file $sql"
    $size = ((Get-childitem $sql).Length / 1Mb)
    $sqlSize = "{0:N2}" -f ($size)

    #Check if more than 1 Mb
    If($sqlSize -gt 1) {
        Write-Log "Info $name : Database dumped successfully. Sql dump is $sqlSize Mb"
        $status = $true
    } else {
        Write-Log "Failure $name : Database dump did not complete successfully. Dump file is $sqlSize Mb"
        $status = $false
    }
} Catch [Exception] {
    Write-Log "Failure $name : Could not dumb mysql database. Exception: "+$_.Exception.Message
}

$steps += @($status,$name)

if($zipEnabled -eq $True) {
    #Compress archive to $destDir
    $name = "Zip creation"
    $process = $7zip
    $zip = "$destDir$tmpName.zip"
    $arguments = " a -tzip $zip $tmpDir"

    Write-Log "Info $name : Compressing temporary directory into zip archive."

    Try {
        Write-Log "Info $name : Creating archive of $tmpDir to $zip"
        Start-Process -FilePath $process -ArgumentList $arguments -Wait

        Write-Log "Info $name : Zip creation complete. Verifying archive $zip"
        $size = ((Get-childitem $zip).Length / 1Mb)
        $zipSize = "{0:N2}" -f ($size)

        #Check if more than 1 Mb
        If($zipSize -gt 1) {
            Write-Log "Info $name : Zip creation completed successfully. Compressed archive is $zipSize Mb"
            $status = $true
        } else {
            Write-Log "Info $name : Zip did not complete successfully. Compressed archive is $zipSize Mb"
            $status = $false
        }
    } Catch [Exception] {
        Write-Log "Failure $name : Could not create zip archive . Exception: "$_.Exception.Message
        $status = $false
    }

    $steps += @($status,$name)
} else {
    $name = "Move directory"
    Write-Log "Info $name : Moving temporary directory $tmpName to $destDir"

    Try {
        Copy-Item -Recurse $tmpName "$destDir\$tmpName" -ErrorAction Stop
        Write-Log "Info $name : Moved temporary directory to $destDir\$tmpName"
    } Catch [Exception] {
        Write-Log "Failure $name : Could not move temporary directory. Exception: "+$_.Exception.Message
    }
}

#Cleanup temporary files
$name = "Cleanup"

Write-Log "Info $name : Cleaning up working directory"

Try {
    Remove-Item -Force -Path $tmpDir -Recurse -Confirm:$false
    Write-Log "Info $name : Successfully cleaned working directory."
} Catch [Exception] {
    Write-Log "Failure $name : Could not remove temporary directories. Exception: "$_.Exception.Message
}

$steps += @($status,$name)

if($mailEnabled -eq $True) {
    #Build mail body
    $name = "Mail"
    $body = "<div><h1>WP Backup Report</h1></div>"

    $body += "<div><h3>Sql</h3></div><div>Sql size: $sqlSize Mb </div>"
    $body += "<div><h3>Temporary backup folder</h3><div>Size before archiving: $wpSize Mb</div>"
    $body += "<div><h3>Zip</h3></div><div>Zip size: $zipSize Mb</div><div>Location: $zip </div>"
    $body += "<h3>Steps</h3>"
    $body += "<table><thead><th>Result</th><th>Step</th><thead><tbody>"
    $row = $NULL
    $attachments = $NULL
    $args = $NULL

    $steps += @($status,$name)

    Write-Log "Info $name : Building email report."

    #Check error messages

    for($i=0;$i -le ((($steps).count)-1);$i++) {
        $step = $steps[$i]

        if($step -eq $true) {
            $i++
            $step = $steps[$i]
            $status = 'style="background-color: #00FF00"' #No error
            $text = "Success"
        } elseif($step -eq $false) {
            $i++
            $step = $steps[$i]
            $status = 'style="background-color: #FF0000"' #Error
            $text = "Error"
            $attachments = $logFile
        }
        $row += "<tr><td $status>$text</td><td $status>$step</td></tr>"
    }

    $body += $row
    $body += "</tbody></table>"

    #Send email with report status

    Try {
        #Only attach log if there was an error
        if(($attachments) -ne $NULL) {
            $subjectStatus = "Error!"
            Send-MailMessage -From $sender -To $recipients -Subject $subject$subjectStatus" - "$date -Body $body -BodyAsHtml:$true -Encoding "UTF8" -SmtpServer $smtpserver -Port $smtpport -Attachments $attachments
        } else {
            $subjectStatus = "Success!"
            Send-MailMessage -From $sender -To $recipients -Subject $subject$subjectStatus" - "$date -Body $body -BodyAsHtml:$true -Encoding "UTF8" -SmtpServer $smtpserver -Port $smtpport
        }
        Write-Log "Info $name : Successfully sent email report to $recipients"
    } Catch [Exception] {
        Write-Log "Failure $name : Could not send email report . Exception: "$_.Exception.Message
    }
}
