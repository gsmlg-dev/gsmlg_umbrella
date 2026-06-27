defmodule GSMLG.Scout.Fetch.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias GSMLG.Scout.Fetch.{Result, RetryPolicy}
  alias GSMLG.Scout.Settings

  test "identifies retryable result types" do
    refute RetryPolicy.retryable?(%Result{ok: true})
    assert RetryPolicy.retryable?(%Result{ok: false, error: %{type: "timeout"}})
    assert RetryPolicy.retryable?(%Result{ok: false, error: %{retryable: true}})
    refute RetryPolicy.retryable?(%Result{ok: false, error: %{type: "blocked_target"}})
    refute RetryPolicy.retryable?(%{})
  end

  test "calculates deterministic no-jitter delay with max backoff clamping" do
    settings =
      Settings.default_settings()
      |> put_in(["fetch", "retry"], %{
        "max_attempts" => 5,
        "base_backoff_ms" => 100,
        "max_backoff_ms" => 250,
        "jitter" => false
      })

    assert RetryPolicy.delay_ms(1, settings) == 100
    assert RetryPolicy.delay_ms(2, settings) == 200
    assert RetryPolicy.delay_ms(3, settings) == 250
    assert RetryPolicy.delay_ms(8, settings) == 250
  end

  test "keeps jittered delay at or below max backoff" do
    settings =
      Settings.default_settings()
      |> put_in(["fetch", "retry"], %{
        "max_attempts" => 5,
        "base_backoff_ms" => 100,
        "max_backoff_ms" => 100,
        "jitter" => true
      })

    for _ <- 1..10 do
      assert RetryPolicy.delay_ms(8, settings) <= 100
    end
  end
end
