#define AppExe "dropdrawer_app.exe"

[Setup]
AppId={{E250749F-4BC6-4861-B9C9-A8EF61FE76F9}
AppName=DropDrawer
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\DropDrawer
UninstallDisplayIcon={app}\{#AppExe}
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\..\dist
OutputBaseFilename=DropDrawer-Windows-x64-Setup
SetupIconFile=..\..\app\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\DropDrawer"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
