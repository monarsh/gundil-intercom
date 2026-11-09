; Inno Setup script for the Gundil Intercom Windows installer.
;
; Build (on Windows, after `flutter build windows --release`):
;   iscc /DMyAppVersion=1.0.0 installer\windows\gundil_intercom.iss
; Output: build\installer\gundil-intercom-setup-<version>.exe
;
; Paths are relative to this file.

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

#define MyAppName "Gundil Intercom"
#define MyAppExe "gundil_intercom.exe"
#define FirewallRule "Gundil Intercom"
; Names used before the app was renamed (cleaned up on upgrade).
#define OldAppName "P2P Intercom"
#define OldAppExe "p2p_intercom.exe"

[Setup]
; Never change AppId: upgrades and uninstall are matched on it.
AppId={{8F1B6C2E-3C4A-4E7B-9A51-2D7E0C6B4F11}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher=Gundil Intercom
VersionInfoVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\..\build\installer
OutputBaseFilename=gundil-intercom-setup-{#MyAppVersion}
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExe}
UninstallDisplayName={#MyAppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; Admin is needed for Program Files and the firewall rule.
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no
; The autostart entry is per-user (HKCU), matching the in-app setting.
UsedUserAreasWarning=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "Start {#MyAppName} automatically when I sign in to Windows (in the system tray)"; GroupDescription: "Startup:"; Flags: checkedonce

[InstallDelete]
; Upgrading from "P2P Intercom": remove the old executable and shortcuts.
Type: files; Name: "{app}\{#OldAppExe}"
Type: files; Name: "{autoprograms}\{#OldAppName}.lnk"
Type: files; Name: "{autodesktop}\{#OldAppName}.lnk"

[Files]
; Flutter bundle: exe, flutter_windows.dll, intercom_audio.dll, data\, and the
; app-local Visual C++ runtime DLLs copied in by CI.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
; Same entry the app's "Start with Windows" switch reads and writes.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; ValueData: """{app}\{#MyAppExe}"" --minimized"; Flags: uninsdeletevalue; Tasks: autostart

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; Tasks: desktopicon

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#OldAppName}"""; Flags: runhidden waituntilterminated
; Allow incoming TCP 47801 (audio) and UDP 47800 (discovery) for the app on
; private/domain networks, so Windows doesn't block peers.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FirewallRule}"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#FirewallRule}"" dir=in action=allow program=""{app}\{#MyAppExe}"" enable=yes profile=private,domain"; Flags: runhidden waituntilterminated; StatusMsg: "Configuring Windows Firewall..."
Filename: "{app}\{#MyAppExe}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
; The app may be running hidden in the tray: close it so files can be removed.
Filename: "{sys}\taskkill.exe"; Parameters: "/IM {#MyAppExe} /F"; Flags: runhidden waituntilterminated; RunOnceId: "CloseApp"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#FirewallRule}"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveFirewallRule"
