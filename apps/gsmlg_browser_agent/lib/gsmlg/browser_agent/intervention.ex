defmodule GSMLG.BrowserAgent.Intervention do
  @moduledoc "Stable human-intervention reasons and bounded operator instructions."

  @reasons [
    :login_required,
    :reauth_required,
    :passkey_required,
    :two_factor_required,
    :captcha_required,
    :account_warning,
    :ui_contract_mismatch,
    :action_outcome_unknown,
    :plan_approval_required
  ]

  @instructions %{
    login_required: "Sign in through the remote browser, then resume the workflow.",
    reauth_required: "Complete account reauthentication in the remote browser, then resume.",
    passkey_required: "Complete the passkey prompt manually, then resume the workflow.",
    two_factor_required: "Complete two-factor verification manually, then resume the workflow.",
    captcha_required: "Complete the CAPTCHA manually, then resume the workflow.",
    account_warning: "Review and resolve the account warning manually, then resume.",
    ui_contract_mismatch: "Inspect the unknown Gemini page and place it in a supported state.",
    action_outcome_unknown: "Inspect whether the last action completed before resuming.",
    plan_approval_required: "Review and approve the research plan manually, then resume."
  }

  def reason_codes, do: @reasons

  def new(reason, operator_id) when reason in @reasons and is_binary(operator_id) do
    if byte_size(operator_id) in 1..256 and String.valid?(operator_id) do
      {:ok,
       %{
         reason: reason,
         reason_code: Atom.to_string(reason),
         operator_id: operator_id,
         instructions: Map.fetch!(@instructions, reason)
       }}
    else
      {:error, :invalid_operator_identity}
    end
  end

  def new(_reason, _operator_id), do: {:error, :invalid_intervention}
end
