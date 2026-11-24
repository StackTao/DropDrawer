#define AppExe "dropdrawer_app.exe"

[Setup]
AppId={{E250749F-4BC6-4861-B9C9-A8EF61FE76F9}
AppName=DropDrawer
AppVersion={#AppVersion}
AppMutex=Local\DropDrawer
CloseApplications=yes
RestartApplications=no
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

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "..\..\app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\DropDrawer"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
Name: "{autodesktop}\DropDrawer"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch DropDrawer"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'DropDrawer');
    RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\DropDrawer');
  end;
end;
