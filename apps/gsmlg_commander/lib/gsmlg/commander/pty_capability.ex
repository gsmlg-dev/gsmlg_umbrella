defmodule GSMLG.Commander.PTYCapability do
  @moduledoc "Descriptor for the existing PTY channel; PTY bytes never use capability RPC."

  alias GSMLG.Commander.Protocol.Capability

  def descriptor do
    %Capability{
      id: "pty.shell",
      version: 1,
      backend: "native",
      operations: [],
      limits: %{},
      workflows: []
    }
  end

  def handle_rpc(_request), do: {:error, %{code: "pty_uses_terminal_channel"}}
end
