defmodule GSMLG.GaoNote.Compat.LabelSelectorTest do
  use ExUnit.Case, async: true
  alias GSMLG.GaoNote.Compat.LabelSelector

  test "parses AND selectors, presence and the first longest operator" do
    assert {:ok, []} = LabelSelector.parse(" && ")

    assert {:ok,
            [
              %{key: "env", operator: "=", value: "prod"},
              %{key: "archived", operator: "=", value: nil}
            ]} = LabelSelector.parse("& env = prod && archived &")

    assert {:ok, [%{key: "=", value: nil}]} = LabelSelector.parse("=")

    for {input, key, operator, value} <- [
          {"version>=1.2.0", "version", ">=", "1.2.0"},
          {"priority<10", "priority", "<", "10"},
          {"status!=done", "status", "!=", "done"},
          {"name~=^a!=b$", "name", "~=", "^a!=b$"},
          {"name^=a>=b", "name", "^=", "a>=b"},
          {"name$=a<=b", "name", "$=", "a<=b"},
          {"name~=a^=b$=c", "name", "~=", "a^=b$=c"},
          {"name~=a==b", "name", "~=", "a==b"},
          {"env=foo==bar", "env", "=", "foo==bar"},
          {"env==foo", "env", "=", "=foo"},
          {"n<=1", "n", "<=", "1"},
          {"n>1", "n", ">", "1"}
        ] do
      assert {:ok, [%{key: ^key, operator: ^operator, value: ^value}]} =
               LabelSelector.parse(input)
    end
  end

  test "exact selectors decode percent bytes once and preserve raw operands" do
    for {input, key, value} <- [
          {"~project==a%26b", "project", "a&b"},
          {"~project==a%3Db", "project", "a=b"},
          {"~project==%2526", "project", "%26"},
          {"~project==%2B", "project", "+"},
          {"~project==a+b", "project", "a+b"},
          {"~project==%20padded%20", "project", " padded "},
          {"~project==", "project", ""},
          {"~%E9%A1%B9%E7%9B%AE==%E7%8C%AB", "项目", "猫"},
          {"~%20key%20==value", " key ", "value"},
          {"~key==a==b", "key", "a==b"}
        ] do
      assert {:ok, [%{key: ^key, operator: "==", value: ^value}]} = LabelSelector.parse(input)
    end
  end

  test "malformed exact selectors reject the whole expression" do
    for input <- [
          "~==secret",
          "~project",
          "~project==%ZZ",
          "status=ready&~==secret",
          "~x==%",
          "~x==%2",
          "~x==%FF",
          "~x==%+1",
          "~x==%-1"
        ] do
      assert {:error, "malformed exact label selector"} = LabelSelector.parse(input)
    end
  end

  test "keys remain case sensitive and all selectors must find a label" do
    labels = [
      %{key: "env", value: "prod", value_type: "text"},
      %{key: "priority", value: "10", value_type: "number"}
    ]

    assert {:ok, selectors} = LabelSelector.parse("env=prod&priority>=2")
    assert LabelSelector.matches_all?(labels, selectors)
    assert {:ok, selectors} = LabelSelector.parse("env=prod&missing!=x")
    refute LabelSelector.matches_all?(labels, selectors)
    refute matches("text", "prod", "Env=prod")
    assert LabelSelector.matches_all?([], [])
    assert matches("text", "", "env")
  end

  test "text ordering trims but is case sensitive; exact is raw and bypasses types" do
    assert matches("text", " padded ", "env=padded")
    refute matches("text", "Agent", "env=agent")
    assert matches("text", "b", "env>a")
    assert matches("text", " padded ", "~env==%20padded%20")
    refute matches("text", " padded ", "~env==padded")
    assert matches("number", "not-a-number", "~env==not-a-number")
    assert matches("number", "01", "~env==01")
    refute matches("number", "01", "~env==1")
  end

  test "numeric comparisons use finite f64 and signed zero total order" do
    assert matches("number", "10", "env>2")
    assert matches("number", "01", "env=1")
    assert matches("number", "1e2", "env=100")
    assert matches("number", ".5", "env=0.5")
    assert matches("number", "1.", "env=1")
    assert matches("number", "1.e2", "env=100")
    assert matches("number", "-0", "env<0")
    refute matches("number", "-0", "env=0")

    for value <- ["NaN", "inf", "-inf", "Infinity", "1e999", "1abc", ""] do
      refute matches("number", value, "env!=1")
    end
  end

  test "dotted versions normalize leading v and trailing zero components" do
    assert matches("version", "1.10.0", "env>1.2.9")
    assert matches("version", "vv1.2.0.0", "env=1.2")
    assert matches("version", "1.2.3.4.5", "env>1.2.3.4")
    assert matches("version", "0001.002", "env=1.2.0")
    assert matches("version", "0.0", "env=0")
    assert matches("version", "18446744073709551615", "env>1")

    for value <- [
          "1.2.beta",
          "1.2.3-rc1",
          "1.2.3+build",
          "V1.2",
          "1..2",
          "1.",
          "v",
          "18446744073709551616"
        ] do
      refute matches("version", value, "env!=1")
    end
  end

  test "dates, naive datetimes and times compare parsed values" do
    assert matches("date", "2026-07-09", "env>=2026-01-01")
    assert matches("datetime", "2026-07-09T12:30", "env<2026-07-09 13:00:00")
    assert matches("date-time", "2026-07-09 12:30:00", "env=2026-07-09T12:30")
    assert matches("time", "09:30", "env<=10:00:00")
    assert matches("date", "2026-7-9", "env=2026-07-09")
    assert matches("date", "2026- 7- 9", "env=2026-07-09")
    assert matches("date", "+12345-1-1", "env>2026-07-09")
    refute matches("date", "12345-1-1", "env>2026-07-09")
    assert matches("time", "9:3", "env=09:03")
    assert matches("time", "9: 3", "env=09:03")
    assert matches("datetime", "2026-7-9T 9:3", "env=2026-07-09T09:03")
    assert matches("datetime", "2026-7-9  9:3", "env=2026-07-09T09:03")
    assert matches("datetime", "2026-7-9T9:3:60", "env>2026-07-09T09:03:59")

    for {type, value} <- [
          {"date", "07/09/2026"},
          {"date", "2026-02-30"},
          {"datetime", "2026-07-09T12:30Z"},
          {"datetime", "2026-07-09T12:30:00.1"},
          {"time", "24:00"},
          {"year", "2026"}
        ] do
      refute matches(type, value, "env!=1")
    end
  end

  test "string comparators operate case insensitively on raw values of every type" do
    for {type, value, expression} <- [
          {"text", "Agent-Note", "env^=agent"},
          {"text", "Agent-Note", "env$=NOTE"},
          {"text", "ÄGENT-NÖTE", "env^=äge"},
          {"text", "ÄGENT-NÖTE", "env$=nöte"},
          {"number", "10", "env^=1"},
          {"version", "v1.2.3", "env~=^V1\\."},
          {"date", "2026-07-21", "env^=2026-"},
          {"datetime", "2026-07-21T12:30", "env~=T12:\\d+$"},
          {"time", "09:30", "env$=:30"},
          {"text", "Agent-Note", "env~=^agent-.+"}
        ] do
      assert matches(type, value, expression)
    end

    refute matches("text", "Agent-Note", "env^=gent")
    refute matches("text", "Agent-Note", "env$=not")
    refute matches("text", " Agent", "env^=agent")

    for operator <- ["^=", "$=", "~="],
        do: assert(matches("text", "Agent-Note", "env#{operator}"))
  end

  test "regex rejects invalid syntax and Rust-unsupported lookaround and backreferences" do
    for pattern <- ["[", "(?=Agent)", "(?<=A)gent", "(Agent)\\1", "(?P=x)", "(?>Agent)"] do
      refute matches("text", "Agent-Note", "env~=#{pattern}")
    end

    assert matches("text", "猫", "env~=\\p{L}")
    assert matches("text", "١٢", "env~=^\\d+$")
    assert matches("text", "Agent", "env~=(?-i:Agent)")
    refute matches("text", "Agent\n", "env~=^agent$")
    refute matches("text", String.duplicate("a", 2000) <> "!", "env~=^(a+)+$")
  end

  defp matches(type, value, expression) do
    assert {:ok, [selector]} = LabelSelector.parse(expression)
    LabelSelector.matches?(%{key: "env", value: value, value_type: type}, selector)
  end

  test "value validation shares the reference typed parsers without normalizing stored bytes" do
    for {type, value} <- [
          {"text", ""},
          {"text", " padded "},
          {"number", " 1.e2 "},
          {"version", " vv1.2.0 "},
          {"date", "2026-7-9"},
          {"datetime", "2026-07-09 12:30"},
          {"time", "09:30:60"}
        ] do
      assert LabelSelector.valid_value?(type, value)
    end

    for {type, value} <- [
          {"number", "NaN"},
          {"number", "1e999"},
          {"version", "1.2.3-rc1"},
          {"version", "1.2.3+build"},
          {"version", "18446744073709551616"},
          {"date", "2026-02-30"},
          {"datetime", "2026-07-09T12:30Z"},
          {"datetime", "2026-07-09T12:30:00.1"},
          {"time", "24:00"},
          {"year", "2026"}
        ] do
      refute LabelSelector.valid_value?(type, value)
    end
  end
end
