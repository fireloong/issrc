unit ScriptCompiler;

{
  Inno Setup
  Copyright (C) 1997-2010 Jordan Russell
  Portions by Martijn Laan
  For conditions of distribution and use, see LICENSE.TXT.

  Script compiler

  $jrsoftware: issrc/Projects/ScriptCompiler.pas,v 1.22 2010/11/13 06:02:48 jr Exp $
}

interface

uses
  Classes, uPSUtils;

type
  TScriptCompilerOnLineToLineInfo = procedure(const Line: LongInt; var Filename: String; var FileLine: LongInt) of object;
  TScriptCompilerOnUsedLine = procedure(const Filename: String; const Line, Position: LongInt) of object;
  TScriptCompilerOnUsedVariable = procedure(const Filename: String; const Line, Col, Param1, Param2, Param3: LongInt; const Param4: AnsiString) of object;
  TScriptCompilerOnError = procedure(const Msg: String; const ErrorFilename: String; const ErrorLine: LongInt) of object;
  TScriptCompilerOnWarning = procedure(const Msg: String) of object;

  TScriptCompiler = class
    private
      FNamingAttribute: String;
      FExports, FUsedLines: TList;
      FFunctionsFound: TStringList;
      FScriptText: AnsiString;
      FOnLineToLineInfo: TScriptCompilerOnLineToLineInfo;
      FOnUsedLine: TScriptCompilerOnUsedLine;
      FOnUsedVariable: TScriptCompilerOnUsedVariable;
      FOnError: TScriptCompilerOnError;
      FOnWarning: TScriptCompilerOnWarning;
      function FindExport(const Name, Decl: String; const IgnoreIndex: Integer): Integer;
      function GetExportCount: Integer;
      procedure PSPositionToLineCol(Position: LongInt; var Line, Col: LongInt);
    public
      constructor Create;
      destructor Destroy; override;
      procedure AddExport(const Name, Decl: String; const AllowNamingAttribute, Required: Boolean; const RequiredFilename: String; const RequiredLine: LongInt);
      function CheckExports: Boolean;
      function Compile(const ScriptText: String; var CompiledScriptText, CompiledScriptDebugInfo: tbtString): Boolean;
      property ExportCount: Integer read GetExportCount;
      function ExportFound(const Name: String): Boolean;
      function FunctionFound(const Name: String): Boolean;
      property NamingAttribute: String write FNamingAttribute;
      property OnLineToLineInfo: TScriptCompilerOnLineToLineInfo write FOnLineToLineInfo;
      property OnUsedLine: TScriptCompilerOnUsedLine write FOnUsedLine;
      property OnUsedVariable: TScriptCompilerOnUsedVariable write FOnUsedVariable;
      property OnError: TScriptCompilerOnError write FOnError;
      property OnWarning: TScriptCompilerOnWarning write FOnWarning;
  end;

implementation

uses
  SysUtils,
  uPSCompiler, uPSC_dll,
  ScriptClasses_C, ScriptFunc_C;

type
  TScriptExport = class
    Name, Decl: String;
    AllowNamingAttribute: Boolean;
    Required: Boolean;
    RequiredFilename: String;
    RequiredLine: LongInt;
    Exported: Boolean;
  end;

{---}

function PSPascalCompilerOnExternalProc(Sender: TPSPascalCompiler; Decl: TPSParametersDecl; const Name, FExternal: tbtstring): TPSRegProc; 
var
  S: String;
  P: Integer;
begin
  S := String(FExternal) + ' ';
  P := Pos(' setuponly ', S);
  if P > 0 then begin
    Delete(S, P+1, Length('setuponly '));
    Insert('setup:', S, Pos('@', S)+1);
  end
  else begin
    P := Pos(' uninstallonly ', S);
    if P > 0 then begin
      Delete(S, P+1, Length('uninstallonly '));
      Insert('uninstall:', S, Pos('@', S)+1);
    end;
  end;
  if Pos('@uninstall:files:', S) <> 0 then begin
    Sender.MakeError('', ecCustomError, '"uninstallonly" cannot be used with "files:"');
    Result := nil;
    Exit;
  end;
  Result := DllExternalProc(Sender, Decl, Name, tbtstring(TrimRight(S)));
end;

function PSPascalCompilerOnApplyAttributeToProc(Sender: TPSPascalCompiler; aProc: TPSProcedure; Attr: TPSAttribute): Boolean;
var
  ScriptCompiler: TScriptCompiler;
  AttrValue: String;
  ScriptExport: TScriptExport;
  B: Boolean;
  I: Integer;
begin
  ScriptCompiler := TScriptCompiler(Sender.ID);
  if CompareText(String(Attr.AType.Name), ScriptCompiler.FNamingAttribute) = 0 then begin
    if (aProc.ClassType <> TPSInternalProcedure) then begin
      with Sender.MakeError('', ecCustomError, tbtstring('"' + ScriptCompiler.FNamingAttribute + '" attribute cannot be used on external function or procedure')) do
        SetCustomPos(Attr.DeclarePos, Attr.DeclareRow, Attr.DeclareCol);
      Result := False;
    end else if Attr.Count <> 1 then begin
      with Sender.MakeError('', ecCustomError, tbtstring('"' + ScriptCompiler.FNamingAttribute + '" attribute value not found')) do
        SetCustomPos(Attr.DeclarePos, Attr.DeclareRow, Attr.DeclareCol);
      Result := False;
    end else begin
      if ScriptCompiler.FindExport(String(TPSInternalProcedure(aProc).Name), '', -1) <> -1 then begin
        { Don't allow attributes on functions already matching an export so that we don't have to deal with this later. }
        with Sender.MakeError('', ecCustomError, tbtstring('"' + ScriptCompiler.FNamingAttribute + '" attribute not allowed for function or procedure "' + String(TPSInternalProcedure(aProc).Name) + '"')) do
          SetCustomPos(Attr.DeclarePos, Attr.DeclareRow, Attr.DeclareCol);
        Result := False;
      end else begin
        AttrValue := String(GetString(Attr.Values[0], B));
        I := ScriptCompiler.FindExport(AttrValue, String(Sender.MakeDecl(TPSInternalProcedure(aProc).Decl)), -1);
        if I <> -1 then begin
          ScriptExport := ScriptCompiler.FExports[I];
          if not ScriptExport.AllowNamingAttribute then begin
            with Sender.MakeError('', ecCustomError, tbtstring('"' + ScriptCompiler.FNamingAttribute + '" attribute value "' + AttrValue + '" not allowed')) do
              SetCustomPos(Attr.DeclarePos, Attr.DeclareRow, Attr.DeclareCol);
            Result := False;
          end else begin
            ScriptExport.Exported := True;
            Result := True;
          end;
        end else if ScriptCompiler.FindExport(AttrValue, '', -1) <> -1 then begin
          with Sender.MakeError('', ecCustomError, tbtstring('Invalid function or procedure prototype for attribute value "' + AttrValue + '"')) do
            SetCustomPos(TPSInternalProcedure(aProc).DeclarePos, TPSInternalProcedure(aProc).DeclareRow, TPSInternalProcedure(aProc).DeclareCol);
          Result := False;
        end else begin
          with Sender.MakeError('', ecCustomError, tbtstring('"' + ScriptCompiler.FNamingAttribute + '" attribute value "' + AttrValue + '"  invalid')) do
            SetCustomPos(Attr.DeclarePos, Attr.DeclareRow, Attr.DeclareCol);
          Result := False;
        end;
      end;
    end;
  end else
    Result := True;
end;

function PSPascalCompilerOnApplyAttributeToType(Sender: TPSPascalCompiler; aType: TPSType; Attr: TPSAttribute): Boolean;
var
  NamingAttribute: String;
begin
  NamingAttribute := TScriptCompiler(Sender.ID).FNamingAttribute;
  if (CompareText(String(Attr.AType.Name), NamingAttribute) = 0)  then begin
    with Sender.MakeError('', ecCustomError, tbtstring('"' + NamingAttribute + '" attribute cannot be used on types')) do
      SetCustomPos(Attr.DeclarePos, Attr.DeclareRow, Attr.DeclareCol);
    Result := False;
  end else
    Result := True;
end;

function PSPascalCompilerOnUses(Sender: TPSPascalCompiler; const Name: tbtstring): Boolean;
var
  NamingAttribute: String;
begin
  if Name = 'SYSTEM' then begin
    RegisterDll_Compiletime(Sender);
    Sender.OnExternalProc := PSPascalCompilerOnExternalProc;
    ScriptClassesLibraryRegister_C(Sender);
    ScriptFuncLibraryRegister_C(Sender);
    NamingAttribute := TScriptCompiler(Sender.ID).FNamingAttribute;
    if NamingAttribute <> '' then begin
      with Sender.AddAttributeType do
      begin
        OrgName := tbtstring(NamingAttribute);
        with AddField do
        begin
          FieldOrgName := 'Name';
          FieldType := Sender.FindType('String');
        end;
        OnApplyAttributeToProc := PSPascalCompilerOnApplyAttributeToProc;
        OnApplyAttributeToType := PSPascalCompilerOnApplyAttributeToType;
      end;
    end;
    Result := True;
  end else begin
    Sender.MakeError('', ecUnknownIdentifier, '');
    Result := False;
  end;
end;

function PSPascalCompilerOnExportCheck(Sender: TPSPascalCompiler; Proc: TPSInternalProcedure; const ProcDecl: tbtstring): Boolean;
var
  ScriptCompiler: TScriptCompiler;
  ScriptExport: TScriptExport;
  I: Integer;
begin
  ScriptCompiler := TScriptCompiler(Sender.ID);

  ScriptCompiler.FFunctionsFound.Add(String(Proc.Name));

  { Try and see if the [Code] function matches an export name and if so,
    see if one of the prototypes for that name matches }

  I := ScriptCompiler.FindExport(String(Proc.Name), String(Procdecl), -1);
  if I <> -1 then begin
    ScriptExport := ScriptCompiler.FExports[I];
    ScriptExport.Exported := True;
    Result := True;
  end else if ScriptCompiler.FindExport(String(Proc.Name), '', -1) <> -1 then begin
    with Sender.MakeError('', ecCustomError, tbtstring(Format('Invalid prototype for ''%s''', [Proc.OriginalName]))) do
      SetCustomPos(Proc.DeclarePos, Proc.DeclareRow, Proc.DeclareCol);
    Result := False;
  end else
    Result := True;
end;

function PSPascalCompilerOnBeforeOutput(Sender: TPSPascalCompiler): Boolean;
var
  ScriptCompiler: TScriptCompiler;
  ScriptExport: TScriptExport;
  I: Integer;
  Decl: TPSParametersDecl;
  Msg: String;
begin
  ScriptCompiler := Sender.ID;
  Result := True;

  { Try and see if required but non found exports match any built in function
    names and if so, see if the prototypes also match }

  for I := 0 to ScriptCompiler.FExports.Count-1 do begin
    ScriptExport := ScriptCompiler.FExports[I];
    if ScriptExport.Required and not ScriptExport.Exported then begin
      Decl := Sender.UseExternalProc(tbtstring(ScriptExport.Name));
      if Decl <> nil then begin
        if CompareText(ScriptExport.Decl, String(Sender.MakeDecl(Decl))) = 0 then
          ScriptExport.Exported := True
        else begin
          if Assigned(ScriptCompiler.FOnError) then begin
            Msg := Format('Function or procedure ''%s'' prototype is incompatible', [ScriptExport.Name]);
            ScriptCompiler.FOnError(Msg, ScriptExport.RequiredFilename, ScriptExport.RequiredLine);
          end;
          Result := False;
        end;
      end;
    end;
  end;
end;

function PSPascalCompilerOnWriteLine(Sender: TPSPascalCompiler; Position: Cardinal): Boolean;
var
  ScriptCompiler: TScriptCompiler;
  Filename: String;
  Line, Col: LongInt;
begin
  ScriptCompiler := Sender.ID;

  if Assigned(ScriptCompiler.FOnUsedLine) then begin
    ScriptCompiler.PSPositionToLineCol(Position, Line, Col);
    if ScriptCompiler.FUsedLines.IndexOf(Pointer(Line)) = -1 then begin
      ScriptCompiler.FUsedLines.Add(Pointer(Line));
      Filename := '';
      if Assigned(ScriptCompiler.FOnLineToLineInfo) then
        ScriptCompiler.FOnLineToLineInfo(Line, Filename, Line);
      ScriptCompiler.FOnUsedLine(Filename, Line, Position);
      Result := True;
    end else
      Result := False;
  end else
    Result := True;
end;

procedure PSPascalCompilerOnUseVariable(Sender: TPSPascalCompiler; VarType: TPSVariableType; VarNo: Longint; ProcNo, Position: Cardinal; const PropData: tbtstring); 
var
  ScriptCompiler: TScriptCompiler;
  Filename: String;
  Line, Col: LongInt;
begin
  ScriptCompiler := Sender.ID;

  if Assigned(ScriptCompiler.FOnUsedVariable) then begin
    ScriptCompiler.PSPositionToLineCol(Position, Line, Col);
    Filename := '';
    if Assigned(ScriptCompiler.FOnLineToLineInfo) then
      ScriptCompiler.FOnLineToLineInfo(Line, Filename, Line);
    ScriptCompiler.FOnUsedVariable(Filename, Line, Col, LongInt(VarType), ProcNo, VarNo, PropData);
  end;
end;

{---}

constructor TScriptCompiler.Create;
begin
  FExports := TList.Create();
  FUsedLines := TList.Create();
  FFunctionsFound := TStringList.Create();
end;

destructor TScriptCompiler.Destroy;
var
  I: Integer;
begin
  FFunctionsFound.Free();
  FUsedLines.Free();
  for I := 0 to FExports.Count-1 do
    TScriptExport(FExports[I]).Free();
  FExports.Free();
end;

procedure TScriptCompiler.PSPositionToLineCol(Position: LongInt; var Line, Col: LongInt);

  function FindNewLine(const S: AnsiString; const Start: Integer): Integer;
  var
    I: Integer;
  begin
    for I := Start to Length(S) do
      if S[I] = #10 then begin
        Result := I - Start + 1;
        Exit;
      end;
    Result := 0;
  end;

var
  LineStartPosition, LineLength: LongInt;
begin
  Inc(Position);

  Line := 1;
  LineStartPosition := 1;
  LineLength := FindNewLine(FScriptText, LineStartPosition);

  while (LineLength <> 0) and (Position > LineLength) do begin
    Inc(Line);
    Inc(LineStartPosition, LineLength);
    Dec(Position, LineLength);
    LineLength := FindNewLine(FScriptText, LineStartPosition);
  end;

{$IFDEF UNICODE}
  { Convert Position from the UTF8 encoded ANSI string index to a UTF-16 string index }
  Position := Length(UTF8ToString(Copy(FScriptText, LineStartPosition, Position - 1))) + 1;
{$ENDIF}
  Col := Position;
end;

procedure TScriptCompiler.AddExport(const Name, Decl: String; const AllowNamingAttribute, Required: Boolean; const RequiredFilename: String; const RequiredLine: LongInt);
var
  ScriptExport: TScriptExport;
  I: Integer;
begin
  if AllowNamingAttribute and not ((Pos('0', Decl) = 1) or (Pos('Boolean', Decl) = 1)) then
    raise Exception.Create('Naming attributes only supported on procedures and boolean functions.');

  I := FindExport(Name, Decl, -1);
  if I <> -1 then begin
    ScriptExport := FExports[I];
    if Required and not ScriptExport.Required then begin
      ScriptExport.Required := True;
      ScriptExport.RequiredFilename := RequiredFilename;
      ScriptExport.RequiredLine := RequiredLine;
    end;
    ScriptExport.AllowNamingAttribute := ScriptExport.AllowNamingAttribute and AllowNamingAttribute;
    Exit;
  end;

  ScriptExport := TScriptExport.Create();
  ScriptExport.Name := Name;
  ScriptExport.Decl := Decl;
  ScriptExport.AllowNamingAttribute := AllowNamingAttribute;
  ScriptExport.Required := Required;
  if Required then begin
    ScriptExport.RequiredFilename := RequiredFilename;
    ScriptExport.RequiredLine := RequiredLine;
  end;
  FExports.Add(ScriptExport);
end;

function TScriptCompiler.FindExport(const Name, Decl: String; const IgnoreIndex: Integer): Integer;
var
  ScriptExport: TScriptExport;
  I: Integer;
begin
  for I := 0 to FExports.Count-1 do begin
    ScriptExport := FExports[I];
    if ((Name = '') or (CompareText(ScriptExport.Name, Name) = 0)) and
       ((Decl = '') or (CompareText(ScriptExport.Decl, Decl) = 0)) and
       ((IgnoreIndex = -1) or (I <> IgnoreIndex)) then begin
      Result := 0;
      Exit;
    end;
  end;
  Result := -1;
end;

function TScriptCompiler.CheckExports: Boolean;
var
  ScriptExport: TScriptExport;
  I: Integer;
  Msg: String;
begin
  Result := True;
  for I := 0 to FExports.Count-1 do begin
    ScriptExport := FExports[I];
    if ScriptExport.Required and not ScriptExport.Exported then begin
      if Assigned(FOnError) then begin
        { Either the function wasn't present or it was present but matched another export }
        if FindExport(ScriptExport.Name, '', I) <> -1 then
          Msg := Format('Required function or procedure ''%s'' found but not with a compatible prototype', [ScriptExport.Name])
        else
          Msg := Format('Required function or procedure ''%s'' not found', [ScriptExport.Name]);
        FOnError(Msg, ScriptExport.RequiredFilename, ScriptExport.RequiredLine);
      end;
      Result := False;
      Exit;
    end;
  end;
end;

function TScriptCompiler.Compile(const ScriptText: String; var CompiledScriptText, CompiledScriptDebugInfo: tbtString): Boolean;
var
  PSPascalCompiler: TPSPascalCompiler;
  L, Line, Col: LongInt;
  Filename, Msg: String;
  I: Integer;
begin
  Result := False;

{$IFDEF UNICODE}
  FScriptText := UTF8Encode(ScriptText);
{$ELSE}
  FScriptText := ScriptText;
{$ENDIF}

  for I := 0 to FExports.Count-1 do
    TScriptExport(FExports[I]).Exported := False;
  FFunctionsFound.Clear;

  PSPascalCompiler := TPSPascalCompiler.Create();

  try
    PSPascalCompiler.ID := Self;
    PSPascalCompiler.AllowNoBegin := True;
    PSPascalCompiler.AllowNoEnd := True;
    PSPascalCompiler.BooleanShortCircuit := True;
{$IFDEF UNICODE}
    PSPascalCompiler.AllowDuplicateRegister := False;
    PSPascalCompiler.UTF8Decode := True;
{$ENDIF}
    PSPascalCompiler.AttributesOpenTokenID := CSTI_Less;
    PSPascalCompiler.AttributesCloseTokenID := CSTI_Greater;

    PSPascalCompiler.OnUses := PSPascalCompilerOnUses;
    PSPascalCompiler.OnExportCheck := PSPascalCompilerOnExportCheck;
    PSPascalCompiler.OnBeforeOutput := PSPascalCompilerOnBeforeOutput;
    DefaultCC := ClStdCall;
    FUsedLines.Clear();
    PSPascalCompiler.OnWriteLine := PSPascalCompilerOnWriteLine;
    PSPascalCompiler.OnUseVariable := PSPascalCompilerOnUseVariable;

    if not PSPascalCompiler.Compile(FScriptText) then begin
      if Assigned(FOnError) then begin
        for L := 0 to PSPascalCompiler.MsgCount-1 do begin
          if PSPascalCompiler.Msg[L] is TPSPascalCompilerError then begin
            PSPositionToLineCol(PSPascalCompiler.Msg[L].Pos, Line, Col);
            Filename := '';
            if Assigned(FOnLineToLineInfo) then
              FOnLineToLineInfo(Line, Filename, Line);
            Msg := Format('Column %d:'#13#10'%s', [Col, PSPascalCompiler.Msg[L].ShortMessageToString]);
            FOnError(Msg, Filename, Line);
            Break;
          end;
        end;
      end;
      Exit;
    end else begin
      if not CheckExports() then
        Exit;

      if not PSPascalCompiler.GetOutput(CompiledScriptText) then begin
        if Assigned(FOnError) then begin
          Msg := 'GetOutput failed';
          FOnError(Msg, '', 0);
        end;
        Exit;
      end;

      if not PSPascalCompiler.GetDebugOutput(CompiledScriptDebugInfo) then begin
        if Assigned(FOnError) then begin
          Msg := 'GetDebugOutput failed';
          FOnError(Msg, '', 0);
        end;
        Exit;
      end;

      if Assigned(FOnWarning) then begin
        for L := 0 to PSPascalCompiler.MsgCount-1 do begin
          PSPositionToLineCol(PSPascalCompiler.Msg[L].Pos, Line, Col);
          Filename := '';
          if Assigned(FOnLineToLineInfo) then
            FOnLineToLineInfo(Line, Filename, Line);
          Msg := '';
          if Filename <> '' then
            Msg := Msg + Filename + ', ';
          Msg := Msg + Format('Line %d, Column %d: [%s] %s', [Line, Col,
            PSPascalCompiler.Msg[L].ErrorType,
            PSPascalCompiler.Msg[L].ShortMessageToString]);
          FOnWarning(Msg);
        end;
      end;
    end;

    Result := True;
  finally
    PSPascalCompiler.Free();
  end;
end;

function TScriptCompiler.ExportFound(const Name: String): Boolean;
var
  ScriptExport: TScriptExport;
  I: Integer;
begin
  for I := 0 to FExports.Count-1 do begin
    ScriptExport := FExports[I];
    if CompareText(ScriptExport.Name, Name) = 0 then begin
      Result := ScriptExport.Exported;
      Exit;
    end;
  end;

  Result := False;
end;

function TScriptCompiler.FunctionFound(const Name: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FFunctionsFound.Count-1 do begin
    if CompareText(FFunctionsFound[I], Name) = 0 then begin
      Result := True;
      Break;
    end;
  end;
end;

function TScriptCompiler.GetExportCount: Integer;
begin
  Result := FExports.Count;
end;

end.
