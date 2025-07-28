defmodule GSMLG.AWS.ErrorHandler do
  @moduledoc """
  Centralized error handling for AWS operations.
  """

  require Logger

  @doc """
  Handles AWS API errors with consistent logging and error formatting.
  """
  def handle_aws_error(operation, context, error) do
    case error do
      %{code: code, message: message} ->
        Logger.error("AWS #{operation} error",
          context: context,
          code: code,
          message: message,
          service: Map.get(context, :service, "unknown")
        )

        {:error, format_aws_error(code, message)}

      {:error, %{code: code, message: message}} ->
        Logger.error("AWS #{operation} error",
          context: context,
          code: code,
          message: message,
          service: Map.get(context, :service, "unknown")
        )

        {:error, format_aws_error(code, message)}

      {:error, :rate_limited} ->
        Logger.warning("AWS #{operation} rate limit exceeded", context: context)
        {:error, :rate_limited}

      {:error, error} when is_binary(error) ->
        Logger.error("AWS #{operation} error",
          context: context,
          message: error
        )

        {:error, error}

      {:error, error} ->
        Logger.error("AWS #{operation} unexpected error",
          context: context,
          error: inspect(error)
        )

        {:error, :unexpected_error}

      error ->
        Logger.error("AWS #{operation} unexpected response",
          context: context,
          response: inspect(error)
        )

        {:error, :unexpected_response}
    end
  end

  @doc """
  Formats AWS error messages for user-friendly display.
  """
  def format_aws_error(code, message) do
    case code do
      "NoSuchHostedZone" -> "Hosted zone not found"
      "InvalidInput" -> "Invalid input: #{message}"
      "AccessDenied" -> "Access denied - check AWS credentials"
      "Throttling" -> "Rate limit exceeded - please try again later"
      "NoSuchBucket" -> "Bucket not found"
      "NoSuchKey" -> "Object not found"
      _ -> message || "AWS error occurred"
    end
  end

  @doc """
  Validates AWS operation parameters and returns appropriate error responses.
  """
  def validate_params(params, validations) do
    Enum.reduce_while(validations, :ok, fn {key, validator}, _acc ->
      case validator.(Map.get(params, key)) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  @doc """
  Wraps AWS operations with standardized error handling.
  """
  def with_error_handling(operation, context, fun) do
    try do
      case fun.() do
        {:ok, result} -> {:ok, result}
        {:ok, result, _} -> {:ok, result}
        {:error, error} -> handle_aws_error(operation, context, {:error, error})
        error -> handle_aws_error(operation, context, error)
      end
    rescue
      error in ArgumentError ->
        Logger.error("AWS #{operation} argument error",
          context: context,
          error: Exception.message(error)
        )

        {:error, Exception.message(error)}

      error ->
        Logger.error("AWS #{operation} exception",
          context: context,
          error: inspect(error)
        )

        {:error, :internal_error}
    end
  end
end
