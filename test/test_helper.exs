# Set AUTH_TOKEN for test environment
Application.put_env(:ex_code_remote, :auth_token, "test-token-for-testing")

# :httpc is used by router/MCP plug tests as an HTTP client. inets is an
# OTP application but isn't auto-started; do it once here.
{:ok, _} = Application.ensure_all_started(:inets)

ExUnit.start()
