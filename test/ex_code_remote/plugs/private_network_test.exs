defmodule ExCodeRemote.Plugs.PrivateNetworkTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  alias ExCodeRemote.Plugs.PrivateNetwork

  # Helper to build a conn with optional headers and remote_ip
  defp build_conn(opts \\ []) do
    remote_ip = Keyword.get(opts, :remote_ip, {127, 0, 0, 1})
    headers = Keyword.get(opts, :headers, [])

    conn = conn(:get, "/ws/agent")
    conn = %{conn | remote_ip: remote_ip}

    Enum.reduce(headers, conn, fn {key, value}, acc ->
      put_req_header(acc, key, value)
    end)
  end

  defp with_enforcement(enabled, fun) do
    old = Application.get_env(:ex_code_remote, :require_private_network)
    Application.put_env(:ex_code_remote, :require_private_network, enabled)

    try do
      fun.()
    after
      if old == nil do
        Application.delete_env(:ex_code_remote, :require_private_network)
      else
        Application.put_env(:ex_code_remote, :require_private_network, old)
      end
    end
  end

  describe "CIDR boundary" do
    test "100.64.0.0 allowed (base of range)" do
      assert PrivateNetwork.allowed?({100, 64, 0, 0})
    end

    test "100.64.0.1 allowed" do
      assert PrivateNetwork.allowed?({100, 64, 0, 1})
    end

    test "100.127.255.255 allowed (upper edge of /10)" do
      assert PrivateNetwork.allowed?({100, 127, 255, 255})
    end

    test "100.100.50.25 allowed (mid-range)" do
      assert PrivateNetwork.allowed?({100, 100, 50, 25})
    end

    test "100.128.0.0 denied (just outside /10)" do
      refute PrivateNetwork.allowed?({100, 128, 0, 0})
    end

    test "100.63.255.255 denied (just below range)" do
      refute PrivateNetwork.allowed?({100, 63, 255, 255})
    end

    test "8.8.8.8 denied" do
      refute PrivateNetwork.allowed?({8, 8, 8, 8})
    end

    test "192.168.1.1 denied (private but not Tailscale)" do
      refute PrivateNetwork.allowed?({192, 168, 1, 1})
    end

    test "10.0.0.1 denied (private but not Tailscale)" do
      refute PrivateNetwork.allowed?({10, 0, 0, 1})
    end
  end

  describe "loopback always allowed" do
    test "127.0.0.1 allowed" do
      assert PrivateNetwork.allowed?({127, 0, 0, 1})
    end

    test "127.255.255.255 allowed" do
      assert PrivateNetwork.allowed?({127, 255, 255, 255})
    end

    test "::1 allowed" do
      assert PrivateNetwork.allowed?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "loopback passes even when enforcement is enabled" do
      with_enforcement(true, fn ->
        conn = build_conn(remote_ip: {127, 0, 0, 1})
        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end
  end

  describe "fly-client-ip header" do
    test "used when present" do
      with_enforcement(true, fn ->
        conn =
          build_conn(
            remote_ip: {8, 8, 8, 8},
            headers: [{"fly-client-ip", "100.64.1.1"}]
          )

        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end

    test "x-forwarded-for ignored when fly-client-ip is present" do
      with_enforcement(true, fn ->
        conn =
          build_conn(
            remote_ip: {8, 8, 8, 8},
            headers: [
              {"fly-client-ip", "100.64.1.1"},
              {"x-forwarded-for", "8.8.8.8"}
            ]
          )

        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end

    test "malformed fly-client-ip denies (fail closed)" do
      with_enforcement(true, fn ->
        conn =
          build_conn(
            remote_ip: {100, 64, 0, 1},
            headers: [{"fly-client-ip", "not-an-ip"}]
          )

        result = PrivateNetwork.call(conn, [])
        assert result.halted
        assert result.status == 403
      end)
    end
  end

  describe "x-forwarded-for parsing" do
    test "single IP used" do
      with_enforcement(true, fn ->
        conn =
          build_conn(
            remote_ip: {8, 8, 8, 8},
            headers: [{"x-forwarded-for", "100.64.1.1"}]
          )

        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end

    test "rightmost IP used with multiple IPs" do
      with_enforcement(true, fn ->
        # Leftmost is Tailscale (spoofed), rightmost is public (real)
        conn =
          build_conn(
            remote_ip: {8, 8, 8, 8},
            headers: [{"x-forwarded-for", "100.64.1.1, 203.0.113.50"}]
          )

        result = PrivateNetwork.call(conn, [])
        assert result.halted
        assert result.status == 403
      end)
    end

    test "spoofed Tailscale IP in leftmost position denied" do
      with_enforcement(true, fn ->
        conn =
          build_conn(
            remote_ip: {8, 8, 8, 8},
            headers: [{"x-forwarded-for", "100.64.0.1, 100.100.1.1, 203.0.113.50"}]
          )

        result = PrivateNetwork.call(conn, [])
        assert result.halted
        assert result.status == 403
      end)
    end

    test "rightmost Tailscale IP allowed" do
      with_enforcement(true, fn ->
        conn =
          build_conn(
            remote_ip: {8, 8, 8, 8},
            headers: [{"x-forwarded-for", "203.0.113.50, 100.64.1.1"}]
          )

        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end

    test "whitespace trimmed around IPs" do
      with_enforcement(true, fn ->
        conn =
          build_conn(
            remote_ip: {8, 8, 8, 8},
            headers: [{"x-forwarded-for", "  203.0.113.50 ,  100.64.1.1  "}]
          )

        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end

    test "malformed x-forwarded-for denies (fail closed)" do
      with_enforcement(true, fn ->
        conn =
          build_conn(
            remote_ip: {100, 64, 0, 1},
            headers: [{"x-forwarded-for", "not-an-ip"}]
          )

        result = PrivateNetwork.call(conn, [])
        assert result.halted
        assert result.status == 403
      end)
    end

    test "empty x-forwarded-for falls back to conn.remote_ip" do
      with_enforcement(true, fn ->
        conn =
          build_conn(
            remote_ip: {100, 64, 0, 1},
            headers: [{"x-forwarded-for", ""}]
          )

        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end

    test "multiple x-forwarded-for headers concatenated, rightmost used" do
      with_enforcement(true, fn ->
        conn = build_conn(remote_ip: {8, 8, 8, 8})
        conn = put_req_header(conn, "x-forwarded-for", "10.0.0.1")
        # Plug merges multiple same-name headers with comma
        conn = %{conn | req_headers: conn.req_headers ++ [{"x-forwarded-for", "100.64.1.1"}]}

        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end
  end

  describe "direct connection fallback" do
    test "conn.remote_ip used when no proxy headers" do
      with_enforcement(true, fn ->
        conn = build_conn(remote_ip: {100, 64, 0, 1})
        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end

    test "public remote_ip denied when no proxy headers" do
      with_enforcement(true, fn ->
        conn = build_conn(remote_ip: {203, 0, 113, 50})
        result = PrivateNetwork.call(conn, [])
        assert result.halted
        assert result.status == 403
      end)
    end
  end

  describe "feature gate" do
    test "all IPs allowed when enforcement disabled" do
      with_enforcement(false, fn ->
        conn = build_conn(remote_ip: {203, 0, 113, 50})
        result = PrivateNetwork.call(conn, [])
        refute result.halted
      end)
    end

    test "public IP denied when enforcement enabled" do
      with_enforcement(true, fn ->
        conn = build_conn(remote_ip: {203, 0, 113, 50})
        result = PrivateNetwork.call(conn, [])
        assert result.halted
      end)
    end
  end

  describe "logging" do
    test "denied requests log at warning with IP and path" do
      with_enforcement(true, fn ->
        log =
          capture_log([level: :warning], fn ->
            conn = build_conn(remote_ip: {203, 0, 113, 50})
            PrivateNetwork.call(conn, [])
          end)

        assert log =~ "203.0.113.50"
        assert log =~ "/ws/agent"
        assert log =~ "Private network denied"
      end)
    end
  end

  describe "403 response format" do
    test "denied requests return JSON body with error field" do
      with_enforcement(true, fn ->
        conn = build_conn(remote_ip: {203, 0, 113, 50})
        result = PrivateNetwork.call(conn, [])

        assert result.status == 403
        body = Jason.decode!(result.resp_body)
        assert body["error"] == "private_network_required"
      end)
    end
  end

  describe "router integration" do
    setup ctx do
      ExCodeRemote.Test.Helpers.setup_server(ctx)
    end

    test "/health is not gated", %{port: port} do
      with_enforcement(true, fn ->
        {:ok, resp} = :httpc.request(:get, {~c"http://localhost:#{port}/health", []}, [], [])
        {{_, 200, _}, _headers, _body} = resp
      end)
    end

    test "MCP endpoint is not gated", %{port: port} do
      with_enforcement(true, fn ->
        # POST to MCP message endpoint — should get a response that isn't 403
        # (will be 400 or similar since we're not sending valid MCP, but not 403)
        body = Jason.encode!(%{jsonrpc: "2.0", method: "initialize", id: 1})

        {:ok, resp} =
          :httpc.request(
            :post,
            {~c"http://localhost:#{port}/mcp/message", [{'content-type', 'application/json'}],
             ~c"application/json", String.to_charlist(body)},
            [],
            []
          )

        {{_, status, _}, _headers, _body} = resp
        # MCP responds (not 403) — exact status depends on MCP session handling
        assert status != 403
      end)
    end
  end
end
