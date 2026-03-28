defmodule GSMLG.Component.Gettext do
  @moduledoc """
  Gettext backend for shared GSMLG components.
  """
  # Ensure plural module is compiled before this backend expands its macro.
  require GSMLG.Component.Gettext.Plural
  use Gettext.Backend, otp_app: :gsmlg_component, plural_forms: GSMLG.Component.Gettext.Plural
end
