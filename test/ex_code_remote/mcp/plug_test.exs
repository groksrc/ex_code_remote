defmodule ExCodeRemote.MCP.PlugTest do
  @moduledoc """
  Tests the MCP HTTP transport end-to-end through Cowboy. Each test boots
  the real router on a random port and POSTs JSON-RPC, so we cover routing,
  body parsing, dispatch, and response shape together.
  """

  use ExUnit.Case, async: false

  alias ExCodeRemote.Test.FakeAgent

  setup :setup_server

  defp setup_server(ctx), do: ExCodeRemote.Test.Helpers.setup_server(ctx)

  import ExCodeRemote.Test.Helpers, only: [await_connected: 1]

  defp start_agent(port, machine, handler \\ nil) do
    opts = [port: port, machine: machine, owner: self()]
    opts = if handler, do: Keyword.put(opts, :handler, handler), else: opts

    {:ok, _pid} = start_supervised({FakeAgent, opts}, id: machine)
    await_connected(machine)
  end

  describe "initialize" do
    test "negotiates protocol and returns server info", %{port: port} do
      response =
        post_jsonrpc(port, "initialize", %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        })

      assert %{
               "jsonrpc" => "2.0",
               "result" => %{
                 "protocolVersion" => "2025-03-26",
                 "serverInfo" => %{"name" => "code-remote"},
                 "capabilities" => %{"tools" => %{}}
               }
             } = response
    end

    test "falls back to server protocol version when client omits one", %{port: port} do
      response = post_jsonrpc(port, "initialize", %{})
      assert is_binary(response["result"]["protocolVersion"])
    end
  end

  describe "ping" do
    test "responds with empty result", %{port: port} do
      response = post_jsonrpc(port, "ping", %{})
      assert response["result"] == %{}
    end
  end

  describe "tools/list" do
    test "lists all five tools with required argument schemas", %{port: port} do
      response = post_jsonrpc(port, "tools/list", %{})
      tools = response["result"]["tools"]

      names = Enum.map(tools, & &1["name"])

      assert Enum.sort(names) ==
               Enum.sort([
                 "run_shell_command",
                 "read_file",
                 "write_file",
                 "list_directory",
                 "check_agent_status"
               ])

      shell = Enum.find(tools, &(&1["name"] == "run_shell_command"))
      assert shell["inputSchema"]["required"] == ["machine", "command"]

      status = Enum.find(tools, &(&1["name"] == "check_agent_status"))
      assert status["inputSchema"]["properties"] == %{}
    end
  end

  describe "check_agent_status" do
    test "returns no agents message when none connected", %{port: port} do
      content = call_tool(port, "check_agent_status", %{})
      assert content["text"] == "No agents are connected."
    end

    test "returns single agent name without comma", %{port: port} do
      start_agent(port, "my-machine")
      content = call_tool(port, "check_agent_status", %{})
      assert content["text"] == "my-machine"
    end

    test "returns comma-separated list for multiple agents", %{port: port} do
      start_agent(port, "machine-a")
      start_agent(port, "machine-b")

      content = call_tool(port, "check_agent_status", %{})
      assert "machine-a" in String.split(content["text"], ", ")
      assert "machine-b" in String.split(content["text"], ", ")
    end
  end

  describe "run_shell_command" do
    test "dispatches and returns formatted result", %{port: port} do
      handler = fn %{"id" => id} ->
        %{type: "result", id: id, status: "completed", output: "hello world", exit_code: 0}
      end

      start_agent(port, "shell-test", handler)

      content =
        call_tool(port, "run_shell_command", %{
          "machine" => "shell-test",
          "command" => "echo hello"
        })

      assert content["text"] =~ "hello world"
      assert content["text"] =~ "[exit_code: 0]"
    end

    test "returns isError for unknown machine", %{port: port} do
      result =
        call_tool_raw(port, "run_shell_command", %{"machine" => "no-such", "command" => "echo"})

      assert result["isError"] == true

      assert hd(result["content"])["text"] =~ "not connected" or
               hd(result["content"])["text"] =~ "No agents"
    end

    test "missing machine returns validation error", %{port: port} do
      result = call_tool_raw(port, "run_shell_command", %{"command" => "echo"})
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "machine"
    end

    test "missing command returns validation error", %{port: port} do
      start_agent(port, "val-test")
      result = call_tool_raw(port, "run_shell_command", %{"machine" => "val-test"})
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "command"
    end

    test "zero timeout is clamped to 1", %{port: port} do
      handler = fn %{"id" => id, "timeout" => timeout} ->
        %{
          type: "result",
          id: id,
          status: "completed",
          output: "timeout was #{timeout}",
          exit_code: 0
        }
      end

      start_agent(port, "clamp-test", handler)

      content =
        call_tool(port, "run_shell_command", %{
          "machine" => "clamp-test",
          "command" => "echo",
          "timeout" => 0
        })

      assert content["text"] =~ "timeout was 1"
    end
  end

  describe "read_file" do
    test "dispatches and returns file content", %{port: port} do
      handler = fn %{"id" => id} ->
        %{type: "result", id: id, status: "completed", output: "file contents here", exit_code: 0}
      end

      start_agent(port, "read-test", handler)
      content = call_tool(port, "read_file", %{"machine" => "read-test", "path" => "~/test.txt"})
      assert content["text"] =~ "file contents here"
    end
  end

  describe "write_file" do
    test "dispatches and returns confirmation", %{port: port} do
      handler = fn %{"id" => id} ->
        %{
          type: "result",
          id: id,
          status: "completed",
          output: "Written 5 bytes to /tmp/test",
          exit_code: 0
        }
      end

      start_agent(port, "write-test", handler)

      content =
        call_tool(port, "write_file", %{
          "machine" => "write-test",
          "path" => "/tmp/test",
          "content" => "hello"
        })

      assert content["text"] =~ "Written"
    end

    test "allows empty content", %{port: port} do
      handler = fn %{"id" => id} ->
        %{type: "result", id: id, status: "completed", output: "Written 0 bytes", exit_code: 0}
      end

      start_agent(port, "write-empty", handler)

      content =
        call_tool(port, "write_file", %{
          "machine" => "write-empty",
          "path" => "/tmp/empty",
          "content" => ""
        })

      assert content["text"] =~ "Written"
    end
  end

  describe "list_directory" do
    test "dispatches and returns listing", %{port: port} do
      handler = fn %{"id" => id} ->
        %{
          type: "result",
          id: id,
          status: "completed",
          output: "dir\t0\tDocuments\nfile\t1234\tREADME.md",
          exit_code: 0
        }
      end

      start_agent(port, "list-test", handler)
      content = call_tool(port, "list_directory", %{"machine" => "list-test", "path" => "~"})
      assert content["text"] =~ "Documents"
      assert content["text"] =~ "README.md"
    end
  end

  describe "JSON-RPC protocol behavior" do
    test "unknown method returns -32601", %{port: port} do
      response = post_jsonrpc(port, "does/not/exist", %{})
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] =~ "does/not/exist"
    end

    test "unknown tool returns isError true", %{port: port} do
      result = call_tool_raw(port, "no_such_tool", %{})
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "Unknown tool"
    end

    test "notification (no id) returns 202 with empty body", %{port: port} do
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized",
          "params" => %{}
        })

      {status, _headers, resp_body} = http_post(port, body)
      assert status == 202
      assert resp_body == ""
    end

    test "malformed JSON returns -32700 parse error", %{port: port} do
      {status, _headers, body} = http_post(port, "not json")
      assert status == 400
      decoded = Jason.decode!(body)
      assert decoded["error"]["code"] == -32700
    end

    test "batch requests are rejected with a clear error", %{port: port} do
      body = Jason.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}])
      {status, _headers, resp_body} = http_post(port, body)
      assert status == 400
      decoded = Jason.decode!(resp_body)
      assert decoded["error"]["message"] =~ "Batch"
    end
  end

  describe "HTTP transport behavior" do
    test "GET returns 405 with Allow header (no SSE)", %{port: port} do
      {:ok, resp} = :httpc.request(:get, {~c"http://localhost:#{port}/mcp", []}, [], [])
      {{_, status, _}, headers, _body} = resp
      assert status == 405

      headers_map =
        for {k, v} <- headers, into: %{}, do: {String.downcase(to_string(k)), to_string(v)}

      assert headers_map["allow"] =~ "POST"
    end

    test "OPTIONS returns 204 with CORS headers", %{port: port} do
      req = {~c"http://localhost:#{port}/mcp", []}
      {:ok, resp} = :httpc.request(:options, req, [], [])
      {{_, status, _}, headers, _body} = resp
      assert status == 204

      headers_map =
        for {k, v} <- headers, into: %{}, do: {String.downcase(to_string(k)), to_string(v)}

      assert headers_map["access-control-allow-origin"] == "*"
      assert headers_map["access-control-allow-methods"] =~ "POST"
    end

    test "DELETE returns 204 (session termination, no-op)", %{port: port} do
      url = ~c"http://localhost:#{port}/mcp"
      {:ok, resp} = :httpc.request(:delete, {url, []}, [], [])
      {{_, status, _}, _headers, _body} = resp
      assert status == 204
    end

    test "MCP responses include CORS headers", %{port: port} do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      {_status, headers, _body} = http_post(port, body)

      headers_map =
        for {k, v} <- headers, into: %{}, do: {String.downcase(to_string(k)), to_string(v)}

      assert headers_map["access-control-allow-origin"] == "*"
    end

    test "request body over 10MB is rejected with 413", %{port: port} do
      # 11MB content payload — should fail at the body-read step before
      # reaching the JSON decoder.
      huge = String.duplicate("a", 11_000_000)

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "write_file",
            "arguments" => %{"machine" => "x", "path" => "/tmp/x", "content" => huge}
          }
        })

      {status, _headers, _resp_body} = http_post(port, body)
      assert status == 413
    end
  end

  describe "router coexistence" do
    test "health endpoint still works", %{port: port} do
      {:ok, resp} = :httpc.request(:get, {~c"http://localhost:#{port}/health", []}, [], [])
      {{_, 200, _}, _headers, _body} = resp
    end

    test "404 still works for unknown routes", %{port: port} do
      {:ok, resp} = :httpc.request(:get, {~c"http://localhost:#{port}/nonexistent", []}, [], [])
      {{_, status, _}, _headers, _body} = resp
      assert status == 404
    end

    test "MCP forward accepts both /mcp and /mcp/sse paths", %{port: port} do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      for path <- ["/mcp", "/mcp/sse", "/mcp/v1/messages"] do
        {status, _headers, resp_body} = http_post(port, body, path)
        assert status == 200, "expected 200 for #{path}, got #{status}"
        assert Jason.decode!(resp_body)["result"] == %{}
      end
    end
  end

  # --- Helpers ---

  defp call_tool(port, name, args) do
    result = call_tool_raw(port, name, args)
    hd(result["content"])
  end

  defp call_tool_raw(port, name, args) do
    response = post_jsonrpc(port, "tools/call", %{"name" => name, "arguments" => args})
    response["result"]
  end

  defp post_jsonrpc(port, method, params) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    {status, _headers, resp_body} = http_post(port, body)
    assert status == 200, "expected 200 for #{method}, got #{status}: #{resp_body}"
    Jason.decode!(resp_body)
  end

  defp http_post(port, body, path \\ "/mcp") do
    url = ~c"http://localhost:#{port}#{path}"
    request = {url, [], ~c"application/json", body}
    {:ok, {{_, status, _}, headers, resp_body}} = :httpc.request(:post, request, [], [])
    {status, headers, to_string(resp_body)}
  end
end
