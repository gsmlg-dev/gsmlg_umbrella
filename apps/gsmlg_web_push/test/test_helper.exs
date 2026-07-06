ExUnit.start()

defmodule Fixtures do
  @fcm_url "https://fcm.googleapis.com/fcm/send"

  def example_input(), do: "Hello, World."
  def example_output(), do: "CE2OS6BxfXsC2YbTdfkeWLlt4AKWbHZ3Fe53n5/4Yg=="

  def example_server_keys() do
    %{
      public:
        "BOg5KfYiBdDDRF12Ri17y3v+POPr8X0nVP2jDjowPVI/DMKU1aQ3OLdPH1iaakvR9/PHq6tNCzJH35v/JUz2crY=",
      private: "uDNsfsz91y2ywQeOHljVoiUg3j5RGrDVAswRqjP3v90="
    }
  end

  def valid_subscription() do
    %{
      endpoint: "https://example-endpoint.com/example/1234",
      keys: %{
        auth: "8eDyX_uCN0XRhSbY5hs7Hg==",
        p256dh:
          "BCIWgsnyXDv1VkhqL2P7YRBvdeuDnlwAPT2guNhdIoW3IP7GmHh1SMKPLxRf7x8vJy6ZFK3ol2ohgn_-0yP7QQA="
      }
    }
  end

  def valid_fcm_subscription() do
    Map.put(valid_subscription(), :endpoint, @fcm_url)
  end
end

defmodule HTTPFetchSandbox do
  def start_link(_) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def fetch(url, options \\ []) do
    req = %{
      method: Keyword.fetch!(options, :method),
      url: url,
      body: Keyword.get(options, :body, ""),
      headers: Keyword.get(options, :headers, %{}),
      options: options
    }

    Agent.update(__MODULE__, &[req | &1])
    {:ok, HTTP.Response.new(status: 201, body: "")}
  end

  def requests() do
    Agent.get(__MODULE__, & &1)
  end

  def reset_requests!() do
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end
