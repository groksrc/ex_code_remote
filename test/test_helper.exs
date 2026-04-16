# Set AUTH_TOKEN for test environment
Application.put_env(:ex_code_remote, :auth_token, "test-token-for-testing")

ExUnit.start()
