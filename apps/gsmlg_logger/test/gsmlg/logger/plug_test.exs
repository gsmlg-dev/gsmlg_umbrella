defmodule GSMLG.Logger.PlugTest do
  use GSMLG.Logger.Case, async: false
  import GSMLG.Logger.Plug
  require Logger

  describe "attach/3" do
    test "attaches a telemetry handler" do
      # Get initial handlers count
      initial_handlers = :telemetry.list_handlers([:phoenix, :endpoint, :stop])

      assert attach(
               "gsmlg-logger-phoenix-requests",
               [:phoenix, :endpoint, :stop],
               :info
             ) == :ok

      # Check that our handler was added (there should be one more than initial)
      handlers = :telemetry.list_handlers([:phoenix, :endpoint, :stop])
      assert length(handlers) == length(initial_handlers) + 1

      # Find our handler in the list
      our_handler =
        Enum.find(handlers, fn handler ->
          handler.id == "gsmlg-logger-phoenix-requests"
        end)

      assert our_handler != nil
      assert our_handler.config == :info
      assert our_handler.event_name == [:phoenix, :endpoint, :stop]
    end
  end

  describe "telemetry_logging_handler/4 for Basic formatter" do
    setup do
      formatter = {GSMLG.Logger.Formatters.Basic, metadata: :all}
      :logger.update_handler_config(:default, :formatter, formatter)
    end

    test "logs request latency and metadata" do
      conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_status(200)

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "message" => "GET / [Sent 200 in 500us]",
               "metadata" => %{"duration_us" => 500},
               "request" => %{
                 "client" => %{"ip" => "127.0.0.1", "user_agent" => nil},
                 "connection" => %{
                   "method" => "GET",
                   "path" => "/",
                   "protocol" => "HTTP/1.1",
                   "status" => 200
                 }
               }
             } = decode_or_print_error(log)
    end

    test "logs unsent connections" do
      conn = Plug.Test.conn(:get, "/")

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "message" => "GET / [Sent in 500us]",
               "metadata" => %{"duration_us" => 500},
               "request" => %{
                 "client" => %{"ip" => "127.0.0.1", "user_agent" => nil},
                 "connection" => %{
                   "method" => "GET",
                   "path" => "/",
                   "protocol" => "HTTP/1.1",
                   "status" => nil
                 }
               }
             } = decode_or_print_error(log)
    end

    test "logs chunked responses" do
      conn = %{Plug.Test.conn(:get, "/") | state: :set_chunked}

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "message" => "GET / [Chunked in 500us]",
               "metadata" => %{"duration_us" => 500},
               "request" => %{
                 "client" => %{"ip" => "127.0.0.1", "user_agent" => nil},
                 "connection" => %{
                   "method" => "GET",
                   "path" => "/",
                   "protocol" => "HTTP/1.1",
                   "status" => nil
                 }
               }
             } = decode_or_print_error(log)
    end

    test "logs long-running responses" do
      conn = %{Plug.Test.conn(:get, "/") | state: :set_chunked}

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{"message" => "GET / [Chunked in 500ms]"} = decode_or_print_error(log)
    end

    test "allows disabling logging at runtime" do
      conn = Plug.Test.conn(:get, "/")

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 5000},
            %{conn: conn},
            {__MODULE__, :ignore_log, [:arg]}
          )

          Logger.flush()
        end)

      assert log == ""
    end
  end

  describe "telemetry_logging_handler/4 for DataDog formatter" do
    setup do
      formatter =
        {GSMLG.Logger.Formatters.Datadog,
         metadata: [:network, :phoenix, :duration, :http, :"usr.id"]}

      :logger.update_handler_config(:default, :formatter, formatter)
    end

    test "logs request latency and metadata" do
      conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_status(200)

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "message" => "GET / [Sent 200 in 500us]",
               "http" => %{
                 "method" => "GET",
                 "referer" => nil,
                 "request_id" => nil,
                 "status_code" => 200,
                 "url" => "http://www.example.com/",
                 "url_details" => %{
                   "host" => "www.example.com",
                   "path" => "/",
                   "port" => 80,
                   "queryString" => "",
                   "scheme" => "http"
                 },
                 "useragent" => nil
               },
               "logger" => %{},
               "network" => %{"client" => %{"ip" => "127.0.0.1"}}
             } = decode_or_print_error(log)
    end

    test "logs requests" do
      conn =
        Plug.Test.conn(:get, "/foo/bar?baz=qux#frag")
        |> Plug.Conn.put_req_header(
          "user-agent",
          "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"
        )
        |> Plug.Conn.put_req_header("referer", "http://www.example.com/")
        |> Plug.Conn.put_status(200)

      log =
        capture_log(fn ->
          Logger.metadata(request_id: "123")

          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "http" => %{
                 "method" => "GET",
                 "referer" => "http://www.example.com/",
                 "request_id" => "123",
                 "status_code" => 200,
                 "url" => "http://www.example.com/foo/bar?baz=qux",
                 "url_details" => %{
                   "host" => "www.example.com",
                   "path" => "/foo/bar",
                   "port" => 80,
                   "queryString" => "baz=qux",
                   "scheme" => "http"
                 },
                 "useragent" => "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"
               },
               "message" => "GET /foo/bar [Sent 200 in 500us]",
               "network" => %{"client" => %{"ip" => "127.0.0.1"}}
             } = decode_or_print_error(log)
    end

    test "logs unsent connections" do
      conn = Plug.Test.conn(:get, "/")

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "message" => "GET / [Sent in 500us]",
               "http" => %{
                 "method" => "GET",
                 "referer" => nil,
                 "request_id" => nil,
                 "status_code" => nil,
                 "url" => "http://www.example.com/",
                 "url_details" => %{
                   "host" => "www.example.com",
                   "path" => "/",
                   "port" => 80,
                   "queryString" => "",
                   "scheme" => "http"
                 },
                 "useragent" => nil
               },
               "logger" => %{},
               "network" => %{"client" => %{"ip" => "127.0.0.1"}}
             } = decode_or_print_error(log)
    end

    test "logs chunked responses" do
      conn = %{Plug.Test.conn(:get, "/") | state: :set_chunked}

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "message" => "GET / [Chunked in 500us]",
               "http" => %{
                 "method" => "GET",
                 "referer" => nil,
                 "request_id" => nil,
                 "status_code" => nil,
                 "url" => "http://www.example.com/",
                 "url_details" => %{
                   "host" => "www.example.com",
                   "path" => "/",
                   "port" => 80,
                   "queryString" => "",
                   "scheme" => "http"
                 },
                 "useragent" => nil
               },
               "logger" => %{},
               "network" => %{"client" => %{"ip" => "127.0.0.1"}}
             } = decode_or_print_error(log)
    end

    test "logs long-running responses" do
      conn = %{Plug.Test.conn(:get, "/") | state: :set_chunked}

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{"message" => "GET / [Chunked in 500ms]"} = decode_or_print_error(log)
    end

    test "allows disabling logging at runtime" do
      conn = Plug.Test.conn(:get, "/")

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 5000},
            %{conn: conn},
            {__MODULE__, :ignore_log, [:arg]}
          )

          Logger.flush()
        end)

      assert log == ""
    end
  end

  describe "telemetry_logging_handler/4 for GoogleCloud formatter" do
    setup do
      formatter = {GSMLG.Logger.Formatters.GoogleCloud, metadata: {:all_except, [:conn]}}
      :logger.update_handler_config(:default, :formatter, formatter)
    end

    test "logs request latency and metadata" do
      conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_status(200)

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "message" => "GET / [Sent 200 in 500us]",
               "duration_us" => 500,
               "httpRequest" => %{
                 "protocol" => "HTTP/1.1",
                 "referer" => nil,
                 "remoteIp" => "127.0.0.1",
                 "requestMethod" => "GET",
                 "requestUrl" => "http://www.example.com/",
                 "status" => 200,
                 "userAgent" => nil
               },
               "severity" => "INFO"
             } = decode_or_print_error(log)
    end

    test "logs unsent connections" do
      conn = Plug.Test.conn(:get, "/")

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "message" => "GET / [Sent in 500us]",
               "duration_us" => 500,
               "httpRequest" => %{
                 "protocol" => "HTTP/1.1",
                 "referer" => nil,
                 "remoteIp" => "127.0.0.1",
                 "requestMethod" => "GET",
                 "requestUrl" => "http://www.example.com/",
                 "status" => nil,
                 "userAgent" => nil
               },
               "severity" => "INFO"
             } = decode_or_print_error(log)
    end

    test "logs chunked responses" do
      conn = %{Plug.Test.conn(:get, "/") | state: :set_chunked}

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "message" => "GET / [Chunked in 500us]",
               "duration_us" => 500,
               "httpRequest" => %{
                 "protocol" => "HTTP/1.1",
                 "referer" => nil,
                 "remoteIp" => "127.0.0.1",
                 "requestMethod" => "GET",
                 "requestUrl" => "http://www.example.com/",
                 "status" => nil,
                 "userAgent" => nil
               },
               "severity" => "INFO"
             } = decode_or_print_error(log)
    end

    test "logs long-running responses" do
      conn = %{Plug.Test.conn(:get, "/") | state: :set_chunked}

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{"message" => "GET / [Chunked in 500ms]"} = decode_or_print_error(log)
    end

    test "allows disabling logging at runtime" do
      conn = Plug.Test.conn(:get, "/")

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 5000},
            %{conn: conn},
            {__MODULE__, :ignore_log, [:arg]}
          )

          Logger.flush()
        end)

      assert log == ""
    end
  end

  describe "telemetry_logging_handler/4 for Elastic formatter" do
    setup do
      formatter = {GSMLG.Logger.Formatters.Elastic, metadata: nil}
      :logger.update_handler_config(:default, :formatter, formatter)
    end

    test "logs request latency and metadata" do
      conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_status(200)

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "client.ip" => "127.0.0.1",
               "http.request.method" => "GET",
               "http.request.referrer" => nil,
               "http.response.status_code" => 200,
               "http.version" => "HTTP/1.1",
               "url.path" => "/",
               "user_agent.original" => nil
             } = decode_or_print_error(log)
    end

    test "logs unsent connections" do
      conn = Plug.Test.conn(:get, "/")

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "client.ip" => "127.0.0.1",
               "http.request.method" => "GET",
               "http.request.referrer" => nil,
               "http.response.status_code" => nil,
               "http.version" => "HTTP/1.1",
               "url.path" => "/",
               "user_agent.original" => nil
             } = decode_or_print_error(log)
    end

    test "logs chunked responses" do
      conn = %{Plug.Test.conn(:get, "/") | state: :set_chunked}

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{
               "client.ip" => "127.0.0.1",
               "http.request.method" => "GET",
               "http.request.referrer" => nil,
               "http.response.status_code" => nil,
               "http.version" => "HTTP/1.1",
               "url.path" => "/",
               "user_agent.original" => nil
             } = decode_or_print_error(log)
    end

    test "logs long-running responses" do
      conn = %{Plug.Test.conn(:get, "/") | state: :set_chunked}

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 500_000_000},
            %{conn: conn},
            :info
          )

          Logger.flush()
        end)

      assert %{"message" => "GET / [Chunked in 500ms]"} = decode_or_print_error(log)
    end

    test "allows disabling logging at runtime" do
      conn = Plug.Test.conn(:get, "/")

      log =
        capture_log(fn ->
          telemetry_logging_handler(
            [:phoenix, :endpoint, :stop],
            %{duration: 5000},
            %{conn: conn},
            {__MODULE__, :ignore_log, [:arg]}
          )

          Logger.flush()
        end)

      assert log == ""
    end
  end

  test "telemetry_logging_handler/4 returns :ok even when Logger is not called" do
    log =
      capture_log(fn ->
        assert :ok == telemetry_logging_handler([], %{duration: 0}, %{conn: %Plug.Conn{}}, false)

        Logger.flush()
      end)

    assert log == ""
  end

  def ignore_log(%Plug.Conn{}, :arg), do: false
end
