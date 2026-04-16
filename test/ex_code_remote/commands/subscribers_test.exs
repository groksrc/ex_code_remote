defmodule ExCodeRemote.Commands.SubscribersTest do
  use ExUnit.Case, async: true

  alias ExCodeRemote.Commands.Subscribers

  setup do
    # The Subscribers Registry is normally started by the application
    # supervisor (Unit 2 added it to the tree). Before Unit 1 landed,
    # the app couldn't boot, so this test bootstrapped its own
    # registry. Now that Unit 1 is in place, the registry is already
    # running — only start one if the supervisor hasn't.
    case Process.whereis(ExCodeRemote.Commands.Subscribers) do
      nil ->
        start_supervised!({Registry, keys: :duplicate, name: ExCodeRemote.Commands.Subscribers})

      _pid ->
        :ok
    end

    :ok
  end

  defp unique_command_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  describe "subscribe/1 + broadcast/1" do
    test "single subscriber receives {:command_done, command_id}" do
      command_id = unique_command_id()

      assert :ok = Subscribers.subscribe(command_id)
      assert :ok = Subscribers.broadcast(command_id)

      assert_receive {:command_done, ^command_id}, 500
    end

    test "broadcast with no subscribers does not raise" do
      command_id = unique_command_id()

      assert :ok = Subscribers.broadcast(command_id)

      # Confirm no message was delivered to the calling process either.
      refute_receive {:command_done, ^command_id}, 50
    end

    test "broadcast for one id does not notify subscribers of a different id" do
      mine = unique_command_id()
      other = unique_command_id()

      assert :ok = Subscribers.subscribe(mine)
      assert :ok = Subscribers.broadcast(other)

      refute_receive {:command_done, ^other}, 50
      refute_receive {:command_done, ^mine}, 50
    end

    test "multi-waiter: two subscribers on the same id both receive the message" do
      command_id = unique_command_id()
      parent = self()

      task1 =
        Task.async(fn ->
          Subscribers.subscribe(command_id)
          send(parent, {:ready, 1})

          receive do
            {:command_done, ^command_id} -> :got_it
          after
            1_000 -> :timeout
          end
        end)

      task2 =
        Task.async(fn ->
          Subscribers.subscribe(command_id)
          send(parent, {:ready, 2})

          receive do
            {:command_done, ^command_id} -> :got_it
          after
            1_000 -> :timeout
          end
        end)

      assert_receive {:ready, 1}, 500
      assert_receive {:ready, 2}, 500

      assert :ok = Subscribers.broadcast(command_id)

      assert :got_it = Task.await(task1, 2_000)
      assert :got_it = Task.await(task2, 2_000)
    end

    test "subscriber exit cleans up registry entries; subsequent broadcast is a no-op" do
      command_id = unique_command_id()
      parent = self()

      {:ok, subscriber} =
        Task.start(fn ->
          Subscribers.subscribe(command_id)
          send(parent, :subscribed)

          receive do
            :exit -> :ok
          end
        end)

      ref = Process.monitor(subscriber)
      assert_receive :subscribed, 500

      # Sanity-check: there is exactly one registered entry before exit.
      assert [{^subscriber, nil}] =
               Registry.lookup(ExCodeRemote.Commands.Subscribers, command_id)

      send(subscriber, :exit)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _reason}, 500

      # Registry cleanup is async-after-DOWN; give it a moment to settle.
      wait_until(fn ->
        Registry.lookup(ExCodeRemote.Commands.Subscribers, command_id) == []
      end)

      assert [] = Registry.lookup(ExCodeRemote.Commands.Subscribers, command_id)

      # No subscribers means broadcast is a no-op (and definitely doesn't
      # try to send to the dead pid).
      assert :ok = Subscribers.broadcast(command_id)
      refute_receive {:command_done, ^command_id}, 50
    end
  end

  defp wait_until(fun, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(10)
        do_wait_until(fun, deadline)
      end
    end
  end
end
