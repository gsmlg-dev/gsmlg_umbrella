defmodule GSMLG.BrowserAgent.Backends.CloakBrowser.Transport do
  @moduledoc false

  @callback request(
              :get | :post,
              String.t(),
              [{String.t(), String.t()}],
              binary(),
              keyword()
            ) :: {:ok, %{status: pos_integer(), body: binary()}} | {:error, atom()}
end
