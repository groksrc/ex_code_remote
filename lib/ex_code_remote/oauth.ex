defmodule ExCodeRemote.OAuth do
  @moduledoc """
  Minimal OAuth 2.1 Authorization Code + PKCE implementation for MCP auth.

  Claude.ai's custom connector sends a client_id and client_secret, then
  follows the standard OAuth 2.1 flow:

  1. Discovers endpoints via `/.well-known/oauth-authorization-server`
  2. Redirects user to `/oauth/authorize` (we auto-approve — single user)
  3. Exchanges the auth code at `/oauth/token` for a bearer token
  4. Sends `Authorization: Bearer <token>` on every MCP request

  Tokens are signed with `Plug.Crypto` using AUTH_TOKEN as the secret.
  No database or session store needed — the token is self-validating.
  """

  import Plug.Conn
  require Logger

  @code_ttl_seconds 120
  @token_ttl_seconds 86_400

  # --- Configuration ---

  def enabled? do
    client_id() != nil and client_secret() != nil
  end

  def client_id, do: Application.get_env(:ex_code_remote, :mcp_client_id)
  def client_secret, do: Application.get_env(:ex_code_remote, :mcp_client_secret)

  defp signing_secret do
    Application.get_env(:ex_code_remote, :auth_token)
  end

  # --- Discovery ---

  def handle_discovery(conn) do
    # Build the base URL from the request
    scheme = if get_req_header(conn, "x-forwarded-proto") == ["https"], do: "https", else: conn.scheme
    host = conn.host
    base = "#{scheme}://#{host}"

    metadata = %{
      issuer: base,
      authorization_endpoint: "#{base}/oauth/authorize",
      token_endpoint: "#{base}/oauth/token",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["client_secret_post"]
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(metadata))
  end

  # --- Authorization Endpoint ---

  def handle_authorize(conn) do
    conn = fetch_query_params(conn)
    params = conn.query_params

    redirect_uri = params["redirect_uri"]
    state = params["state"]
    cid = params["client_id"]
    code_challenge = params["code_challenge"]

    cond do
      cid != client_id() ->
        send_error(conn, 403, "invalid_client", "Unknown client_id")

      is_nil(redirect_uri) or redirect_uri == "" ->
        send_error(conn, 400, "invalid_request", "redirect_uri is required")

      true ->
        # Single-user server: auto-approve. Generate a signed auth code
        # that embeds the code_challenge so we can verify it at /token.
        code = generate_code(cid, code_challenge)

        location =
          redirect_uri
          |> URI.parse()
          |> then(fn uri ->
            existing = URI.decode_query(uri.query || "")

            query =
              Map.merge(existing, %{"code" => code})
              |> then(fn q -> if state, do: Map.put(q, "state", state), else: q end)
              |> URI.encode_query()

            %{uri | query: query} |> URI.to_string()
          end)

        conn
        |> put_resp_header("location", location)
        |> send_resp(302, "")
    end
  end

  # --- Token Endpoint ---

  def handle_token(conn) do
    # Token endpoint receives form-encoded body
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)

    case params["grant_type"] do
      "authorization_code" -> exchange_code(conn, params)
      "refresh_token" -> refresh_token(conn, params)
      _ -> send_error(conn, 400, "unsupported_grant_type", "Only authorization_code and refresh_token are supported")
    end
  end

  defp exchange_code(conn, params) do
    code = params["code"]
    cid = params["client_id"]
    secret = params["client_secret"]
    code_verifier = params["code_verifier"]

    with :ok <- validate_client(cid, secret),
         {:ok, claims} <- verify_code(code),
         :ok <- verify_pkce(claims, code_verifier) do
      access_token = generate_access_token(cid)
      refresh = generate_refresh_token(cid)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{
        access_token: access_token,
        token_type: "Bearer",
        expires_in: @token_ttl_seconds,
        refresh_token: refresh
      }))
    else
      {:error, reason} ->
        send_error(conn, 400, "invalid_grant", reason)
    end
  end

  defp refresh_token(conn, params) do
    cid = params["client_id"]
    secret = params["client_secret"]
    refresh = params["refresh_token"]

    with :ok <- validate_client(cid, secret),
         {:ok, _claims} <- verify_refresh_token(refresh) do
      access_token = generate_access_token(cid)
      new_refresh = generate_refresh_token(cid)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{
        access_token: access_token,
        token_type: "Bearer",
        expires_in: @token_ttl_seconds,
        refresh_token: new_refresh
      }))
    else
      {:error, reason} ->
        send_error(conn, 400, "invalid_grant", reason)
    end
  end

  # --- Token Validation (used by MCP.Plug) ---

  def verify_bearer_token(token) do
    case Plug.Crypto.verify(signing_secret(), "mcp_access", token, max_age: @token_ttl_seconds) do
      {:ok, _claims} -> :ok
      {:error, _} -> :error
    end
  end

  # --- Internal ---

  defp validate_client(cid, secret) do
    if cid == client_id() and Plug.Crypto.secure_compare(secret || "", client_secret() || "") do
      :ok
    else
      {:error, "invalid client credentials"}
    end
  end

  defp generate_code(cid, code_challenge) do
    Plug.Crypto.sign(signing_secret(), "mcp_code", %{
      client_id: cid,
      code_challenge: code_challenge
    })
  end

  defp verify_code(code) do
    case Plug.Crypto.verify(signing_secret(), "mcp_code", code, max_age: @code_ttl_seconds) do
      {:ok, claims} -> {:ok, claims}
      {:error, _} -> {:error, "invalid or expired authorization code"}
    end
  end

  defp verify_pkce(%{code_challenge: nil}, _verifier), do: :ok
  defp verify_pkce(%{code_challenge: _challenge}, nil), do: {:error, "code_verifier is required"}

  defp verify_pkce(%{code_challenge: challenge}, verifier) do
    computed = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    if Plug.Crypto.secure_compare(computed, challenge) do
      :ok
    else
      {:error, "PKCE verification failed"}
    end
  end

  defp generate_access_token(cid) do
    Plug.Crypto.sign(signing_secret(), "mcp_access", %{client_id: cid})
  end

  defp generate_refresh_token(cid) do
    Plug.Crypto.sign(signing_secret(), "mcp_refresh", %{client_id: cid})
  end

  defp verify_refresh_token(token) do
    # Refresh tokens are long-lived (30 days)
    case Plug.Crypto.verify(signing_secret(), "mcp_refresh", token, max_age: 30 * 86_400) do
      {:ok, claims} -> {:ok, claims}
      {:error, _} -> {:error, "invalid or expired refresh token"}
    end
  end

  defp send_error(conn, status, error, description) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error, error_description: description}))
  end
end
