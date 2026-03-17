defmodule GSMLG.Component.Gettext do
  @moduledoc """
  Gettext backend for shared GSMLG components.
  """
  use Gettext.Backend, otp_app: :gsmlg_component
end
