defmodule GSMLG.BrowserAgent.Backend do
  @moduledoc "Boundary for the remote browser profile manager."

  alias GSMLG.BrowserAgent.Settings

  @type result :: {:ok, map() | [map()] | ControlConnection.t()} | {:error, map()}

  @callback manager_status(Settings.t(), keyword()) :: result()
  @callback list_profiles(Settings.t(), keyword()) :: result()
  @callback get_profile(Settings.t(), String.t(), keyword()) :: result()
  @callback profile_status(Settings.t(), String.t(), keyword()) :: result()
  @callback launch_profile(Settings.t(), String.t(), keyword()) :: result()
  @callback stop_profile(Settings.t(), String.t(), keyword()) :: result()
  @callback open_session(Settings.t(), String.t(), keyword()) :: result()
  @callback close_session(Settings.t(), map(), keyword()) :: result()
  @callback connect_control_protocol(Settings.t(), map(), keyword()) :: result()

  @optional_callbacks open_session: 3, close_session: 3, connect_control_protocol: 3
end

defmodule GSMLG.BrowserAgent.Backend.ControlConnection do
  @moduledoc false

  @enforce_keys [:url, :headers]
  defstruct [:url, :headers]

  @type t :: %__MODULE__{url: String.t(), headers: [{String.t(), String.t()}]}
end

defimpl Inspect, for: GSMLG.BrowserAgent.Backend.ControlConnection do
  import Inspect.Algebra

  def inspect(_connection, _opts),
    do: concat(["#GSMLG.BrowserAgent.Backend.ControlConnection<redacted>"])
end
