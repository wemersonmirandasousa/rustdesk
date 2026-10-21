; Instalador DABLIU DESK (Inno Setup) - arquivo unico, padrao conhecido pelos antivirus.
; Empacota a pasta ./rustdesk (Release + usbmmidd) num unico DABLIU-DESK-Setup.exe.

[Setup]
AppName=DABLIU DESK
AppVersion=1.0
AppPublisher=Wemerson
AppCopyright=Desenvolvido por Wemerson @2026
DefaultDirName={localappdata}\Programs\DABLIU DESK
DisableProgramGroupPage=yes
DisableDirPage=yes
OutputBaseFilename=DABLIU-DESK-Setup
OutputDir=.\installer-out
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
WizardStyle=modern
SetupIconFile=.\flutter\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\DABLIU-DESK.exe
UninstallDisplayName=DABLIU DESK

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Files]
Source: ".\rustdesk\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\DABLIU DESK"; Filename: "{app}\DABLIU-DESK.exe"
Name: "{autodesktop}\DABLIU DESK"; Filename: "{app}\DABLIU-DESK.exe"

[Run]
Filename: "{app}\DABLIU-DESK.exe"; Description: "Abrir o DABLIU DESK agora"; Flags: nowait postinstall skipifsilent
