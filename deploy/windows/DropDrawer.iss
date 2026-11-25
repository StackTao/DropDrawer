#define AppExe "dropdrawer_app.exe"

[Setup]
AppId={{E250749F-4BC6-4861-B9C9-A8EF61FE76F9}
AppName=DropDrawer
AppVersion={#AppVersion}
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
; In-app updates run this installer with /SILENT /UPDATE=1; start the new version afterwards.
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: IsInAppUpdate

[Code]
function IsInAppUpdate: Boolean;
begin
  Result := ExpandConstant('{param:UPDATE|0}') = '1';
end;

function FindDrawerWindow(ClassName, WindowName: String): HWND;
  external 'FindWindowW@user32.dll stdcall';

function CloseRunningDrawer: String;
var
  Wnd: HWND;
  Attempt: Integer;
begin
  Result := '';
  for Attempt := 1 to 100 do
  begin
    if not CheckForMutexes('Local\DropDrawer') then Exit;
    Wnd := FindDrawerWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'DropDrawer');
    { Same quit message as the tray menu, including previously installed versions. }
    if Wnd <> 0 then PostMessage(Wnd, $8002, 0, 0);
    Sleep(100);
  end;
  Result := 'Please quit DropDrawer from its tray menu and retry.';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := CloseRunningDrawer;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  CloseError: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    CloseError := CloseRunningDrawer;
    if CloseError <> '' then RaiseException(CloseError);
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'DropDrawer');
    RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\DropDrawer');
  end;
end;
