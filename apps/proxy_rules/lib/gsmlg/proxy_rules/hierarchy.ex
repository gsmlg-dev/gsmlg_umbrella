defmodule GSMLG.ProxyRules.Hierarchy do
  @moduledoc """
  Deduplicates and folds descendant domains within a rule list.
  """

  alias GSMLG.ProxyRules.Rule

  @type fold_result :: %{
          required(:rules) => [Rule.t()],
          required(:duplicate_count) => non_neg_integer(),
          required(:collapsed_count) => non_neg_integer()
        }

  @spec fold([Rule.t()]) :: [Rule.t()]
  def fold(rules), do: fold_with_stats(rules).rules

  @spec fold_with_stats([Rule.t()]) :: fold_result()
  def fold_with_stats(rules) do
    unique = Enum.uniq_by(rules, & &1.domain.name)
    folded = fold_unique(unique)

    %{
      rules: folded,
      duplicate_count: length(rules) - length(unique),
      collapsed_count: length(unique) - length(folded)
    }
  end

  defp fold_unique(rules) do
    rules
    |> Enum.sort_by(&{&1.domain.reversed_labels, &1.domain.name})
    |> Enum.reduce([], fn rule, kept ->
      if covered?(rule, kept), do: kept, else: [rule | kept]
    end)
    |> Enum.sort_by(& &1.domain.name)
  end

  defp covered?(rule, kept) do
    Enum.any?(kept, fn parent ->
      List.starts_with?(rule.domain.reversed_labels, parent.domain.reversed_labels)
    end)
  end
end
