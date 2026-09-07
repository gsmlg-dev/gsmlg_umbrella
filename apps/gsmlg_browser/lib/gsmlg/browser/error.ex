defmodule GSMLG.Browser.Error do
  @moduledoc "Stable, redacted errors returned by the Browser public facade."

  @enforce_keys [:class, :code, :message, :retryable, :human_action, :details]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          class: String.t(),
          code: String.t(),
          message: String.t(),
          retryable: boolean(),
          human_action: String.t(),
          details: map()
        }

  def new(class, code, message, retryable, human_action, details \\ %{})
      when is_binary(class) and is_binary(code) and is_binary(message) and is_boolean(retryable) and
             is_binary(human_action) and is_map(details) do
    %__MODULE__{
      class: class,
      code: code,
      message: message,
      retryable: retryable,
      human_action: human_action,
      details: details
    }
  end
end
