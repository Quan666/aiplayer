; Build with package.py windows --windows-installer (Inno Setup 6).
[Setup]
AppId=app.aiplayer.aiplayer
AppName=AIPlayer
AppVersion={#AppVersion}
VersionInfoVersion={#FileVersion}
AppPublisher=AIPlayer contributors
DefaultDirName={localappdata}\Programs\AIPlayer
DefaultGroupName=AIPlayer
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=aiplayer-windows-x64-setup
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\aiplayer.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\AIPlayer"; Filename: "{app}\aiplayer.exe"

[Run]
Filename: "{app}\aiplayer.exe"; Description: "Launch AIPlayer"; Flags: nowait postinstall skipifsilent
