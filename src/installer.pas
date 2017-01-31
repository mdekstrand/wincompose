{
{ Installer state
}
var
    { s_run_1: first run
    { s_run_2: second run, with elevated privileges
    { s_skipped: second run, with all pages automatically skipped }
    state: (s_run_1, s_run_2, s_skipped);

    { The .NET version detection page }
    dotnet_page: twizardpage;
    warning, action, hint: tnewstatictext;

{
{ Some Win32 API hooks
}
procedure exit_process(uExitCode: uint);
    external 'ExitProcess@kernel32.dll stdcall';

function reexec(hwnd: hwnd; lpOperation: string; lpFile: string;
                lpParameters: string; lpDirectory: string;
                nShowCmd: integer): thandle;
    external 'ShellExecuteW@shell32.dll stdcall';

procedure trampoline(hwnd: hwnd; milliseconds: uint);
    external 'trampoline@files:trampoline.dll cdecl setuponly';

{
{ Translation support
}
function _(src: string): string;
begin
    result := src;
    stringchangeex(result, '\n', #13#10, true);
end;

{
{ Visit the project homepage
}
procedure visit_homepage(sender: tobject);
var
    ret: integer;
begin
    shellexec('open', 'http://wincompose.info/', '', '', sw_show, ewnowait, ret);
end;

{
{ Download .NET Framework 3.5 SP1
}
procedure download_dotnet(sender: tobject);
var
    ret: integer;
begin
    { ID 22 is Service Pack 1, 21 would be the original .NET 3.5. }
    shellexec('open', 'https://www.microsoft.com/en-us/download/details.aspx?id=22',
              '', '', sw_show, ewnowait, ret);
end;

{
{ Check the .NET Framework installation state
}
function get_dotnet_state(): integer;
var
    framework_names: tarrayofstring;
    path, version: string;
begin
    path := 'SOFTWARE\Microsoft\NET Framework Setup\NDP\';
    if not(reggetsubkeynames(HKLM, path, framework_names))
       or (getarraylength(framework_names) = 0) then begin
        { No such path in registry, or no frameworks found }
        result := -1;
    end;
end;

{
{ Initialize installer state.
}
procedure InitializeWizard;
var
    i: integer;
    homepage: tnewstatictext;
begin
    state := s_run_1;
    for i := 1 to paramcount do
        if comparetext(paramstr(i), '/elevate') = 0 then state := s_run_2;

    { Add a link to the homepage at the bottom of the installer window }
    homepage := tnewstatictext.create(wizardform);
    homepage.caption := 'http://wincompose.info/';
    homepage.cursor := crhand;
    homepage.onclick := @visit_homepage;
    homepage.parent := wizardform;
    homepage.font.style := homepage.font.style + [fsunderline];
    homepage.font.color := clblue;
    homepage.top := wizardform.cancelbutton.top
                  + wizardform.cancelbutton.height
                  - homepage.height - 2;
    homepage.left := scalex(20);

    { Create an optional page for .NET detection and installation }
    dotnet_page := createcustompage(wpwelcome, _('Prerequisites'),
                                    _('Software required by WinCompose'));

    warning := tnewstatictext.create(dotnet_page);
    warning.caption := _('WinCompose needs the .NET Framework, version 3.5 SP1 or later, which does not\n'
                       + 'seem to be currently installed. The following action may help solve the problem:');
    warning.parent := dotnet_page.surface;

    action := tnewstatictext.create(dotnet_page);
    action.caption := _('Download and install .NET Framework 3.5 Service Pack 1');
    action.parent := dotnet_page.surface;
    action.cursor := crhand;
    action.onclick := @download_dotnet;
    action.font.style := action.font.style + [fsunderline];
    action.font.color := clblue;
    action.left := scalex(10);
    action.top := warning.top + warning.height + scaley(10);

    hint := tnewstatictext.create(dotnet_page);
    hint.caption := _('Once this is done, you may return to this screen and proceed with the\n'
                    + 'installation.');
    hint.parent := dotnet_page.surface;
    hint.font.style := hint.font.style + [fsbold];
    hint.top := action.top + action.height + scaley(20);
end;

{
{ If we're in the target directory selection page, check that we
{ can actually install files in that directory. Otherwise, we hijack
{ NextButtonClick() to re-execute ourselves in admin mode.
}
function NextButtonClick(page_id: integer): boolean;
var
    e1: boolean;
    e2: thandle;
begin
    result := true;
    if (state = s_run_1) and (page_id = wpselectdir) then
    begin
        createdir(expandconstant('{app}'));
        e1 := savestringtofile(expandconstant('{app}/.stamp'), '', false);
        deletefile(expandconstant('{app}/.stamp'));
        deltree(expandconstant('{app}'), true, false, false);
        if e1 then exit;

        e2 := reexec(wizardform.handle, 'runas', expandconstant('{srcexe}'),
                     expandconstant('/dir="{app}" /elevate'), '', sw_show);
        if e2 > 32 then exit_process(0);

        result := false;
        msgbox(format(_('Administrator rights are required. Error: %d'), [e2]),
               mberror, MB_OK);
    end;
end;

{
{ Broadcast the WM_WINCOMPOSE_EXIT message for all WinCompose instances
{ to shutdown themselves.
}
function PrepareToInstall(var needsrestart: boolean): string;
var
    dummy: integer;
begin
    postbroadcastmessage(registerwindowmessage('WM_WINCOMPOSE_EXIT'), 0, 0);
    sleep(1000);
    exec('>', 'cmd.exe /c taskkill /f /im {#NAME}.exe', '',
         SW_HIDE, ewwaituntilterminated, dummy);
end;

{
{ Refresh the .NET page
}
procedure refresh_dotnet_page(sender: tobject; var key: word; shift: tshiftstate);
begin
    if wizardform.curpageid = dotnet_page.id then
    begin
        if (get_dotnet_state() < 0) then begin
            wizardform.nextbutton.enabled := false;
            action.visible := true;
            hint.visible := true;
        end else begin
            wizardform.nextbutton.enabled := true;
            warning.caption := 'All prerequisites were found!';
            action.visible := false;
            hint.visible := false;
        end;
    end;
end;

{
{ Optionally tweak the current page
}
procedure CurPageChanged(page_id: integer);
begin
    if (page_id = dotnet_page.id) then begin
        { Trigger refresh_dotnet_page() every second }
        wizardform.onkeyup := @refresh_dotnet_page;
        trampoline(wizardform.handle, 1000);
    end else begin
        wizardform.onkeyup := nil;
        trampoline(0, 0);
    end;
end;

{
{ If running elevated and we haven't reached the directory selection page,
{ skip all pages, including the directory selection page.
}
function ShouldSkipPage(page_id: integer): boolean;
begin
    { If this is the .NET page, decide whether to show it or not! }
    if (state = s_run_1) and (page_id = dotnet_page.id) then begin
        result := (get_dotnet_state() = 0);
        exit;
    end;

    result := (state = s_run_2) and (page_id <= wpselectdir);
    if (state = s_run_2) and (page_id = wpselectdir) then
        state := s_skipped;
end;

