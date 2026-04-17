defmodule ExCodeRemote.OAuthTest do
  use ExUnit.Case, async: false

  @client_id "test-client-id"
  @client_secret "test-client-secret"

  setup do
    # Enable OAuth for these tests
    old_id = Application.get_env(:ex_code_remote, :mcp_client_id)
    old_secret = Application.get_env(:ex_code_remote, :mcp_client_secret)

    Application.put_env(:ex_code_remote, :mcp_client_id, @client_id)
    Application.put_env(:ex_code_remote, :mcp_client_secret, @client_secret)

    on_exit(fn ->
      if old_id, do: Application.put_env(:ex_code_remote, :mcp_client_id, old_id),
        else: Application.delete_env(:ex_code_remote, :mcp_client_id)
      if old_secret, do: Application.put_env(:ex_code_remote, :mcp_client_secret, old_secret),
        else: Application.delete_env(:ex_code_remote, :mcp_client_secret)
    end)

    ExCodeRemote.Test.Helpers.setup_server()
  end

  describe "discovery" do
    test "returns OAuth metadata", %{port: port} do
      {:ok, resp} =
        :httpc.request(:get, {~c"http://localhost:#{port}/.well-known/oauth-authorization-server", []}, [], [])

      {{_, 200, _}, _headers, body} = resp
      meta = Jason.decode!(body)

      assert meta["authorization_endpoint"] =~ "/oauth/authorize"
      assert meta["token_endpoint"] =~ "/oauth/token"
      assert "code" in meta["response_types_supported"]
      assert "S256" in meta["code_challenge_methods_supported"]
    end
  end

  describe "authorize" do
    test "redirects with code for valid client", %{port: port} do
      url = ~c"http://localhost:#{port}/oauth/authorize?client_id=#{@client_id}&redirect_uri=http://localhost/callback&state=xyz"

      {:ok, resp} =
        :httpc.request(:get, {url, []}, [{:autoredirect, false}], [])

      {{_, 302, _}, headers, _body} = resp
      location = :proplists.get_value(~c"location", headers) |> to_string()

      uri = URI.parse(location)
      params = URI.decode_query(uri.query)

      assert params["code"]
      assert params["state"] == "xyz"
    end

    test "rejects unknown client_id", %{port: port} do
      url = ~c"http://localhost:#{port}/oauth/authorize?client_id=wrong&redirect_uri=http://localhost/callback"

      {:ok, resp} =
        :httpc.request(:get, {url, []}, [{:autoredirect, false}], [])

      {{_, 403, _}, _headers, _body} = resp
    end
  end

  describe "token exchange" do
    test "exchanges code for access token", %{port: port} do
      # First get an auth code
      code = get_auth_code(port)

      # Exchange it
      body = URI.encode_query(%{
        grant_type: "authorization_code",
        code: code,
        client_id: @client_id,
        client_secret: @client_secret
      })

      {:ok, resp} =
        :httpc.request(:post, {
          ~c"http://localhost:#{port}/oauth/token",
          [{~c"content-type", ~c"application/x-www-form-urlencoded"}],
          ~c"application/x-www-form-urlencoded",
          String.to_charlist(body)
        }, [], [])

      {{_, 200, _}, _headers, resp_body} = resp
      token_data = Jason.decode!(resp_body)

      assert token_data["access_token"]
      assert token_data["token_type"] == "Bearer"
      assert token_data["refresh_token"]
    end

    test "rejects invalid client_secret", %{port: port} do
      code = get_auth_code(port)

      body = URI.encode_query(%{
        grant_type: "authorization_code",
        code: code,
        client_id: @client_id,
        client_secret: "wrong"
      })

      {:ok, resp} =
        :httpc.request(:post, {
          ~c"http://localhost:#{port}/oauth/token",
          [{~c"content-type", ~c"application/x-www-form-urlencoded"}],
          ~c"application/x-www-form-urlencoded",
          String.to_charlist(body)
        }, [], [])

      {{_, 400, _}, _headers, _body} = resp
    end
  end

  describe "MCP auth enforcement" do
    test "MCP POST requires Bearer token when OAuth is enabled", %{port: port} do
      body = Jason.encode!(%{jsonrpc: "2.0", method: "ping", id: 1})

      {:ok, resp} =
        :httpc.request(:post, {
          ~c"http://localhost:#{port}/mcp",
          [{~c"content-type", ~c"application/json"}],
          ~c"application/json",
          String.to_charlist(body)
        }, [], [])

      {{_, 401, _}, _headers, _body} = resp
    end

    test "MCP POST succeeds with valid Bearer token", %{port: port} do
      token = get_access_token(port)
      body = Jason.encode!(%{jsonrpc: "2.0", method: "ping", id: 1})

      {:ok, resp} =
        :httpc.request(:post, {
          ~c"http://localhost:#{port}/mcp",
          [
            {~c"content-type", ~c"application/json"},
            {~c"authorization", String.to_charlist("Bearer #{token}")}
          ],
          ~c"application/json",
          String.to_charlist(body)
        }, [], [])

      {{_, 200, _}, _headers, resp_body} = resp
      assert %{"result" => %{}} = Jason.decode!(resp_body)
    end

    test "MCP POST rejects invalid Bearer token", %{port: port} do
      body = Jason.encode!(%{jsonrpc: "2.0", method: "ping", id: 1})

      {:ok, resp} =
        :httpc.request(:post, {
          ~c"http://localhost:#{port}/mcp",
          [
            {~c"content-type", ~c"application/json"},
            {~c"authorization", ~c"Bearer garbage"}
          ],
          ~c"application/json",
          String.to_charlist(body)
        }, [], [])

      {{_, 401, _}, _headers, _body} = resp
    end
  end

  describe "refresh token" do
    test "refresh token returns new access token", %{port: port} do
      # Get initial tokens
      code = get_auth_code(port)

      body = URI.encode_query(%{
        grant_type: "authorization_code",
        code: code,
        client_id: @client_id,
        client_secret: @client_secret
      })

      {:ok, resp} =
        :httpc.request(:post, {
          ~c"http://localhost:#{port}/oauth/token",
          [{~c"content-type", ~c"application/x-www-form-urlencoded"}],
          ~c"application/x-www-form-urlencoded",
          String.to_charlist(body)
        }, [], [])

      {{_, 200, _}, _headers, resp_body} = resp
      %{"refresh_token" => refresh} = Jason.decode!(resp_body)

      # Use refresh token
      refresh_body = URI.encode_query(%{
        grant_type: "refresh_token",
        refresh_token: refresh,
        client_id: @client_id,
        client_secret: @client_secret
      })

      {:ok, resp2} =
        :httpc.request(:post, {
          ~c"http://localhost:#{port}/oauth/token",
          [{~c"content-type", ~c"application/x-www-form-urlencoded"}],
          ~c"application/x-www-form-urlencoded",
          String.to_charlist(refresh_body)
        }, [], [])

      {{_, 200, _}, _headers, resp2_body} = resp2
      token_data = Jason.decode!(resp2_body)

      assert token_data["access_token"]
      assert token_data["refresh_token"]
    end
  end

  # --- Helpers ---

  defp get_auth_code(port) do
    url = ~c"http://localhost:#{port}/oauth/authorize?client_id=#{@client_id}&redirect_uri=http://localhost/callback"

    {:ok, resp} =
      :httpc.request(:get, {url, []}, [{:autoredirect, false}], [])

    {{_, 302, _}, headers, _body} = resp
    location = :proplists.get_value(~c"location", headers) |> to_string()
    URI.decode_query(URI.parse(location).query)["code"]
  end

  defp get_access_token(port) do
    code = get_auth_code(port)

    body = URI.encode_query(%{
      grant_type: "authorization_code",
      code: code,
      client_id: @client_id,
      client_secret: @client_secret
    })

    {:ok, resp} =
      :httpc.request(:post, {
        ~c"http://localhost:#{port}/oauth/token",
        [{~c"content-type", ~c"application/x-www-form-urlencoded"}],
        ~c"application/x-www-form-urlencoded",
        String.to_charlist(body)
      }, [], [])

    {{_, 200, _}, _headers, resp_body} = resp
    Jason.decode!(resp_body)["access_token"]
  end
end
