defmodule GSMLG.BrowserAgent.CDPClientTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{OriginPolicy}
  alias GSMLG.BrowserAgent.CDP.Client

  defmodule Transport do
    @behaviour GSMLG.BrowserAgent.CDP.Transport

    @impl true
    def connect(url, headers, owner, opts) do
      socket = %{owner: owner, test_pid: opts[:test_pid], ref: make_ref()}
      Kernel.send(opts[:test_pid], {:cdp_connect, url, headers, opts})
      unless opts[:defer_open], do: Kernel.send(owner, {:cdp_transport, socket, :open})
      {:ok, socket}
    end

    @impl true
    def send(socket, payload) do
      command = JSON.decode!(payload)
      Kernel.send(socket.test_pid, {:cdp_command, socket, command})
      :ok
    end

    @impl true
    def close(socket) do
      Kernel.send(socket.test_pid, {:cdp_closed, socket})
      :ok
    end
  end

  test "owns the socket and exposes only a finite internal method set" do
    {:ok, client} = start_client()
    assert_receive {:cdp_connect, "ws://127.0.0.1:8080/api/profiles/p/cdp", headers, opts}
    assert headers == [{"authorization", "Bearer secret"}]
    assert opts[:max_message_bytes] == 2_048

    refute function_exported?(Client, :call, 3)
    refute function_exported?(Client, :request, 3)
    refute function_exported?(Client, :evaluate, 2)

    assert Client.allowed_methods() == [
             "Accessibility.enable",
             "Accessibility.getFullAXTree",
             "Browser.cancelDownload",
             "Browser.setDownloadBehavior",
             "Fetch.continueRequest",
             "Fetch.enable",
             "Fetch.failRequest",
             "DOM.describeNode",
             "DOM.enable",
             "DOM.focus",
             "DOM.getBoxModel",
             "DOM.getDocument",
             "DOM.querySelector",
             "Input.dispatchKeyEvent",
             "Input.dispatchMouseEvent",
             "Input.dispatchMouseWheelEvent",
             "Input.insertText",
             "Network.enable",
             "Page.captureScreenshot",
             "Page.enable",
             "Page.getNavigationHistory",
             "Page.navigate"
           ]

    task = Task.async(fn -> Client.navigate(client, "https://gemini.google.com/app", 500) end)

    assert_receive {:cdp_command, socket,
                    %{
                      "id" => id,
                      "method" => "Page.navigate",
                      "params" => %{"url" => "https://gemini.google.com/app"}
                    }}

    send(client, {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => id, "result" => %{}})}})
    assert {:ok, %{}} = Task.await(task)
    GenServer.stop(client)
  end

  test "enables finite all-request interception before browser actions" do
    {:ok, client} = start_client()
    assert_receive {:cdp_connect, _, _, _}

    task = Task.async(fn -> Client.enable(client, 500) end)

    for {method, expected_params} <- [
          {"Network.enable", %{}},
          {"Fetch.enable",
           %{
             "patterns" => [
               %{
                 "requestStage" => "Request",
                 "urlPattern" => "*"
               }
             ]
           }},
          {"Page.enable", %{}},
          {"DOM.enable", %{}},
          {"Accessibility.enable", %{}}
        ] do
      assert_receive {:cdp_command, socket,
                      %{"id" => id, "method" => ^method, "params" => ^expected_params}}

      send(
        client,
        {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => id, "result" => %{}})}}
      )
    end

    assert :ok = Task.await(task)
    GenServer.stop(client)
  end

  test "authorizes every actual request and blocks a DNS-rebound redirect" do
    {:ok, resolutions} = Agent.start_link(fn -> [[{8, 8, 8, 8}], [{127, 0, 0, 1}]] end)

    resolver = fn "gemini.google.com" ->
      Agent.get_and_update(resolutions, fn [next | rest] -> {{:ok, next}, rest} end)
    end

    {:ok, client} = start_client(resolver: resolver)
    assert_receive {:cdp_connect, _, _, _}
    socket = :sys.get_state(client).socket

    send_paused_request(
      client,
      socket,
      "request-1",
      "network-1",
      "Document",
      "https://gemini.google.com/app"
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Fetch.continueRequest",
                      "params" => %{"requestId" => "request-1"}
                    }}

    send_paused_request(
      client,
      socket,
      "request-2",
      "network-2",
      "Script",
      "https://gemini.google.com/redirect"
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Fetch.failRequest",
                      "params" => %{
                        "errorReason" => "BlockedByClient",
                        "requestId" => "request-2"
                      }
                    }}

    refute_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Fetch.continueRequest",
                      "params" => %{"requestId" => "request-2"}
                    }}

    GenServer.stop(client)
  end

  test "fails an authorized request when its network id cannot be correlated" do
    {:ok, client} = start_client()
    assert_receive {:cdp_connect, _, _, _}
    socket = :sys.get_state(client).socket

    for {request_id, network_fields} <- [
          {"request-missing-network", %{}},
          {"request-invalid-network", %{"networkId" => String.duplicate("n", 257)}}
        ] do
      send(
        client,
        {:cdp_transport, socket,
         {:text,
          JSON.encode!(%{
            "method" => "Fetch.requestPaused",
            "params" =>
              Map.merge(
                %{
                  "requestId" => request_id,
                  "resourceType" => "Document",
                  "request" => %{"url" => "https://gemini.google.com/app"}
                },
                network_fields
              )
          })}}
      )

      assert_receive {:cdp_command, ^socket,
                      %{
                        "method" => "Fetch.failRequest",
                        "params" => %{
                          "errorReason" => "BlockedByClient",
                          "requestId" => ^request_id
                        }
                      }}

      refute_receive {:cdp_command, ^socket,
                      %{
                        "method" => "Fetch.continueRequest",
                        "params" => %{"requestId" => ^request_id}
                      }}
    end

    GenServer.stop(client)
  end

  test "a private response address terminates the client after detection" do
    {:ok, client} = start_client()
    assert_receive {:cdp_connect, _, _, _}
    socket = :sys.get_state(client).socket
    monitor = Process.monitor(client)

    send_paused_request(
      client,
      socket,
      "request-1",
      "network-1",
      "Image",
      "https://gemini.google.com/image.png"
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Fetch.continueRequest",
                      "params" => %{"requestId" => "request-1"}
                    }}

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Network.responseReceived",
          "params" => %{
            "requestId" => "network-1",
            "response" => %{
              "url" => "https://gemini.google.com/image.png",
              "remoteIPAddress" => "127.0.0.1"
            }
          }
        })}}
    )

    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
    assert_receive {:cdp_closed, ^socket}
  end

  test "request authorization is bounded and fails closed on resolver timeout" do
    resolver = fn _host -> Process.sleep(1_000) end
    {:ok, client} = start_client(resolver: resolver, policy_timeout_ms: 10)
    assert_receive {:cdp_connect, _, _, _}
    socket = :sys.get_state(client).socket

    send_paused_request(
      client,
      socket,
      "request-timeout",
      "network-timeout",
      "XHR",
      "https://gemini.google.com/api"
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Fetch.failRequest",
                      "params" => %{
                        "errorReason" => "BlockedByClient",
                        "requestId" => "request-timeout"
                      }
                    }},
                   100

    GenServer.stop(client)
  end

  test "bounds concurrently authorized network requests and denies overflow" do
    {:ok, client} = start_client(max_authorized_network_ids: 1)
    assert_receive {:cdp_connect, _, _, _}
    socket = :sys.get_state(client).socket

    send_paused_request(
      client,
      socket,
      "request-1",
      "network-1",
      "Image",
      "https://gemini.google.com/one.png"
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Fetch.continueRequest",
                      "params" => %{"requestId" => "request-1"}
                    }}

    send_paused_request(
      client,
      socket,
      "request-2",
      "network-2",
      "Script",
      "https://gemini.google.com/two.js"
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Fetch.failRequest",
                      "params" => %{"requestId" => "request-2"}
                    }}

    GenServer.stop(client)
  end

  test "releases a correlated authorization when Network.loadingFailed arrives" do
    {:ok, client} = start_client(max_authorized_network_ids: 1)
    assert_receive {:cdp_connect, _, _, _}
    socket = :sys.get_state(client).socket

    send_paused_request(
      client,
      socket,
      "request-1",
      "network-1",
      "Image",
      "https://gemini.google.com/one.png"
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Fetch.continueRequest",
                      "params" => %{"requestId" => "request-1"}
                    }}

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Network.loadingFailed",
          "params" => %{"requestId" => "network-1", "errorText" => "net::ERR_ABORTED"}
        })}}
    )

    _state = :sys.get_state(client)

    send_paused_request(
      client,
      socket,
      "request-2",
      "network-2",
      "Script",
      "https://gemini.google.com/two.js"
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Fetch.continueRequest",
                      "params" => %{"requestId" => "request-2"}
                    }}

    GenServer.stop(client)
  end

  test "fails closed on malformed or uncorrelated Network.loadingFailed events" do
    for params <- [
          %{},
          %{"requestId" => String.duplicate("n", 257)},
          %{"requestId" => "not-authorized"}
        ] do
      {:ok, client} = start_client()
      assert_receive {:cdp_connect, _, _, _}
      socket = :sys.get_state(client).socket
      monitor = Process.monitor(client)

      send(
        client,
        {:cdp_transport, socket,
         {:text, JSON.encode!(%{"method" => "Network.loadingFailed", "params" => params})}}
      )

      assert_receive {:cdp_closed, ^socket}
      assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
    end
  end

  test "permits a missing response peer only for a correlated authorized cache response" do
    for cache_flag <- ["fromDiskCache", "fromServiceWorker"] do
      {:ok, client} = start_client(max_authorized_network_ids: 1)
      assert_receive {:cdp_connect, _, _, _}
      socket = :sys.get_state(client).socket

      send_paused_request(
        client,
        socket,
        "request-1",
        "network-1",
        "Image",
        "https://gemini.google.com/one.png"
      )

      assert_receive {:cdp_command, ^socket,
                      %{
                        "method" => "Fetch.continueRequest",
                        "params" => %{"requestId" => "request-1"}
                      }}

      send(
        client,
        {:cdp_transport, socket,
         {:text,
          JSON.encode!(%{
            "method" => "Network.responseReceived",
            "params" => %{
              "requestId" => "network-1",
              "response" =>
                Map.put(%{"url" => "https://gemini.google.com/one.png"}, cache_flag, true)
            }
          })}}
      )

      _state = :sys.get_state(client)

      send_paused_request(
        client,
        socket,
        "request-2",
        "network-2",
        "Script",
        "https://gemini.google.com/two.js"
      )

      assert_receive {:cdp_command, ^socket,
                      %{
                        "method" => "Fetch.continueRequest",
                        "params" => %{"requestId" => "request-2"}
                      }}

      GenServer.stop(client)
    end
  end

  test "fails closed when a network response lacks a peer and a validated cache source" do
    for response <- [
          %{"url" => "https://gemini.google.com/one.png"},
          %{"url" => "https://gemini.google.com/one.png", "fromDiskCache" => "true"},
          %{"url" => "https://evil.example/one.png", "fromDiskCache" => true}
        ] do
      {:ok, client} = start_client()
      assert_receive {:cdp_connect, _, _, _}
      socket = :sys.get_state(client).socket

      send_paused_request(
        client,
        socket,
        "request-1",
        "network-1",
        "Image",
        "https://gemini.google.com/one.png"
      )

      assert_receive {:cdp_command, ^socket,
                      %{
                        "method" => "Fetch.continueRequest",
                        "params" => %{"requestId" => "request-1"}
                      }}

      monitor = Process.monitor(client)

      send(
        client,
        {:cdp_transport, socket,
         {:text,
          JSON.encode!(%{
            "method" => "Network.responseReceived",
            "params" => %{"requestId" => "network-1", "response" => response}
          })}}
      )

      assert_receive {:cdp_closed, ^socket}
      assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
    end
  end

  test "bounds pending calls and turns disconnect ambiguity into stable errors" do
    {:ok, client} = start_client(max_pending: 1)
    assert_receive {:cdp_connect, _, _, _}

    first = Task.async(fn -> Client.screenshot(client, 1_000) end)
    assert_receive {:cdp_command, socket, %{"id" => _id, "method" => "Page.captureScreenshot"}}

    assert {:error, :cdp_pending_limit} = Client.navigation_history(client, 100)
    send(client, {:cdp_transport, socket, {:close, 1006}})
    assert {:error, :cdp_disconnected} = Task.await(first)

    assert {:error, :cdp_disconnected} = Client.screenshot(client, 100)
    GenServer.stop(client)
  end

  test "DOM metadata lookup is fixed to one backend node without traversal" do
    {:ok, client} = start_client()
    assert_receive {:cdp_connect, _, _, _}

    task = Task.async(fn -> Client.describe_backend_node(client, 42, 500) end)

    assert_receive {:cdp_command, socket,
                    %{
                      "id" => id,
                      "method" => "DOM.describeNode",
                      "params" => %{
                        "backendNodeId" => 42,
                        "depth" => 0,
                        "pierce" => false
                      }
                    }}

    send(client, {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => id, "result" => %{}})}})
    assert {:ok, %{}} = Task.await(task)
    GenServer.stop(client)
  end

  test "correlates responses, bounds server errors, and expires pending calls" do
    {:ok, client} = start_client()
    assert_receive {:cdp_connect, _, _, _}

    error_task = Task.async(fn -> Client.focus(client, 42, 500) end)
    assert_receive {:cdp_command, socket, %{"id" => id, "method" => "DOM.focus"}}

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "id" => id,
          "error" => %{"code" => -32_000, "message" => String.duplicate("secret", 100)}
        })}}
    )

    assert {:error, {:cdp_error, -32_000}} = Task.await(error_task)

    timeout_task = Task.async(fn -> Client.box_model(client, 19, 20) end)
    assert_receive {:cdp_command, _socket, %{"method" => "DOM.getBoxModel"}}
    assert {:error, :cdp_timeout} = Task.await(timeout_task)
    GenServer.stop(client)
  end

  test "awaits the supervised transport open event with a bound" do
    {:ok, client} = start_client(transport_opts: [test_pid: self(), defer_open: true])
    assert_receive {:cdp_connect, _, _, _}

    waiter = Task.async(fn -> Client.await_ready(client, 500) end)
    assert Task.yield(waiter, 10) == nil
    state = :sys.get_state(client)
    send(client, {:cdp_transport, state.socket, :open})
    assert :ok = Task.await(waiter)

    GenServer.stop(client)

    {:ok, unopened} = start_client(transport_opts: [test_pid: self(), defer_open: true])
    assert_receive {:cdp_connect, _, _, _}
    assert {:error, :cdp_timeout} = Client.await_ready(unopened, 10)
    GenServer.stop(unopened)
  end

  test "closes its socket when the owning session process exits" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, client} = start_client(owner: owner)
    assert_receive {:cdp_connect, _, _, _}
    monitor = Process.monitor(client)
    Process.exit(owner, :kill)
    assert_receive {:cdp_closed, _socket}
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  test "invalidates the observed document epoch on page and DOM mutation events" do
    {:ok, client} = start_client()
    assert_receive {:cdp_connect, _, _, _}
    assert {:ok, 0} = Client.document_epoch(client)
    socket = :sys.get_state(client).socket

    send(
      client,
      {:cdp_transport, socket, {:text, JSON.encode!(%{"method" => "DOM.documentUpdated"})}}
    )

    assert {:ok, 1} = Client.document_epoch(client)

    send(
      client,
      {:cdp_transport, socket, {:text, JSON.encode!(%{"method" => "Network.dataReceived"})}}
    )

    assert {:ok, 1} = Client.document_epoch(client)
    GenServer.stop(client)
  end

  @tag :tmp_dir
  test "captures one bounded download without trusting its guid as a path", %{tmp_dir: tmp_dir} do
    {:ok, client} = start_client(download_dir: tmp_dir, max_download_bytes: 4)
    assert_receive {:cdp_connect, _, _, _}

    prepare = Task.async(fn -> Client.prepare_download(client, 500) end)

    assert_receive {:cdp_command, socket,
                    %{
                      "id" => id,
                      "method" => "Browser.setDownloadBehavior",
                      "params" => %{
                        "behavior" => "allowAndName",
                        "downloadPath" => ^tmp_dir,
                        "eventsEnabled" => true
                      }
                    }}

    send(client, {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => id, "result" => %{}})}})
    assert {:ok, token} = Task.await(prepare)
    waiter = Task.async(fn -> Client.await_download(client, token, 500) end)

    File.write!(Path.join(tmp_dir, "guid-1"), "pdf")

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Browser.downloadWillBegin",
          "params" => %{
            "guid" => "guid-1",
            "url" => "https://gemini.google.com/report.pdf?secret=query",
            "suggestedFilename" => "../report.pdf"
          }
        })}}
    )

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Browser.downloadProgress",
          "params" => %{"guid" => "guid-1", "state" => "completed", "totalBytes" => 3}
        })}}
    )

    assert {:ok,
            %{
              content: "pdf",
              source_url: "https://gemini.google.com/report.pdf?secret=query",
              suggested_filename: "../report.pdf"
            }} = Task.await(waiter)

    assert {:ok, ["guid-1"]} = File.ls(tmp_dir)

    finish = Task.async(fn -> Client.finish_download(client, token, 500) end)

    assert_receive {:cdp_command, ^socket,
                    %{
                      "id" => finish_id,
                      "method" => "Browser.setDownloadBehavior",
                      "params" => %{"behavior" => "deny"}
                    }}

    send(
      client,
      {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => finish_id, "result" => %{}})}}
    )

    assert :ok = Task.await(finish)
    assert {:ok, []} = File.ls(tmp_dir)

    prepare = Task.async(fn -> Client.prepare_download(client, 500) end)

    assert_receive {:cdp_command, ^socket,
                    %{"id" => second_id, "method" => "Browser.setDownloadBehavior"}}

    send(
      client,
      {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => second_id, "result" => %{}})}}
    )

    assert {:ok, token} = Task.await(prepare)
    waiter = Task.async(fn -> Client.await_download(client, token, 500) end)
    monitor = Process.monitor(client)
    File.write!(Path.join(tmp_dir, "guid-2"), "12345")

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Browser.downloadWillBegin",
          "params" => %{
            "guid" => "guid-2",
            "url" => "https://gemini.google.com/large.bin",
            "suggestedFilename" => "large.bin"
          }
        })}}
    )

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Browser.downloadProgress",
          "params" => %{
            "guid" => "guid-2",
            "state" => "inProgress",
            "receivedBytes" => 5,
            "totalBytes" => 5
          }
        })}}
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Browser.cancelDownload",
                      "params" => %{"guid" => "guid-2"}
                    }}

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Browser.setDownloadBehavior",
                      "params" => %{"behavior" => "deny"}
                    }}

    assert {:error, :artifact_too_large} = Task.await(waiter)
    assert {:ok, []} = File.ls(tmp_dir)
    assert_receive {:cdp_closed, ^socket}
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  @tag :tmp_dir
  test "rejects a path-unsafe download guid before filesystem lookup", %{tmp_dir: tmp_dir} do
    {:ok, client} = start_client(download_dir: tmp_dir, max_download_bytes: 16)
    assert_receive {:cdp_connect, _, _, _}

    prepare = Task.async(fn -> Client.prepare_download(client, 500) end)

    assert_receive {:cdp_command, socket,
                    %{"id" => id, "method" => "Browser.setDownloadBehavior"}}

    send(client, {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => id, "result" => %{}})}})
    assert {:ok, token} = Task.await(prepare)
    waiter = Task.async(fn -> Client.await_download(client, token, 500) end)
    monitor = Process.monitor(client)
    File.write!(Path.join(tmp_dir, "unrelated"), "secret")

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Browser.downloadWillBegin",
          "params" => %{
            "guid" => "../../not-a-path",
            "url" => "https://gemini.google.com/report.pdf",
            "suggestedFilename" => "report.pdf"
          }
        })}}
    )

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Browser.setDownloadBehavior",
                      "params" => %{"behavior" => "deny"}
                    }}

    assert {:error, :download_failed} = Task.await(waiter)
    assert {:ok, []} = File.ls(tmp_dir)
    assert_receive {:cdp_closed, ^socket}
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  @tag :tmp_dir
  test "a timed out download is canceled and denied before returning ambiguity", %{
    tmp_dir: tmp_dir
  } do
    {:ok, client} = start_client(download_dir: tmp_dir, max_download_bytes: 16)
    assert_receive {:cdp_connect, _, _, _}

    prepare = Task.async(fn -> Client.prepare_download(client, 500) end)

    assert_receive {:cdp_command, socket,
                    %{"id" => id, "method" => "Browser.setDownloadBehavior"}}

    send(client, {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => id, "result" => %{}})}})
    assert {:ok, token} = Task.await(prepare)

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Browser.downloadWillBegin",
          "params" => %{
            "guid" => "guid-timeout",
            "url" => "https://gemini.google.com/report.pdf",
            "suggestedFilename" => "report.pdf"
          }
        })}}
    )

    File.write!(Path.join(tmp_dir, "guid-timeout"), "partial")
    monitor = Process.monitor(client)
    assert {:error, :cdp_timeout} = Client.await_download(client, token, 20)

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Browser.cancelDownload",
                      "params" => %{"guid" => "guid-timeout"}
                    }}

    assert_receive {:cdp_command, ^socket,
                    %{
                      "method" => "Browser.setDownloadBehavior",
                      "params" => %{"behavior" => "deny"}
                    }}

    assert {:ok, []} = File.ls(tmp_dir)
    assert_receive {:cdp_closed, ^socket}
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  @tag :tmp_dir
  test "invalidates the client when allowAndName times out", %{tmp_dir: tmp_dir} do
    {:ok, client} = start_client(download_dir: tmp_dir, max_download_bytes: 16)
    assert_receive {:cdp_connect, _, _, _}
    monitor = Process.monitor(client)

    assert {:error, :cdp_timeout} = Client.prepare_download(client, 20)
    assert_receive {:cdp_command, socket, %{"method" => "Browser.setDownloadBehavior"}}
    assert_receive {:cdp_closed, ^socket}
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  @tag :tmp_dir
  test "invalidates the client when deny is not confirmed", %{tmp_dir: tmp_dir} do
    {:ok, client} = start_client(download_dir: tmp_dir, max_download_bytes: 16)
    assert_receive {:cdp_connect, _, _, _}

    prepare = Task.async(fn -> Client.prepare_download(client, 500) end)

    assert_receive {:cdp_command, socket,
                    %{"id" => id, "method" => "Browser.setDownloadBehavior"}}

    send(client, {:cdp_transport, socket, {:text, JSON.encode!(%{"id" => id, "result" => %{}})}})
    assert {:ok, token} = Task.await(prepare)

    waiter = Task.async(fn -> Client.await_download(client, token, 500) end)
    File.write!(Path.join(tmp_dir, "guid-deny"), "pdf")

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Browser.downloadWillBegin",
          "params" => %{
            "guid" => "guid-deny",
            "url" => "https://gemini.google.com/report.pdf",
            "suggestedFilename" => "report.pdf"
          }
        })}}
    )

    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Browser.downloadProgress",
          "params" => %{"guid" => "guid-deny", "state" => "completed", "totalBytes" => 3}
        })}}
    )

    assert {:ok, %{content: "pdf"}} = Task.await(waiter)
    monitor = Process.monitor(client)
    assert {:error, :cdp_timeout} = Client.finish_download(client, token, 20)
    assert_receive {:cdp_command, ^socket, %{"method" => "Browser.setDownloadBehavior"}}
    assert_receive {:cdp_closed, ^socket}
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
  end

  defp start_client(opts \\ []) do
    result =
      Client.start_link(
        Keyword.merge(
          [
            name: nil,
            url: "ws://127.0.0.1:8080/api/profiles/p/cdp",
            headers: [{"authorization", "Bearer secret"}],
            transport: Transport,
            transport_opts: [test_pid: self()],
            origin_policy: origin_policy!(),
            resolver: fn _host -> {:ok, [{8, 8, 8, 8}]} end,
            max_pending: 4,
            max_message_bytes: 2_048
          ],
          opts
        )
      )

    case {result, get_in(opts, [:transport_opts, :defer_open])} do
      {{:ok, client}, nil} ->
        :ok = Client.await_ready(client)
        result

      _other ->
        result
    end
  end

  defp origin_policy! do
    {:ok, policy} = OriginPolicy.new(allowed_origins: ["https://gemini.google.com"])
    policy
  end

  defp send_paused_request(client, socket, request_id, network_id, resource_type, url) do
    send(
      client,
      {:cdp_transport, socket,
       {:text,
        JSON.encode!(%{
          "method" => "Fetch.requestPaused",
          "params" => %{
            "requestId" => request_id,
            "networkId" => network_id,
            "resourceType" => resource_type,
            "request" => %{"url" => url}
          }
        })}}
    )
  end
end
