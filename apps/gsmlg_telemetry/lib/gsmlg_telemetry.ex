defmodule GSMLGTelemetry do
  @moduledoc """
  Convenience module for GSMLG.Telemetry.

  This module provides a shorter alias for the main telemetry module.
  """

  defdelegate log(level, message, opts \\ []), to: GSMLG.Telemetry
  defdelegate emit(event_name, measurements \\ %{}, metadata \\ %{}), to: GSMLG.Telemetry
  defdelegate span(event_name, metadata, function), to: GSMLG.Telemetry
  defdelegate span_with_metadata(event_name, base_metadata, function), to: GSMLG.Telemetry
  defdelegate config(), to: GSMLG.Telemetry
  defdelegate enabled?(level), to: GSMLG.Telemetry
  defdelegate attach_handler(handler_id, event_name, handler_module, handler_config \\ %{}), to: GSMLG.Telemetry
  defdelegate detach_handler(handler_id), to: GSMLG.Telemetry
  defdelegate debug(message, opts \\ []), to: GSMLG.Telemetry
  defdelegate info(message, opts \\ []), to: GSMLG.Telemetry
  defdelegate warn(message, opts \\ []), to: GSMLG.Telemetry
  defdelegate error(message, opts \\ []), to: GSMLG.Telemetry
end