defmodule ExCodeRemote.MCP.ServerTest do
  use ExUnit.Case, async: false

  alias ExCodeRemote.Test.FakeAgent

  @token "test-token-for-testing"

  setup :setup_server

  defp setup_server(ctx), do: ExCodeRemote.Test.Helpers.setup_server(ctx)

  import ExCodeRemote.Test.Helpers, only: [await_connected: 1, await_connected: 2, await_disconnected: 1, await_disconnected: 2]

  defp start_agent(port, machine, handler \\ nil) do
    opts = [port: port, machine: machine, owner: self()]
    opts = if handler, do: Keyword.put(opts, :handler, handler), else: opts

    {:ok, _pid} = start_supervised({FakeAgent, opts}, id: machine)
    await_connected(machine)
  end

  describe "check_agent_status" do
    test "returns no agents message when none connected", %{port: port} do
      result = call_tool(port, "check_agent_status", %{})
      assert result["type"] == "text"
      assert result["text"] == "No agents are connected."
    end

    test "returns single agent name without comma", %{port: port} do
      start_agent(port, "my-machine")
      result = call_tool(port, "check_agent_status", %{})
      assert result["text"] == "my-machine"
    end

    test "returns comma-separated list for multiple agents", %{port: port} do
      start_agent(port, "machine-a")
      start_agent(port, "machine-b")

      result = call_tool(port, "check_agent_status", %{})
      text = result["text"]
      assert "machine-a" in String.split(text, ", ")
      assert "machine-b" in String.split(text, ", ")
    end
  end

  describe "run_shell_command" do
    test "dispatches and returns formatted result", %{port: port} do
      handler = fn %{"id" => id} ->
        %{type: "result", id: id, status: "completed", output: "hello world", exit_code: 0}
      end

      start_agent(port, "shell-test", handler)

      result =
        call_tool(port, "run_shell_command", %{
          "machine" => "shell-test",
          "command" => "echo hello"
        })

      assert result["text"] =~ "hello world"
      assert result["text"] =~ "[exit_code: 0]"
    end

    test "returns error for unknown machine", %{port: port} do
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

      result =
        call_tool(port, "run_shell_command", %{
          "machine" => "clamp-test",
          "command" => "echo",
          "timeout" => 0
        })

      assert result["text"] =~ "timeout was 1"
    end
  end

  describe "read_file" do
    test "dispatches and returns file content", %{port: port} do
      handler = fn %{"id" => id} ->
        %{type: "result", id: id, status: "completed", output: "file contents here", exit_code: 0}
      end

      start_agent(port, "read-test", handler)
      result = call_tool(port, "read_file", %{"machine" => "read-test", "path" => "~/test.txt"})
      assert result["text"] =~ "file contents here"
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

      result =
        call_tool(port, "write_file", %{
          "machine" => "write-test",
          "path" => "/tmp/test",
          "content" => "hello"
        })

      assert result["text"] =~ "Written"
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
      result = call_tool(port, "list_directory", %{"machine" => "list-test", "path" => "~"})
      assert result["text"] =~ "Documents"
      assert result["text"] =~ "README.md"
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
      # Should be 404, not caught by MCP
      assert status == 404
    end
  end

  # --- Helpers ---

  # Call a tool via the MCP server module directly (bypasses HTTP)
  defp call_tool(port, name, args) do
    result = call_tool_raw(port, name, args)

    case result do
      %{"content" => [content | _]} -> content
      [content | _] -> content
      content -> content
    end
  end

  defp call_tool_raw(_port, name, args) do
    {:ok, result, _state} =
      ExCodeRemote.MCP.Server.handle_call_tool(name, args, %{})

    case result do
      [%{type: "text"} = content] ->
        %{"content" => [stringify_keys(content)]}

      %{content: content, isError: true} ->
        %{"isError" => true, "content" => Enum.map(content, &stringify_keys/1)}

      other ->
        other
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
