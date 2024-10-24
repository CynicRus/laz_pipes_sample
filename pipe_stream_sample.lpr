program pipe_stream_sample;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  pipe_stream { you can add units after this };

var
  NamedSender, NamedReceiver: TNamedPipeStream;
  AnonymousPipe: TAnonymousPipeStream;
  DataToSend, DataReceived: string;
  Buffer: array[0..255] of char;
  TestCount: integer;

begin
  WriteLn('Testing Named Pipe Streams...');
  DataToSend := 'Hello, Named Pipe!';
  NamedSender := TNamedPipeStream.Create( 'TestPipe',pmSender);
  NamedReceiver := TNamedPipeStream.Create('TestPipe', pmReceiver);
  FillChar(Buffer,SizeOf(Buffer),#0);
  try
    NamedSender.Write(Pointer(DataToSend)^, Length(DataToSend));
    if NamedReceiver.WaitForData(0) then
    begin
      TestCount := NamedReceiver.Read(Buffer, SizeOf(Buffer) - 1);
      if TestCount > 0 then
      begin
        Buffer[TestCount] := #0;
        DataReceived := string(Buffer);
      end;
    end;

    WriteLn('Named Pipe Test:');
    WriteLn('Data Sent: ', DataToSend);
    WriteLn('Data Received: ', DataReceived);
  finally
    NamedSender.Free;
    NamedReceiver.Free;
  end;

  WriteLn('Testing Anonymous Pipe Streams...');
  DataToSend := 'Hello, Anonymous Pipe!';
  AnonymousPipe := TAnonymousPipeStream.Create(pmBoth);

  try
    AnonymousPipe.Write(Pointer(DataToSend)^, Length(DataToSend));
    if AnonymousPipe.WaitForData(0) then
    begin
      TestCount := AnonymousPipe.Read(Buffer, SizeOf(Buffer) - 1);
      if TestCount > 0 then
      begin
        Buffer[TestCount] := #0;
        DataReceived := string(Buffer);
      end;
    end;

    WriteLn('Anonymous Pipe Test:');
    WriteLn('Data Sent: ', DataToSend);
    WriteLn('Data Received: ', DataReceived);
  finally
    AnonymousPipe.Free;
  end;
end.
