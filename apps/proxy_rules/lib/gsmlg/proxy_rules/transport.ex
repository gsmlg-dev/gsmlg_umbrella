defmodule GSMLG.ProxyRules.Transport do
  @moduledoc """
  HTTP transport boundary used by remote proxy-rule sources.
  """

  @type header :: {binary(), binary()}
  @type response :: %{
          required(:status) => non_neg_integer(),
          required(:headers) => [header()],
          required(:body) => binary()
        }
  @type error_reason ::
          :invalid_options
          | :invalid_url
          | :invalid_headers
          | :timeout
          | :connect_timeout
          | :receive_timeout
          | :connection_failed
          | :transport_error
          | :http_error
          | :body_too_large

  @callback get(String.t(), [header()], keyword()) ::
              {:ok, response()} | {:error, error_reason()}
end
