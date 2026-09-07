defmodule GSMLG.Browser.ChatURLTest do
  use ExUnit.Case, async: true

  alias GSMLG.Browser.ChatURL

  test "accepts only HTTPS URLs on approved Gemini hosts" do
    assert {:ok, "https://gemini.google.com/app/abc?hl=en"} =
             ChatURL.validate("https://gemini.google.com/app/abc?hl=en")

    assert {:error, :invalid_chat_url} = ChatURL.validate("http://gemini.google.com/app/abc")
    assert {:error, :invalid_chat_url} = ChatURL.validate("https://gemini.google.com.evil.test/x")
    assert {:error, :invalid_chat_url} = ChatURL.validate("https://user@gemini.google.com/x")
    assert {:error, :invalid_chat_url} = ChatURL.validate("https://gemini.google.com:444/x")
    assert {:error, :invalid_chat_url} = ChatURL.validate("https://gemini.google.com/x#secret")
  end

  test "extracts only the dedicated trusted RPC field and retains an existing value" do
    assert {:ok, "https://gemini.google.com/app/abc"} =
             ChatURL.from_rpc(%{"chat_url" => "https://gemini.google.com/app/abc"})

    assert {:ok, "https://gemini.google.com/app/existing"} =
             ChatURL.from_rpc(
               %{
                 "result" => %{"chat_url" => "https://gemini.google.com/app/nested"}
               },
               "https://gemini.google.com/app/existing"
             )
  end
end
