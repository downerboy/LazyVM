# Unattend.ps1 - Unattended Windows Setup answer-file disc.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# Windows Setup and OOBE run without anyone at the console, so a build can
# carry on into the guest by itself.
#
# Windows Setup looks for autounattend.xml only at the root of removable
# media (USB drives, then CDs and DVDs), never on a fixed disk. A virtual hard
# disk is a fixed disk, so the answer file goes on a small ISO image instead,
# attached as a second DVD drive. The image is built with IMAPI2, which is
# part of Windows: no Windows ADK or oscdimg needed, and the Windows ISO is
# never modified.

function New-UnattendXml {
    param(
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$TimeZone,
        # Where the first-logon command marks the guest as provisioned, in reg.exe's form (HKLM\...).
        [Parameter(Mandatory)][string]$MarkerKey
    )

    # Literal here-string, tokens substituted afterwards, so nothing in the XML
    # is at risk of PowerShell interpolation.
    $template = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Label>System</Label><Format>FAT32</Format></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>@@USER@@</FullName>
        <Organization>LazyVM</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>@@COMPUTER@@</ComputerName>
      <TimeZone>@@TIMEZONE@@</TimeZone>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Allow OOBE without a Microsoft account</Description>
          <Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <!-- Without this, Windows 11 OOBE stops on the region and keyboard pages. -->
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <TimeZone>@@TIMEZONE@@</TimeZone>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>@@USER@@</Name>
            <DisplayName>@@USER@@</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>@@PASSWORD@@</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>@@USER@@</Username>
        <LogonCount>99</LogonCount>
        <Password>
          <Value>@@PASSWORD@@</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Never expire local account passwords</Description>
          <CommandLine>net accounts /maxpwage:unlimited</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Signal provisioning complete</Description>
          <CommandLine>reg add "@@MARKERKEY@@" /v Provisioned /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
'@

    # The answer file format requires the password in clear text, so it is
    # decoded here, at the last possible moment, and the answer-file disc carrying it
    # is deleted as soon as the guest is provisioned.
    # XML-escape the substituted values; a generated password contains & and <.
    $escUser = [Security.SecurityElement]::Escape($UserName)
    $escPass = [Security.SecurityElement]::Escape((ConvertTo-PlainText $Password))
    $escComputer = [Security.SecurityElement]::Escape($ComputerName)
    $escTimeZone = [Security.SecurityElement]::Escape($TimeZone)
    $escMarkerKey = [Security.SecurityElement]::Escape($MarkerKey)

    $xml = $template.Replace('@@USER@@', $escUser).
    Replace('@@PASSWORD@@', $escPass).
    Replace('@@COMPUTER@@', $escComputer).
    Replace('@@TIMEZONE@@', $escTimeZone).
    Replace('@@MARKERKEY@@', $escMarkerKey)

    # Fail loudly here rather than letting Windows Setup silently ignore a
    # malformed answer file and drop to the interactive installer.
    $null = [xml]$xml
    return $xml
}

function Save-ImapiStream {
    <#
      Writes the image IMAPI2 builds to a file. IMAPI2 hands it over as a COM
      stream, which PowerShell cannot read directly, so a few lines of C# copy
      it across.
    #>
    param(
        [Parameter(Mandatory)]$Stream,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not ('LazyVM.ImapiStreamWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace LazyVM
{
    public static class ImapiStreamWriter
    {
        public static void Save(object stream, string path)
        {
            IStream source = (IStream)stream;
            byte[] buffer = new byte[65536];
            IntPtr bytesRead = Marshal.AllocHGlobal(sizeof(int));
            try
            {
                using (FileStream target = File.Create(path))
                {
                    while (true)
                    {
                        source.Read(buffer, buffer.Length, bytesRead);
                        int count = Marshal.ReadInt32(bytesRead);
                        if (count == 0) { break; }
                        target.Write(buffer, 0, count);
                    }
                }
            }
            finally
            {
                Marshal.FreeHGlobal(bytesRead);
            }
        }
    }
}
'@
    }
    [LazyVM.ImapiStreamWriter]::Save($Stream, $Path)
}

function New-UnattendSeedDisk {
    <# Builds the answer-file disc, SeedDiskPath: an ISO holding autounattend.xml. #>
    param(
        [Parameter(Mandatory)][VMContext]$VM,
        [Parameter(Mandatory)][pscredential]$GuestCredential
    )

    $seedDisk = $VM.Settings.SeedDiskPath
    Write-LogEntry 'Building the answer-file disc...' 'INFO'
    Remove-Item -LiteralPath $seedDisk -Force -ErrorAction SilentlyContinue

    $xml = New-UnattendXml -UserName $VM.Runtime.GuestAdminUser -Password $GuestCredential.Password `
        -ComputerName $VM.Settings.GuestComputerName -TimeZone $VM.Settings.GuestTimeZone `
        -MarkerKey ($script:GuestMarkerKey -replace '^HKLM:', 'HKLM')

    # IMAPI2 builds an image from a folder, so the answer file is written to
    # a private folder first and deleted straight after: it holds the guest
    # password in clear text.
    $staging = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ("LazyVM-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Folder -Path $staging
        [IO.File]::WriteAllText((Join-Path -Path $staging -ChildPath 'autounattend.xml'), $xml, [Text.UTF8Encoding]::new($false))

        $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $image.FileSystemsToCreate = 3      # ISO 9660 + Joliet, which keeps the long file name
        $image.VolumeName = 'UNATTEND'
        $image.Root.AddTree($staging, $false)
        Save-ImapiStream -Stream $image.CreateResultImage().ImageStream -Path $seedDisk
    }
    catch {
        Write-LogError 'Building the answer-file disc failed' $_
        Remove-Item -LiteralPath $seedDisk -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-LogEntry "Answer-file disc ready: $seedDisk" 'OK'
}

function Test-SeedDiskAttached {
    <# True when the VM still has the answer-file disc in a DVD drive. #>
    param([Parameter(Mandatory)][VMContext]$VM)

    return @(Get-VMDvdDrive -VMName $VM.Name -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $VM.Settings.SeedDiskPath }).Count -gt 0
}

function Remove-UnattendSeedDisk {
    <#
      The answer file holds the guest password in plain text, so the
      answer-file disc is ejected and deleted as soon as provisioning is
      confirmed.
    #>
    param([Parameter(Mandatory)][VMContext]$VM)

    $seedDisk = $VM.Settings.SeedDiskPath
    try {
        foreach ($drive in @(Get-VMDvdDrive -VMName $VM.Name -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $seedDisk })) {
            Remove-VMDvdDrive -VMDvdDrive $drive
            Write-LogEntry 'Answer-file disc removed from the VM' 'OK'
        }
        if (Test-Path -LiteralPath $seedDisk) {
            Remove-Item -LiteralPath $seedDisk -Force
            Write-LogEntry 'Answer-file disc deleted (it held the guest password in clear text)' 'OK'
        }
    }
    catch {
        Write-LogEntry "Could not remove the answer-file disc: $($_.Exception.Message)" 'WARN'
        Write-LogEntry "  Delete $seedDisk by hand - it contains the guest password." 'WARN'
    }
}
