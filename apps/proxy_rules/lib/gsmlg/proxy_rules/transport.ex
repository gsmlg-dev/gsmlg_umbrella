defmodule GSMLG.ProxyRules.Transport do
  @moduledoc """
  HTTP transport boundary used by remote proxy-rule sources.
  """

  @type header :: {binary(), binary()}
  @type response :: %{
          required(:status) => pos_integer(),
          required(:headers) => [header()],
          required(:body) => binary()
        }
  @type error_reason ::
          :invalid_options
          | :invalid_url
          | :invalid_headers
          | :headers_too_large
          | :timeout
          | :connect_timeout
          | :receive_timeout
          | :connection_failed
          | :transport_error
          | :http_error
          | :body_too_large

  @error_reasons [
    :invalid_options,
    :invalid_url,
    :invalid_headers,
    :headers_too_large,
    :timeout,
    :connect_timeout,
    :receive_timeout,
    :connection_failed,
    :transport_error,
    :http_error,
    :body_too_large
  ]

  @doc "Returns every finite error reason exposed by transport implementations."
  @spec error_reasons() :: [error_reason()]
  def error_reasons, do: @error_reasons

  @doc "Returns whether a value is a finite transport error reason."
  @spec valid_error_reason?(term()) :: boolean()
  def valid_error_reason?(reason), do: reason in @error_reasons

  @callback get(String.t(), [header()], keyword()) ::
              {:ok, response()} | {:error, error_reason()}
end
