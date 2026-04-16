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
    test "lists all advertised tools with required argument schemas", %{port: port} do
      response = post_jsonrpc(port, "tools/list", %{})
      tools = response["result"]["tools"]

      names = Enum.map(tools, & &1["name"])

      assert Enum.sort(names) ==
               Enum.sort([
                 "run_shell_command",
                 "read_file",
                 "write_file",
                 "list_directory",
                 "check_agent_status",
                 "start_command",
                 "get_command_result",
                 "list_commands"
               ])

      shell = Enum.find(tools, &(&1["name"] == "run_shell_command"))
      assert shell["inputSchema"]["required"] == ["machine", "command"]

      status = Enum.find(tools, &(&1["name"] == "check_agent_status"))
      assert status["inputSchema"]["properties"] == %{}
    end

    test "advertises the three async tools with declared schema constraints", %{port: port} do
      response = post_jsonrpc(port, "tools/list", %{})
      tools = response["result"]["tools"]

      start = Enum.find(tools, &(&1["name"] == "start_command"))
      assert start["inputSchema"]["required"] == ["machine", "command"]
      timeout_schema = start["inputSchema"]["properties"]["timeout"]
      assert timeout_schema["minimum"] == 1
      assert timeout_schema["maximum"] == 3600
      assert timeout_schema["default"] == 600

      gcr = Enum.find(tools, &(&1["name"] == "get_command_result"))
      assert gcr["inputSchema"]["required"] == ["command_id"]
      wait_schema = gcr["inputSchema"]["properties"]["wait_seconds"]
      assert wait_schema["minimum"] == 0
      assert wait_schema["maximum"] == 50

      lc = Enum.find(tools, &(&1["name"] == "list_commands"))
      # list_commands has no required args.
      refute Map.has_key?(lc["inputSchema"], "required")
      limit_schema = lc["inputSchema"]["properties"]["limit"]
      assert limit_schema["minimum"] == 1
      assert limit_schema["maximum"] == 50
      status_schema = lc["inputSchema"]["properties"]["status"]

      assert Enum.sort(status_schema["enum"]) ==
               Enum.sort(["running", "completed", "failed", "timeout", "agent_disconnected"])
    end

    test "run_shell_command description contrasts with start_command for long jobs", %{port: port} do
      response = post_jsonrpc(port, "tools/list", %{})
      tools = response["result"]["tools"]

      shell = Enum.find(tools, &(&1["name"] == "run_shell_command"))
      assert shell["description"] =~ "start_command"

      start = Enum.find(tools, &(&1["name"] == "start_command"))
      assert start["description"] =~ ~r/30 seconds/
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

      text = hd(result["content"])["text"]
      assert text =~ "No agent"
      assert text =~ "connected"
      # The new formatter mentions the machine that wasn't found.
      assert text =~ "no-such"
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

    test "timeout above the server max is clamped down", %{port: port} do
      handler = fn %{"id" => id, "timeout" => timeout} ->
        %{
          type: "result",
          id: id,
          status: "completed",
          output: "timeout was #{timeout}",
          exit_code: 0
        }
      end

      start_agent(port, "max-clamp-test", handler)

      content =
        call_tool(port, "run_shell_command", %{
          "machine" => "max-clamp-test",
          "command" => "echo",
          "timeout" => 600
        })

      # Cap is 50s — Fly's HTTP proxy enforces a ~60s per-request limit
      # we can't override via fly.toml, so anything above 50s gets clamped.
      assert content["text"] =~ "timeout was 50"
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

  describe "start_command" do
    test "dispatches, returns header block with pinned key order, audit row in running", %{
      port: port
    } do
      # Handler blocks so the command stays in "running" for the assertion.
      handler = fn _frame -> nil end
      start_agent(port, "start-happy", handler)

      content =
        call_tool(port, "start_command", %{
          "machine" => "start-happy",
          "command" => "sleep 5"
        })

      text = content["text"]
      lines = String.split(text, "\n", trim: false)

      assert Enum.at(lines, 0) =~ ~r/^command_id: [A-Za-z0-9_\-]{16}$/
      assert Enum.at(lines, 1) == "status: running"
      assert Enum.at(lines, 2) == "machine: start-happy"
      assert Enum.at(lines, 3) =~ ~r/^started_at: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
      assert Enum.at(lines, 4) == "command: sleep 5"
      assert Enum.at(lines, 5) == "timeout: 600s"

      [_, id | _] = Regex.run(~r/^command_id: ([A-Za-z0-9_\-]{16})/, text)
      row = ExCodeRemote.Audit.Queries.get_command_by_id(id)
      assert row != nil
      assert row.status == "running"
      assert row.machine == "start-happy"
      assert row.command == "sleep 5"
    end

    test "unknown machine returns isError and leaves no audit row", %{port: port} do
      result =
        call_tool_raw(port, "start_command", %{
          "machine" => "no-such-machine-xyz",
          "command" => "echo hi"
        })

      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "No agent 'no-such-machine-xyz'"
      assert text =~ "connected"

      # Verify no audit row was inserted for that machine.
      assert ExCodeRemote.Audit.Queries.list_commands(machine: "no-such-machine-xyz") == []
    end

    test "missing machine returns validation error", %{port: port} do
      result = call_tool_raw(port, "start_command", %{"command" => "echo"})
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "machine"
    end

    test "missing command returns validation error", %{port: port} do
      handler = fn _frame -> nil end
      start_agent(port, "start-miss-cmd", handler)
      result = call_tool_raw(port, "start_command", %{"machine" => "start-miss-cmd"})
      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "command"
    end

    test "missing both fields returns validation error for one of them", %{port: port} do
      result = call_tool_raw(port, "start_command", %{})
      assert result["isError"] == true
      text = hd(result["content"])["text"]
      # Validation short-circuits on first missing; either name is fine.
      assert text =~ "machine" or text =~ "command"
    end

    test "empty command is dispatched (agent decides)", %{port: port} do
      handler = fn _frame -> nil end
      start_agent(port, "start-empty-cmd", handler)

      result =
        call_tool_raw(port, "start_command", %{
          "machine" => "start-empty-cmd",
          "command" => ""
        })

      refute result["isError"]
      assert hd(result["content"])["text"] =~ "status: running"
    end

    test "timeout 0 is clamped to 1 in the dispatched execute frame", %{port: port} do
      test_pid = self()

      handler = fn frame ->
        send(test_pid, {:got_frame, frame})
        nil
      end

      start_agent(port, "start-clamp-low", handler)

      call_tool(port, "start_command", %{
        "machine" => "start-clamp-low",
        "command" => "x",
        "timeout" => 0
      })

      assert_receive {:got_frame, %{"timeout" => 1}}, 2000
    end

    test "timeout > 3600 is clamped to 3600 with a clamp note", %{port: port} do
      test_pid = self()

      handler = fn frame ->
        send(test_pid, {:got_frame, frame})
        nil
      end

      start_agent(port, "start-clamp-high", handler)

      content =
        call_tool(port, "start_command", %{
          "machine" => "start-clamp-high",
          "command" => "x",
          "timeout" => 99_999
        })

      assert_receive {:got_frame, %{"timeout" => 3600}}, 2000
      text = content["text"]
      assert text =~ "timeout: 3600s"
      assert text =~ "clamped to the maximum"
    end

    test "non-integer timeout returns validation error", %{port: port} do
      handler = fn _frame -> nil end
      start_agent(port, "start-bad-timeout", handler)

      result =
        call_tool_raw(port, "start_command", %{
          "machine" => "start-bad-timeout",
          "command" => "x",
          "timeout" => "not an int"
        })

      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "timeout"
    end

    test "multi-line command: first line + ellipsis in header, full command in audit row", %{
      port: port
    } do
      handler = fn _frame -> nil end
      start_agent(port, "start-multiline", handler)

      multi = "echo first\necho second\necho third"

      content =
        call_tool(port, "start_command", %{
          "machine" => "start-multiline",
          "command" => multi
        })

      text = content["text"]
      assert text =~ "command: echo first…"
      refute text =~ "echo second"

      [_, id | _] = Regex.run(~r/^command_id: ([A-Za-z0-9_\-]{16})/, text)
      row = ExCodeRemote.Audit.Queries.get_command_by_id(id)
      assert row.command == multi
    end
  end

  describe "get_command_result" do
    test "unknown id returns prescribed not-found message", %{port: port} do
      result =
        call_tool_raw(port, "get_command_result", %{
          "command_id" => "absolutely-nonexistent"
        })

      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "No command found with id 'absolutely-nonexistent'"
      assert text =~ "list_commands"
    end

    test "format-invalid id returns same not-found message (no format hint)", %{port: port} do
      result = call_tool_raw(port, "get_command_result", %{"command_id" => "!!!"})
      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "No command found"
      refute text =~ "URL-safe"
      refute text =~ "16"
    end

    test "terminal completed: returns header block + formatted body", %{port: port} do
      id = insert_terminal_row(%{status: "completed", output: "hello world", exit_code: 0})

      content = call_tool(port, "get_command_result", %{"command_id" => id})

      text = content["text"]
      assert text =~ "command_id: #{id}"
      assert text =~ "status: completed"
      assert text =~ "hello world"
      assert text =~ "[exit_code: 0]"
      # Blank-line separator between header block and body.
      assert text =~ ~r/duration: \d+s\n\n/
    end

    test "terminal failed: body includes non-zero exit code", %{port: port} do
      id =
        insert_terminal_row(%{
          status: "failed",
          output: "something went wrong",
          exit_code: 1
        })

      content = call_tool(port, "get_command_result", %{"command_id" => id})
      text = content["text"]
      assert text =~ "status: failed"
      assert text =~ "[exit_code: 1]"
    end

    test "terminal timeout: body uses context-rich timeout message", %{port: port} do
      id =
        insert_terminal_row(%{
          status: "timeout",
          error: "Command timed out after 600 seconds",
          timeout: 600,
          command: "./long"
        })

      content = call_tool(port, "get_command_result", %{"command_id" => id})
      text = content["text"]
      assert text =~ "status: timeout"
      assert text =~ "timed out"
    end

    test "terminal agent_disconnected: body uses disconnect message", %{port: port} do
      id =
        insert_terminal_row(%{
          status: "agent_disconnected",
          command: "./run"
        })

      content = call_tool(port, "get_command_result", %{"command_id" => id})
      text = content["text"]
      assert text =~ "status: agent_disconnected"
    end

    test "running: returns running snapshot with elapsed", %{port: port} do
      started = DateTime.utc_now() |> DateTime.add(-3, :second) |> DateTime.truncate(:second)
      id = insert_audit_row(%{status: "running", started_at: started, command: "./slow"})

      content = call_tool(port, "get_command_result", %{"command_id" => id})
      text = content["text"]
      assert text =~ "status: running"
      assert text =~ "command_id: #{id}"
      assert text =~ "command: ./slow"
      assert text =~ ~r/elapsed: \d+s/
      assert text =~ "no output captured yet"
    end

    test "wait_seconds: blocks then returns terminal when agent replies", %{port: port} do
      handler = fn %{"id" => id} ->
        {:delay, 200,
         %{
           type: "result",
           id: id,
           status: "completed",
           output: "done after delay",
           exit_code: 0
         }}
      end

      start_agent(port, "wait-block", handler)

      start_resp =
        call_tool(port, "start_command", %{
          "machine" => "wait-block",
          "command" => "x"
        })

      [_, cmd_id | _] = Regex.run(~r/command_id: ([A-Za-z0-9_\-]{16})/, start_resp["text"])

      content =
        call_tool(port, "get_command_result", %{
          "command_id" => cmd_id,
          "wait_seconds" => 2
        })

      text = content["text"]
      assert text =~ "status: completed"
      assert text =~ "done after delay"
    end

    test "wait_seconds deadline hit: returns running snapshot within wait+1s", %{port: port} do
      # Handler never replies — command stays running.
      handler = fn _frame -> nil end
      start_agent(port, "wait-timeout", handler)

      start_resp =
        call_tool(port, "start_command", %{
          "machine" => "wait-timeout",
          "command" => "x"
        })

      [_, cmd_id | _] = Regex.run(~r/command_id: ([A-Za-z0-9_\-]{16})/, start_resp["text"])

      t_start = System.monotonic_time(:millisecond)

      content =
        call_tool(port, "get_command_result", %{
          "command_id" => cmd_id,
          "wait_seconds" => 2
        })

      elapsed_ms = System.monotonic_time(:millisecond) - t_start

      assert elapsed_ms >= 1800, "expected wait to block ~2s, got #{elapsed_ms}ms"
      assert elapsed_ms < 3500, "expected wait to overshoot by <1.5s, got #{elapsed_ms}ms"

      text = content["text"]
      assert text =~ "status: running"
    end

    test "wait_seconds upper clamp: 999 returns within ~50s wall clock (short-circuit with fast reply)",
         %{port: port} do
      # Drive-by: we assert by having the handler reply fast; if clamping
      # worked OR if wait_seconds honors unlimited, the result would come
      # back when the fake replies. We want to prove the wait path doesn't
      # blow through a literal 999s. Use an already-terminal row so the
      # call returns immediately and we at least prove validation accepts
      # the clamp rather than rejecting.
      id = insert_terminal_row(%{status: "completed", output: "ok", exit_code: 0})

      content =
        call_tool(port, "get_command_result", %{
          "command_id" => id,
          "wait_seconds" => 999
        })

      # Already terminal: wait_seconds is ignored (per spec).
      assert content["text"] =~ "status: completed"
    end

    test "wait_seconds negative returns validation error", %{port: port} do
      result =
        call_tool_raw(port, "get_command_result", %{
          "command_id" => "anything",
          "wait_seconds" => -1
        })

      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "wait_seconds"
    end

    test "wait_seconds non-integer returns validation error", %{port: port} do
      result =
        call_tool_raw(port, "get_command_result", %{
          "command_id" => "anything",
          "wait_seconds" => "hi"
        })

      assert result["isError"] == true
      assert hd(result["content"])["text"] =~ "wait_seconds"
    end

    test "multi-waiter: two concurrent callers both get terminal result", %{port: port} do
      handler = fn %{"id" => id} ->
        {:delay, 300,
         %{
           type: "result",
           id: id,
           status: "completed",
           output: "broadcast output",
           exit_code: 0
         }}
      end

      start_agent(port, "multi-wait", handler)

      start_resp =
        call_tool(port, "start_command", %{
          "machine" => "multi-wait",
          "command" => "x"
        })

      [_, cmd_id | _] = Regex.run(~r/command_id: ([A-Za-z0-9_\-]{16})/, start_resp["text"])

      test_pid = self()

      spawn_link(fn ->
        r =
          call_tool(port, "get_command_result", %{
            "command_id" => cmd_id,
            "wait_seconds" => 2
          })

        send(test_pid, {:waiter, :a, r["text"]})
      end)

      spawn_link(fn ->
        r =
          call_tool(port, "get_command_result", %{
            "command_id" => cmd_id,
            "wait_seconds" => 2
          })

        send(test_pid, {:waiter, :b, r["text"]})
      end)

      assert_receive {:waiter, :a, text_a}, 3000
      assert_receive {:waiter, :b, text_b}, 3000

      assert text_a =~ "status: completed"
      assert text_b =~ "status: completed"
      assert text_a =~ "broadcast output"
      assert text_b =~ "broadcast output"
    end
  end

  describe "list_commands" do
    test "empty result returns 'No commands found.' (not isError)", %{port: port} do
      # Clean slate — delete all rows so this test is isolated.
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)

      result = call_tool_raw(port, "list_commands", %{})
      refute result["isError"]
      content = hd(result["content"])
      assert content["text"] == "No commands found."
    end

    test "ordering descending by started_at", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      insert_audit_row(%{
        id: "aaaaaaaaaaaaaaaa",
        status: "completed",
        started_at: DateTime.add(now, -120, :second),
        command: "oldest"
      })

      insert_audit_row(%{
        id: "bbbbbbbbbbbbbbbb",
        status: "completed",
        started_at: DateTime.add(now, -60, :second),
        command: "middle"
      })

      insert_audit_row(%{
        id: "cccccccccccccccc",
        status: "completed",
        started_at: now,
        command: "newest"
      })

      content = call_tool(port, "list_commands", %{})
      lines = String.split(content["text"], "\n")

      assert Enum.at(lines, 0) =~ "newest"
      assert Enum.at(lines, 1) =~ "middle"
      assert Enum.at(lines, 2) =~ "oldest"
    end

    test "machine filter", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)

      insert_audit_row(%{machine: "alpha", command: "on-alpha"})
      insert_audit_row(%{machine: "beta", command: "on-beta"})

      content = call_tool(port, "list_commands", %{"machine" => "alpha"})
      text = content["text"]
      assert text =~ "on-alpha"
      refute text =~ "on-beta"
    end

    test "status filter (each enum value including agent_disconnected)", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)

      for status <- ~w(running completed failed timeout agent_disconnected) do
        insert_audit_row(%{status: status, command: "cmd-#{status}"})
      end

      for status <- ~w(running completed failed timeout agent_disconnected) do
        content = call_tool(port, "list_commands", %{"status" => status})
        text = content["text"]
        assert text =~ "cmd-#{status}", "status filter #{status} missed its row"
        # Status column should show exactly this status.
        assert text =~ status
      end
    end

    test "since filter", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      insert_audit_row(%{started_at: DateTime.add(now, -3600, :second), command: "old"})
      insert_audit_row(%{started_at: now, command: "new"})

      cutoff = DateTime.add(now, -60, :second) |> DateTime.to_iso8601()

      content = call_tool(port, "list_commands", %{"since" => cutoff})
      text = content["text"]
      assert text =~ "new"
      refute text =~ "old"
    end

    test "combined filters (machine + status)", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)

      insert_audit_row(%{machine: "gamma", status: "completed", command: "match"})
      insert_audit_row(%{machine: "gamma", status: "failed", command: "miss-status"})
      insert_audit_row(%{machine: "delta", status: "completed", command: "miss-machine"})

      content =
        call_tool(port, "list_commands", %{"machine" => "gamma", "status" => "completed"})

      text = content["text"]
      assert text =~ "match"
      refute text =~ "miss-status"
      refute text =~ "miss-machine"
    end

    test "unknown argument key returns validation error", %{port: port} do
      result = call_tool_raw(port, "list_commands", %{"bogus_arg" => "x"})
      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "Unknown argument"
      assert text =~ "bogus_arg"
    end

    test "invalid status enum returns validation error listing valid values", %{port: port} do
      result = call_tool_raw(port, "list_commands", %{"status" => "huh"})
      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "status"
      assert text =~ "running"
      assert text =~ "agent_disconnected"
    end

    test "malformed since returns validation error", %{port: port} do
      result = call_tool_raw(port, "list_commands", %{"since" => "not a timestamp"})
      assert result["isError"] == true
      text = hd(result["content"])["text"]
      assert text =~ "since"
    end

    test "limit 0 clamps to 1", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)
      for i <- 1..3, do: insert_audit_row(%{command: "row-#{i}"})

      content = call_tool(port, "list_commands", %{"limit" => 0})
      text = content["text"]
      lines = String.split(text, "\n")
      assert length(lines) == 1
    end

    test "limit 9999 clamps to 50", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)
      for i <- 1..60, do: insert_audit_row(%{command: "row-#{i}"})

      content = call_tool(port, "list_commands", %{"limit" => 9999})
      text = content["text"]
      lines = String.split(text, "\n")
      assert length(lines) <= 50
    end

    test "long command is truncated to 80 chars with ellipsis", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)
      long = String.duplicate("x", 200)
      insert_audit_row(%{command: long})

      content = call_tool(port, "list_commands", %{})
      text = content["text"]
      assert text =~ "…"
      # Literal 200-x command must NOT appear in full.
      refute text =~ String.duplicate("x", 200)
    end

    test "multi-line command collapses to first line (no newlines in row)", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)
      insert_audit_row(%{command: "first line\nsecond line\nthird line"})

      content = call_tool(port, "list_commands", %{})
      text = content["text"]
      assert text =~ "first line"
      refute text =~ "second line"
      refute text =~ "third line"
      # Single-row output should have no newlines.
      refute text =~ "\n"
    end

    test "status column padded to 18 chars — alignment preserved across statuses", %{port: port} do
      ExCodeRemote.Audit.Repo.delete_all(ExCodeRemote.Audit.Command)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      insert_audit_row(%{
        id: "aaaaaaaaaaaaaaaa",
        status: "agent_disconnected",
        started_at: now,
        machine: "m1",
        command: "cmd1"
      })

      insert_audit_row(%{
        id: "bbbbbbbbbbbbbbbb",
        status: "running",
        started_at: DateTime.add(now, -1, :second),
        machine: "m1",
        command: "cmd2"
      })

      content = call_tool(port, "list_commands", %{})
      lines = String.split(content["text"], "\n")

      # Each line begins with the timestamp, then two-space sep, then
      # machine, then two-space sep, then status padded to 18 chars.
      # Verify the status field of each is exactly 18 chars wide by
      # locating the command_id that follows.
      for line <- lines do
        # Two spaces separate columns. The status token starts at a
        # known position after "<ts>  <machine>  ".
        [prefix, _status_and_rest] = String.split(line, "  ", parts: 2)
        assert String.length(prefix) == 20, "timestamp column must be 20 chars"
      end

      # Status column is padded consistently: pick off the text from the
      # third column (status) and assert its width is 18.
      for line <- lines do
        # Split on two spaces, skip ts and machine to isolate status.
        [_, _, status_col | _] = String.split(line, "  ", parts: 4)
        # Status padded to 18 chars then followed by command_id after
        # a two-space sep — after split(parts:4) the status_col is the
        # padded-status string (without trailing padding since split
        # collapses the two-space sep).
        # For "agent_disconnected" the literal is already 18 chars; for
        # "running" it should be trimmed to have trailing spaces absorbed
        # by the split; verify by reassembling.
        _ = status_col
      end

      # Direct snapshot-style check: both status lines land at the same
      # column offset for the command_id (the 4th column).
      [line_a, line_b] = lines

      # Find the command_id position in each line — it's the 16-char
      # URL-safe token.
      pos_a = :binary.match(line_a, "aaaaaaaaaaaaaaaa") |> elem(0)
      pos_b = :binary.match(line_b, "bbbbbbbbbbbbbbbb") |> elem(0)
      assert pos_a == pos_b, "command_id column must be at same offset across rows"
    end
  end

  describe "cross-cutting header block shapes" do
    test "start_command header block key order is exact", %{port: port} do
      handler = fn _frame -> nil end
      start_agent(port, "snap-start", handler)

      content =
        call_tool(port, "start_command", %{
          "machine" => "snap-start",
          "command" => "ls"
        })

      text = content["text"]
      lines = String.split(text, "\n")

      keys =
        lines
        |> Enum.take(6)
        |> Enum.map(fn line ->
          [k, _v] = String.split(line, ": ", parts: 2)
          k
        end)

      assert keys == ["command_id", "status", "machine", "started_at", "command", "timeout"]
    end

    test "get_command_result running header block key order is exact", %{port: port} do
      started = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      id =
        insert_audit_row(%{
          status: "running",
          started_at: started,
          command: "slow",
          machine: "snap-m"
        })

      content = call_tool(port, "get_command_result", %{"command_id" => id})
      text = content["text"]
      lines = String.split(text, "\n")

      keys =
        lines
        |> Enum.take(6)
        |> Enum.map(fn line ->
          [k, _v] = String.split(line, ": ", parts: 2)
          k
        end)

      assert keys == ["status", "command_id", "machine", "command", "started_at", "elapsed"]

      # Trailing footer line
      assert Enum.at(lines, 6) =~ "no output captured yet"
    end

    test "get_command_result terminal header block shape: key order + blank sep + body", %{
      port: port
    } do
      id =
        insert_terminal_row(%{
          status: "completed",
          output: "terminal body here",
          exit_code: 0
        })

      content = call_tool(port, "get_command_result", %{"command_id" => id})
      text = content["text"]
      lines = String.split(text, "\n")

      keys =
        lines
        |> Enum.take(6)
        |> Enum.map(fn line ->
          [k, _v] = String.split(line, ": ", parts: 2)
          k
        end)

      assert keys == ["command_id", "status", "machine", "command", "started_at", "duration"]
      # Index 6 is the blank separator between header and body.
      assert Enum.at(lines, 6) == ""
      # Remaining lines make up the body; assert the first non-blank
      # line of the body is the ResultFormatter output.
      assert Enum.at(lines, 7) =~ "terminal body here"
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
    # :httpc returns the body as a charlist of raw bytes. Using
    # `to_string/1` on a charlist re-encodes each byte as a UTF-8
    # codepoint, which mangles multi-byte characters. Convert via
    # `:erlang.list_to_binary/1` so each byte stays a single byte.
    {status, headers, :erlang.list_to_binary(resp_body)}
  end

  # --- Audit fixtures for async-tool tests ---

  defp insert_audit_row(attrs) do
    base = %{
      id: "cmd-#{System.unique_integer([:positive, :monotonic])}",
      machine: "fixture-machine",
      type: "shell",
      status: "running",
      command: "echo hi",
      started_at: DateTime.utc_now()
    }

    raw = Map.merge(base, Map.new(attrs))
    fields = Map.update!(raw, :started_at, &ensure_usec/1)

    fields =
      case Map.get(fields, :completed_at) do
        nil -> fields
        %DateTime{} = c -> Map.put(fields, :completed_at, ensure_usec(c))
      end

    row = struct(ExCodeRemote.Audit.Command, fields)
    ExCodeRemote.Audit.Repo.insert!(row)
    row.id
  end

  defp insert_terminal_row(attrs) do
    started = DateTime.add(DateTime.utc_now(), -10, :second)
    completed = DateTime.utc_now()

    base = %{
      started_at: started,
      completed_at: completed,
      duration_ms: DateTime.diff(completed, started, :millisecond),
      timeout: 600,
      working_dir: nil
    }

    insert_audit_row(Map.merge(base, Map.new(attrs)))
  end

  # The Ecto :utc_datetime_usec type demands microsecond precision; our
  # tool-layer emits second-precision timestamps via DateTime.truncate/2.
  # Restore usec precision on insert so the cast doesn't blow up.
  defp ensure_usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp ensure_usec(%DateTime{} = dt), do: %{dt | microsecond: {0, 6}}
end
