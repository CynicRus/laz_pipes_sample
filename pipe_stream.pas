unit pipe_stream;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils
  {$IFDEF UNIX}
  , BaseUnix, pthreads, cmem
  {$IFNDEF DARWIN}
  ,linux
  {$ENDIF}
  {$ENDIF}
  {$IFDEF WINDOWS}
  , Windows
  {$ENDIF}
  ;

type
  TPipeState = (StateStartConnect, StateConnecting, StateConnected,
    StateReading, StateHaveData, StateReadFinished, StateDisconnected);
  TPipeMode = (pmSender, pmReceiver, pmBoth);
  EUnsupportedOperation = Exception;

  { TPipeStream}

  TPipeStream = class(TStream)
  protected
    FHandle: THandle;
    FMode: TPipeMode;
    FState: TPipeState;
    {$IFDEF UNIX}
    FMutex: TRTLCriticalSection;
    FCondVar: pthread_cond_t;
    {$ELSE}
    FMutex: THandle;
    FEvent: THandle;
    {$ENDIF}
    function IsDataAvailable: boolean;virtual;
  public
    constructor Create(Mode: TPipeMode);
    destructor Destroy; override;
    function WaitForData(Timeout: DWORD): boolean; virtual;
    function Read(var Buffer; Count: longint): longint; override;
    function Write(const Buffer; Count: longint): longint; override;
    function Seek(const Offset: int64; Origin: TSeekOrigin): int64; override;
    procedure SetSize(NewSize: longint); override;
    procedure SetSize(const NewSize: int64); override;
  end;

  { TNamedPipeStream }

  TNamedPipeStream = class(TPipeStream)
  private
    FPipeName: string;
  public
    constructor Create(const PipeName: string; Mode: TPipeMode); overload;
    destructor Destroy; override;
  end;

  { TAnonymousPipeStream }

  TAnonymousPipeStream = class(TPipeStream)
  private
    FReadHandle: THandle;
    FWriteHandle: THandle;
    function IsDataAvailable: boolean;override;
  public
    constructor Create(Mode: TPipeMode); overload;
    destructor Destroy; override;
    function Read(var Buffer; Count: longint): longint; override;
    function Write(const Buffer; Count: longint): longint; override;
    function WaitForData(Timeout: DWORD): boolean; override;
  end;

implementation

{ TPipeStream }

function TPipeStream.IsDataAvailable: boolean;
  {$IFDEF UNIX}
var
  fds: TFDSet;
  tv: TTimeVal;
  {$ENDIF}
begin
  {$IFDEF WINDOWS}
  Result := PeekNamedPipe(FHandle, nil, 0, nil, nil, nil);
  {$ENDIF}

  {$IFDEF UNIX}
  fpfd_zero(fds);
  fpfd_set(FHandle, fds);
  tv.tv_sec := 0;
  tv.tv_usec := 0;
  Result := fpSelect(FHandle + 1, @fds, nil, nil, @tv) > 0;
  {$ENDIF}
end;

constructor TPipeStream.Create(Mode: TPipeMode);
  {$IFDEF WINDOWS}
const
  EventName = 'PipeStream';
var
  sd: SECURITY_DESCRIPTOR;
  sa: SECURITY_ATTRIBUTES;
  {$ENDIF}
begin
  inherited Create;
  FMode := Mode;
  FState := StateStartConnect;

  {$IFDEF UNIX}
  InitCriticalSection(FMutex);
  pthread_cond_init(@FCondVar, nil);
  {$ENDIF}

  {$IFDEF WINDOWS}
  InitializeSecurityDescriptor(@sd, SECURITY_DESCRIPTOR_REVISION);
  SetSecurityDescriptorDacl(@sd, TRUE, nil, FALSE);

  sa.nLength := SizeOf(sa);
  sa.bInheritHandle := FALSE;
  sa.lpSecurityDescriptor := @sd;

  FMutex := CreateMutex(nil, False, nil);
  FEvent := CreateEvent(@sa, True, False, @EventName[0]);
  if FEvent = 0 then
    raise Exception.Create('Cannot create event: ' + SysErrorMessage(GetLastError));
  {$ENDIF}
end;

destructor TPipeStream.Destroy;
begin
  FState := StateDisconnected;
  {$IFDEF UNIX}
  if FHandle <> 0 then
    FpClose(FHandle);
  DoneCriticalSection(FMutex);
  pthread_cond_destroy(@FCondVar);
  {$ENDIF}

  {$IFDEF WINDOWS}
  if FHandle <> INVALID_HANDLE_VALUE then
    CloseHandle(FHandle);
  if FMutex <> 0 then
    CloseHandle(FMutex);
  if FEvent <> 0 then
    CloseHandle(FEvent);
  {$ENDIF}
  inherited Destroy;
end;

function TPipeStream.WaitForData(Timeout: DWORD): boolean;
{$IFDEF UNIX}
var
  fds: TFDSet;
  tv: TTimeVal;
{$ENDIF}
begin
  FState := StateReading;

  if IsDataAvailable then
  begin
    Result := True;
    Exit;
  end;

  {$IFDEF WINDOWS}
  WaitForSingleObject(FMutex, INFINITE);
  try
    Result := WaitForSingleObject(FEvent, Timeout) = WAIT_OBJECT_0;
    ResetEvent(FEvent);
  finally
    ReleaseMutex(FMutex);
  end;
  {$ENDIF}

  {$IFDEF UNIX}
  EnterCriticalSection(FMutex);
  try
    fpfd_zero(fds);
    fpfd_set(FHandle, fds);
    tv.tv_sec := Timeout div 1000;
    tv.tv_usec := (Timeout mod 1000) * 1000;
    Result := fpSelect(FHandle + 1, @fds, nil, nil, @tv) > 0;
  finally
    LeaveCriticalSection(FMutex);
  end;
  {$ENDIF}

  if Result then
    FState := StateHaveData
  else
    FState := StateReading;
end;

function TPipeStream.Read(var Buffer; Count: longint): longint;
begin
  if FMode = pmSender then
    raise EUnsupportedOperation.Create('Cannot read in sender mode');

  if not (FState in [StateHaveData, StateConnected]) then
    raise Exception.Create('Invalid state for reading');

  {$IFDEF UNIX}
  EnterCriticalSection(FMutex);
  try
    Result := fpRead(FHandle, Buffer, Count); // Убедитесь в корректности работы
  finally
    LeaveCriticalSection(FMutex);
  end;
  if Result = -1 then
    raise Exception.Create('Error reading from pipe: ' + SysErrorMessage(fpGetErrno()));
  {$ENDIF}

  {$IFDEF WINDOWS}
  WaitForSingleObject(FMutex, INFINITE);
  try
    ReadFile(FHandle, Buffer, Count, DWORD(Result), nil);
  finally
    ReleaseMutex(FMutex);
  end;
  if Result = -1 then
    raise Exception.Create('Error reading from pipe: ' + SysErrorMessage(GetLastError()));
  {$ENDIF}

  if Result > 0 then
    FState := StateHaveData
  else
    FState := StateReadFinished;
end;

function TPipeStream.Write(const Buffer; Count: longint): longint;
  {$IFDEF WINDOWS}
var
  BytesWritten: DWORD;
  {$ENDIF}
begin
  if FMode = pmReceiver then
    raise EUnsupportedOperation.Create('Cannot write in receiver mode');

  if FState <> StateConnected then
    raise Exception.Create('Invalid state for writing');

  {$IFDEF UNIX}
  EnterCriticalSection(FMutex);
  try
    Result := fpWrite(FHandle, Buffer, Count);
    if Result > 0 then
      pthread_cond_signal(@FCondVar); // сигнализируем о новых данных
  finally
    LeaveCriticalSection(FMutex);
  end;
  if Result = -1 then
    raise Exception.Create('Error writing to pipe: ' + SysErrorMessage(fpGetErrno()));
  {$ENDIF}

  {$IFDEF WINDOWS}
  WaitForSingleObject(FMutex, INFINITE);
  try
    WriteFile(FHandle, Buffer, Count, BytesWritten, nil);
    Result := BytesWritten;
    if Result > 0 then
      SetEvent(FEvent);
  finally
    ReleaseMutex(FMutex);
  end;
  if Result = -1 then
    raise Exception.Create('Error writing to pipe: ' + SysErrorMessage(GetLastError()));
  {$ENDIF}
end;

function TPipeStream.Seek(const Offset: int64; Origin: TSeekOrigin): int64;
begin
  raise EUnsupportedOperation.Create('Pipes do not support seeking.');
end;

procedure TPipeStream.SetSize(NewSize: longint);
begin
  raise EUnsupportedOperation.Create('Pipes do not support setting size.');
end;

procedure TPipeStream.SetSize(const NewSize: int64);
begin
  raise EUnsupportedOperation.Create('Pipes do not support setting size.');
end;

{ TNamedPipeStream }

constructor TNamedPipeStream.Create(const PipeName: string; Mode: TPipeMode);
  {$IFDEF UNIX}
var
  Buf: Stat;
  {$ENDIF}
begin
  inherited Create(Mode);
  FPipeName := PipeName;

  {$IFDEF UNIX}
  if fpStat(PChar(FPipeName), Buf) = 0 then
  begin
    case FMode of
      pmSender: FHandle := fpOpen(PChar(FPipeName), O_RDWR);
      pmReceiver: FHandle := fpOpen(PChar(FPipeName), O_RDONLY);
      pmBoth: FHandle := fpOpen(PChar(FPipeName), O_RDWR);
    end;

    if FHandle = -1 then
      raise Exception.Create('Cannot open existing pipe: ' + SysErrorMessage(fpGetErrno));
  end
  else
  begin
    if fpMkfifo(PChar(FPipeName), &666) <> 0 then
      raise Exception.Create('Cannot create named pipe: ' + SysErrorMessage(fpGetErrno));

    case FMode of
      pmSender: FHandle := fpOpen(PChar(FPipeName), O_RDWR);
      pmReceiver: FHandle := fpOpen(PChar(FPipeName), O_RDONLY);
      pmBoth: FHandle := fpOpen(PChar(FPipeName), O_RDWR);
    end;

    if FHandle = -1 then
      raise Exception.Create('Cannot open pipe: ' + SysErrorMessage(fpGetErrno));
  end;
  FState := StateConnected;
  {$ENDIF}

  {$IFDEF WINDOWS}
  if WaitNamedPipe(PChar('\\.\pipe\' + FPipeName), NMPWAIT_USE_DEFAULT_WAIT) then
  begin
    case FMode of
      pmSender:
        FHandle := CreateFile(PChar('\\.\pipe\' + FPipeName),
          GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
      pmReceiver:
        FHandle := CreateFile(PChar('\\.\pipe\' + FPipeName),
          GENERIC_READ, 0, nil, OPEN_EXISTING, 0, 0);
      pmBoth:
        FHandle := CreateFile(PChar('\\.\pipe\' + FPipeName),
          GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
    end;
  end
  else
  begin
    case FMode of
      pmSender:
        FHandle := CreateNamedPipe(PChar('\\.\pipe\' + FPipeName),
          PIPE_ACCESS_OUTBOUND, PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_NOWAIT,
          1, 1024 * 16, 1024 * 16, NMPWAIT_USE_DEFAULT_WAIT, nil);
      pmReceiver:
        FHandle := CreateFile(PChar('\\.\pipe\' + FPipeName),
          GENERIC_READ, 0, nil, OPEN_EXISTING, 0, 0);
      pmBoth:
        FHandle := CreateNamedPipe(PChar('\\.\pipe\' + FPipeName),
          PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_NOWAIT,
          1, 1024 * 16, 1024 * 16, NMPWAIT_USE_DEFAULT_WAIT, nil);
    end;

    if FMode in [pmSender, pmBoth] then
    begin
      ConnectNamedPipe(FHandle, nil);
      FState := StateConnected;
    end;
  end;

  if FHandle = INVALID_HANDLE_VALUE then
    raise Exception.Create('Cannot create or open pipe: ' + SysErrorMessage(GetLastError));
  {$ENDIF}
end;

destructor TNamedPipeStream.Destroy;
begin
  {$IFDEF UNIX}
  FpUnlink(PChar(FPipeName));
  {$ENDIF}
  inherited Destroy;
end;

{ TAnonymousPipeStream }

function TAnonymousPipeStream.IsDataAvailable: boolean;
  {$IFDEF UNIX}
var
  fds: TFDSet;
  tv: TTimeVal;
  {$ENDIF}
begin
  if FMode in [pmReceiver,pmBoth] then
  begin
  {$IFDEF WINDOWS}
  Result := PeekNamedPipe(FReadHandle, nil, 0, nil, nil, nil);
  {$ENDIF}

  {$IFDEF UNIX}
  fpfd_zero(fds);
  fpfd_set(FHandle, fds);
  tv.tv_sec := 0;
  tv.tv_usec := 0;
  Result := fpSelect(FHandle + 1, @fds, nil, nil, @tv) > 0;
  {$ENDIF}
  end;
end;

constructor TAnonymousPipeStream.Create(Mode: TPipeMode);
var
  {$IFDEF UNIX}
  PipeHandles: TFilDes;
  {$ELSE}
  Security: TSecurityAttributes;
  {$ENDIF}
begin
  inherited Create(Mode);
  FMode := Mode;

  {$IFDEF UNIX}
  if fpPipe(PipeHandles) <> 0 then
    raise Exception.Create('Cannot create anonymous pipe: ' + SysErrorMessage(fpGetErrno));

  case FMode of
    pmSender:
      FWriteHandle := PipeHandles[1];
    pmReceiver:
      FReadHandle := PipeHandles[0];
    pmBoth:
      begin
        FReadHandle := PipeHandles[0];
        FWriteHandle := PipeHandles[1];
      end;
  end;
  {$ENDIF}

  {$IFDEF WINDOWS}
  Security.nLength := SizeOf(TSecurityAttributes);
  Security.bInheritHandle := True;
  Security.lpSecurityDescriptor := nil;

  if not CreatePipe(FReadHandle, FWriteHandle, @Security, 0) then
    raise Exception.Create('Cannot create anonymous pipe: ' + SysErrorMessage(GetLastError));

  FMutex := CreateMutex(nil, False, nil);
  FEvent := CreateEvent(nil, True, False, nil);
  {$ENDIF}

  FState := StateConnected;
end;

destructor TAnonymousPipeStream.Destroy;
begin
  {$IFDEF UNIX}
  if FReadHandle <> 0 then
    FpClose(FReadHandle);
  if FWriteHandle <> 0 then
    FpClose(FWriteHandle);
  {$ENDIF}

  {$IFDEF WINDOWS}
  if FReadHandle <> INVALID_HANDLE_VALUE then
    CloseHandle(FReadHandle);
  if FWriteHandle <> INVALID_HANDLE_VALUE then
    CloseHandle(FWriteHandle);
  if FMutex <> INVALID_HANDLE_VALUE then
    CloseHandle(FMutex);
  if FEvent <> INVALID_HANDLE_VALUE then
    CloseHandle(FEvent);
  {$ENDIF}

  inherited Destroy;
end;

function TAnonymousPipeStream.Read(var Buffer; Count: longint): longint;
  {$IFDEF WINDOWS}
var
  BytesRead: DWORD;
  {$ENDIF}
begin
  if FMode = pmSender then
    raise EUnsupportedOperation.Create('Cannot read in sender mode');

  if not (FState in [StateHaveData, StateConnected]) then
    raise Exception.Create('Invalid state for reading');

  {$IFDEF UNIX}
  EnterCriticalSection(FMutex);
  try
    Result := fpRead(FReadHandle, Buffer, Count);
  finally
    LeaveCriticalSection(FMutex);
  end;
  if Result = -1 then
    raise Exception.Create('Error reading from pipe: ' + SysErrorMessage(fpGetErrno));
  {$ENDIF}

  {$IFDEF WINDOWS}
  WaitForSingleObject(FMutex, INFINITE);
  try
    BytesRead := 0;
    if not ReadFile(FReadHandle, Buffer, Count, BytesRead, nil) then
      raise Exception.Create('Error reading from pipe: ' + SysErrorMessage(GetLastError));
    Result := BytesRead;
  finally
    ReleaseMutex(FMutex);
  end;
  {$ENDIF}

  if Result > 0 then
    FState := StateHaveData
  else
    FState := StateReadFinished;
end;

function TAnonymousPipeStream.Write(const Buffer; Count: longint): longint;
  {$IFDEF WINDOWS}
var
  BytesWritten: DWORD;
  {$ENDIF}
begin
  if FMode = pmReceiver then
    raise EUnsupportedOperation.Create('Cannot write in receiver mode');

  if FState <> StateConnected then
    raise Exception.Create('Invalid state for writing');

  {$IFDEF UNIX}
  EnterCriticalSection(FMutex);
  try
    Result := fpWrite(FWriteHandle, Buffer, Count);
  finally
    LeaveCriticalSection(FMutex);
  end;
  if Result = -1 then
    raise Exception.Create('Error writing to pipe: ' + SysErrorMessage(fpGetErrno));
  {$ENDIF}

  {$IFDEF WINDOWS}
  BytesWritten := 0;
  WaitForSingleObject(FMutex, INFINITE);
  try
    if not WriteFile(FWriteHandle, Buffer, Count, BytesWritten, nil) then
      raise Exception.Create('Error writing to pipe: ' + SysErrorMessage(GetLastError));
    Result := BytesWritten;
    if Result > 0 then
      SetEvent(FEvent);
  finally
    ReleaseMutex(FMutex);
  end;
  {$ENDIF}
end;

function TAnonymousPipeStream.WaitForData(Timeout: DWORD): boolean;
  {$IFDEF UNIX}
var
  fds: TFDSet;
  tv: TTimeVal;
  {$ENDIF}
begin
  if FMode = pmSender then
    raise EUnsupportedOperation.Create('Cannot wait for data in sender mode');

  if IsDataAvailable then
  begin
    Result := True;
    Exit;
  end;

  {$IFDEF WINDOWS}
  WaitForSingleObject(FMutex, INFINITE);
  try
    Result := WaitForSingleObject(FEvent, Timeout) = WAIT_OBJECT_0;
    ResetEvent(FEvent);
  finally
    ReleaseMutex(FMutex);
  end;
  {$ENDIF}

  {$IFDEF UNIX}
  EnterCriticalSection(FMutex);
  try
    fpFD_ZERO(fds);
    fpFD_SET(FReadHandle, fds);
    tv.tv_sec := Timeout div 1000;
    tv.tv_usec := (Timeout mod 1000) * 1000;
    Result := fpSelect(FReadHandle + 1, @fds, nil, nil, @tv) > 0;
  finally
    LeaveCriticalSection(FMutex);
  end;
  {$ENDIF}

  if Result then
    FState := StateHaveData
  else
    FState := StateReading;
end;


end.
