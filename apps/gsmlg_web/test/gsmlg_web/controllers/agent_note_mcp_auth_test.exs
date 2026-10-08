defmodule GSMLG.Web.AgentNoteMCPAuthTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test
  alias GSMLG.Web.Plugs.AgentNoteMCPAuth

  test "missing credentials reject before MCP transport" do
    conn = conn(:post, "/mcp", "{}") |> AgentNoteMCPAuth.call([])
    assert conn.status == 401
    assert conn.halted
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
  end

  test "ambiguous or malformed authorization headers reject" do
    for headers <- [
          [{"authorization", "Basic abc"}],
          [{"authorization", "Bearer "}],
          [{"authorization", "Bearer bad"}, {"authorization", "Bearer other"}],
          [{"x-api-key", ""}]
        ] do
      conn = %{conn(:post, "/mcp") | req_headers: headers} |> AgentNoteMCPAuth.call([])
      assert conn.status == 401
      assert conn.halted
    end
  end
end
