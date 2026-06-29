defmodule GSMLG.Scout.Server.TransportDisabled do
  @moduledoc false

  def publish_job(_job) do
    {:error,
     %{
       type: "transport_disabled",
       message: "Scout RabbitMQ transport is disabled",
       retryable: false
     }}
  end
end
