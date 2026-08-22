defmodule GSMLG.GaoNote.LabelValueTest do
  use ExUnit.Case, async: true

  alias GSMLG.GaoNote.{LabelSetting, LabelValue}

  test "normalizes nil and surrounding whitespace" do
    assert LabelValue.normalize(nil) == ""
    assert LabelValue.normalize(" 2026-08 ") == "2026-08"
  end

  test "classifies valid and invalid year-month values" do
    setting = %LabelSetting{value_type: "year-month"}

    assert LabelValue.classify(setting, "2026-08") == {"valid", []}
    assert LabelValue.classify(setting, "August") == {"invalid", ["must be YYYY-MM"]}
  end

  test "validates and returns the normalized value" do
    setting = %LabelSetting{value_type: "year-month"}

    assert {:ok, "2026-08"} = LabelValue.validate(setting, " 2026-08 ")
  end

  test "validates with the label setting id in the error" do
    setting = %LabelSetting{id: "setting-id", value_type: "year-month"}

    assert {:error,
            {:invalid_label_value, %{label_setting_id: "setting-id", errors: ["must be YYYY-MM"]}}} =
             LabelValue.validate(setting, "August")
  end
end
