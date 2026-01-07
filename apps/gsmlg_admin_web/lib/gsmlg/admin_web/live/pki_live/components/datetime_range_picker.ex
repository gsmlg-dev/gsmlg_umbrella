defmodule GSMLG.AdminWeb.PKILive.Components.DateTimeRangePicker do
  @moduledoc """
  LiveView component for selecting a datetime range.

  Uses HTML5 datetime-local inputs with validation for CA certificate validity periods.
  Provides visual feedback for invalid ranges and calculates the duration.

  ## Usage

      <.datetime_range_picker
        id="validity"
        start_field={@form[:validity_start]}
        end_field={@form[:validity_end]}
      />
  """
  use Phoenix.Component

  @doc """
  Renders a datetime range picker with start and end inputs.

  ## Attributes

  - `id` - Required. Unique identifier for the component
  - `start_field` - Required. Phoenix.HTML.FormField for the start datetime
  - `end_field` - Required. Phoenix.HTML.FormField for the end datetime
  - `start_label` - Optional. Label for start input (default: "Valid From")
  - `end_label` - Optional. Label for end input (default: "Valid Until")
  - `show_duration` - Optional. Whether to show duration calculation (default: true)
  """
  attr :id, :string, required: true
  attr :start_field, Phoenix.HTML.FormField, required: true
  attr :end_field, Phoenix.HTML.FormField, required: true
  attr :start_label, :string, default: "Valid From"
  attr :end_label, :string, default: "Valid Until"
  attr :show_duration, :boolean, default: true

  def datetime_range_picker(assigns) do
    ~H"""
    <div id={@id} class="space-y-4">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <!-- Start DateTime -->
        <div>
          <label for={"#{@id}_start"} class="block text-sm font-medium text-gray-700 mb-1">
            {@start_label}
          </label>
          <input
            type="datetime-local"
            name={@start_field.name}
            id={"#{@id}_start"}
            value={format_datetime_local(@start_field.value)}
            class={[
              "input input-bordered w-full",
              @start_field.errors != [] && "input-error"
            ]}
            step="1"
          />
          <%= if @start_field.errors != [] do %>
            <p class="mt-1 text-sm text-error">
              {Enum.map(@start_field.errors, fn {msg, _opts} -> msg end) |> Enum.join(", ")}
            </p>
          <% end %>
        </div>
        
    <!-- End DateTime -->
        <div>
          <label for={"#{@id}_end"} class="block text-sm font-medium text-gray-700 mb-1">
            {@end_label}
          </label>
          <input
            type="datetime-local"
            name={@end_field.name}
            id={"#{@id}_end"}
            value={format_datetime_local(@end_field.value)}
            class={[
              "input input-bordered w-full",
              @end_field.errors != [] && "input-error"
            ]}
            step="1"
          />
          <%= if @end_field.errors != [] do %>
            <p class="mt-1 text-sm text-error">
              {Enum.map(@end_field.errors, fn {msg, _opts} -> msg end) |> Enum.join(", ")}
            </p>
          <% end %>
        </div>
      </div>
      
    <!-- Duration Display -->
      <%= if @show_duration && @start_field.value && @end_field.value do %>
        <%= if is_struct(@start_field.value, DateTime) && is_struct(@end_field.value, DateTime) do %>
          <div class="alert alert-info">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              class="stroke-current shrink-0 w-6 h-6"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              >
              </path>
            </svg>
            <span>
              <strong>Validity Period:</strong>
              {format_duration(@start_field.value, @end_field.value)}
            </span>
          </div>
        <% end %>
      <% end %>
      
    <!-- Info Text -->
      <p class="text-sm text-gray-600">
        Specify the validity period for this Certificate Authority. For root CAs, consider 10-20 years. All times are in UTC.
      </p>
    </div>
    """
  end

  @doc """
  Formats a DateTime for HTML5 datetime-local input.

  Converts DateTime to local format "YYYY-MM-DDTHH:MM:SS" required by datetime-local inputs.
  """
  def format_datetime_local(nil), do: ""

  def format_datetime_local(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace("Z", "")
    |> String.replace(~r/[+-]\d{2}:\d{2}$/, "")
  end

  def format_datetime_local(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> format_datetime_local(dt)
      _ -> value
    end
  end

  def format_datetime_local(_), do: ""

  @doc """
  Formats the duration between two DateTimes in a human-readable format.

  Returns a string like "10 years, 3 months, 15 days".
  """
  def format_duration(%DateTime{} = start_dt, %DateTime{} = end_dt) do
    if DateTime.compare(end_dt, start_dt) == :gt do
      diff_seconds = DateTime.diff(end_dt, start_dt)
      diff_days = div(diff_seconds, 86400)

      years = div(diff_days, 365)
      remaining_days = rem(diff_days, 365)
      months = div(remaining_days, 30)
      days = rem(remaining_days, 30)

      parts =
        [
          {years, "year"},
          {months, "month"},
          {days, "day"}
        ]
        |> Enum.filter(fn {count, _label} -> count > 0 end)
        |> Enum.map(fn {count, label} ->
          plural = if count > 1, do: "s", else: ""
          "#{count} #{label}#{plural}"
        end)

      case parts do
        [] -> "less than 1 day"
        parts -> Enum.join(parts, ", ")
      end
    else
      "Invalid range (end before start)"
    end
  end

  def format_duration(_, _), do: ""

  @doc """
  Parses an HTML5 datetime-local input value to a DateTime.

  Assumes the input is in UTC timezone.
  """
  def parse_datetime_local(nil), do: {:error, :invalid_format}
  def parse_datetime_local(""), do: {:error, :empty}

  def parse_datetime_local(value) when is_binary(value) do
    # HTML5 datetime-local format: "2025-11-25T14:30:00"
    # Add "Z" to indicate UTC
    case DateTime.from_iso8601(value <> "Z") do
      {:ok, dt, 0} -> {:ok, dt}
      {:error, _} = error -> error
      _ -> {:error, :invalid_format}
    end
  end
end
