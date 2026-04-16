defmodule ExCodeRemote.Plugs.PrivateNetwork do
  @moduledoc """
  Plug that restricts access to Tailscale CGNAT IPs (100.64.0.0/10).

  IP extraction strategy (in priority order):
  1. fly-client-ip header — Fly overwrites this on every request, so it cannot
     be spoofed by clients. This is the preferred source on Fly.
  2. Rightmost IP in x-forwarded-for — the IP appended by Fly's proxy, the only
     hop we trust. Leftmost IPs are client-controlled and ignored.
  3. conn.remote_ip — direct connection fallback for dev/test environments.

  Loopback (127.0.0.1, ::1) is always allowed. In production on Fly, Tailscale
  userspace networking proxies connections through the local daemon, which may
  present the connection as loopback. This is acceptable because the only
  processes on the Fly machine are tailscaled and the Elixir release.

  Fails closed: parse errors, missing IPs, or unrecognized formats result in denial.
  """

  import Plug.Conn
  import Bitwise
  require Logger

  @behaviour Plug

  # Tailscale CGNAT: 100.64.0.0/10 → 100.64.0.0 through 100.127.255.255
  # First 10 bits: 0110_0100 01 (100.64 in binary, masked to 10 bits)
  @tailscale_base {100, 64, 0, 0}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if enforcement_enabled?() do
      case extract_client_ip(conn) do
        {:ok, ip} ->
          if allowed?(ip) do
            conn
          else
            deny(conn, format_ip(ip))
          end

        :error ->
          deny(conn, "unparseable")
      end
    else
      conn
    end
  end

  defp enforcement_enabled? do
    Application.get_env(:ex_code_remote, :require_private_network, false)
  end

  @doc false
  def extract_client_ip(conn) do
    with :skip <- try_fly_client_ip(conn),
         :skip <- try_x_forwarded_for(conn) do
      {:ok, conn.remote_ip}
    end
  end

  defp try_fly_client_ip(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [value] when value != "" ->
        case parse_ip(String.trim(value)) do
          {:ok, ip} -> {:ok, ip}
          :error -> :error
        end

      _ ->
        :skip
    end
  end

  defp try_x_forwarded_for(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [] ->
        :skip

      headers ->
        # Concatenate multiple headers per RFC 7230, take rightmost IP
        all_ips =
          headers
          |> Enum.join(", ")
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        case List.last(all_ips) do
          nil ->
            :skip

          rightmost ->
            case parse_ip(rightmost) do
              {:ok, ip} -> {:ok, ip}
              :error -> :error
            end
        end
    end
  end

  defp parse_ip(str) do
    case :inet.parse_address(String.to_charlist(str)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  @doc """
  Returns true if the IP is in the Tailscale CGNAT range or is loopback.
  """
  def allowed?(ip) do
    loopback?(ip) or tailscale_cgnat?(ip)
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp tailscale_cgnat?({a, b, _, _}) do
    # 100.64.0.0/10: first 10 bits must match
    # Byte 1: 100 (all 8 bits). Byte 2: top 2 bits must be 01 (64..127)
    {base_a, base_b, _, _} = @tailscale_base
    a == base_a and band(b, 0xC0) == band(base_b, 0xC0)
  end

  defp tailscale_cgnat?(_), do: false

  defp deny(conn, ip_string) do
    Logger.warning("Private network denied: ip=#{ip_string} path=#{conn.request_path}")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: "private_network_required"}))
    |> halt()
  end

  defp format_ip(ip) when is_tuple(ip) do
    :inet.ntoa(ip) |> to_string()
  end

  defp format_ip(other), do: inspect(other)
end
