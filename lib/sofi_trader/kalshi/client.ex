defmodule SofiTrader.Kalshi.Client do
  @moduledoc """
  Base HTTP client for Kalshi API with RSA authentication.

  Kalshi uses RSA-based request signing for authentication. Each request must include:
  - KALSHI-ACCESS-KEY: Your API key ID
  - KALSHI-ACCESS-SIGNATURE: RSA signature of the request
  - KALSHI-ACCESS-TIMESTAMP: Unix timestamp in milliseconds

  Environment variables required:
  - KALSHI_API_KEY: Your API key ID
  - KALSHI_PRIVATE_KEY: Your RSA private key (PEM format)
  """

  require Logger

  @doc """
  Makes a GET request to the Kalshi API.
  """
  def get(path, params \\ []) do
    request(:get, path, params)
  end

  @doc """
  Makes a POST request to the Kalshi API.
  """
  def post(path, body \\ %{}) do
    request(:post, path, body)
  end

  @doc """
  Makes a PUT request to the Kalshi API.
  """
  def put(path, body \\ %{}) do
    request(:put, path, body)
  end

  @doc """
  Makes a DELETE request to the Kalshi API.
  """
  def delete(path) do
    request(:delete, path, %{})
  end

  defp request(method, path, params_or_body) do
    url = build_url(path)
    timestamp = System.system_time(:millisecond)

    # Build the body string for signing
    body_string = case method do
      :get -> ""
      _ ->
        if params_or_body == %{} do
          ""
        else
          Jason.encode!(params_or_body)
        end
    end

    # Build headers with signature
    headers = build_headers(method, path, timestamp, body_string)

    result = case method do
      :get ->
        Req.request(
          method: method,
          url: url,
          params: params_or_body,
          headers: headers
        )

      _ ->
        Req.request(
          method: method,
          url: url,
          json: params_or_body,
          headers: headers
        )
    end

    handle_response(result)
  end

  defp handle_response(result) do
    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 401, body: body}} ->
        Logger.error("Kalshi authentication failed: #{inspect(body)}")
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 429, body: body}} ->
        Logger.warning("Kalshi rate limit exceeded: #{inspect(body)}")
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Kalshi API error #{status}: #{inspect(body)}")
        {:error, %{status: status, body: body}}

      {:error, error} ->
        Logger.error("Kalshi request failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp build_url(path) do
    base_url = get_base_url()
    "#{base_url}#{path}"
  end

  defp get_base_url do
    config = Application.get_env(:sofi_trader, :kalshi, [])
    demo = Keyword.get(config, :demo, true)

    if demo do
      Keyword.get(config, :demo_url, "https://demo-api.kalshi.co")
    else
      Keyword.get(config, :base_url, "https://api.elections.kalshi.com")
    end
  end

  defp build_headers(method, path, timestamp, body_string) do
    api_key = get_api_key()
    signature = sign_request(method, path, timestamp, body_string)

    [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {"KALSHI-ACCESS-KEY", api_key},
      {"KALSHI-ACCESS-SIGNATURE", signature},
      {"KALSHI-ACCESS-TIMESTAMP", to_string(timestamp)}
    ]
  end

  @doc """
  Signs a request using RSA-SHA256.

  The signature is computed over the concatenation of:
  - Timestamp (milliseconds)
  - HTTP method (uppercase)
  - Request path
  - Request body (empty string for GET)
  """
  def sign_request(method, path, timestamp, _body_string) do
    private_key = get_private_key()
    method_str = method |> to_string() |> String.upcase()

    # Build the string to sign
    # IMPORTANT: Kalshi only signs timestamp + method + path (no body!)
    # Also strip query params from path
    path_without_query = path |> String.split("?") |> hd()
    string_to_sign = "#{timestamp}#{method_str}#{path_without_query}"

    # Sign with RSA-PSS (SHA256, MGF1-SHA256, salt_length = digest_length)
    # Kalshi requires PSS padding, not PKCS#1 v1.5
    rsa_pss_options = [
      {:rsa_padding, :rsa_pkcs1_pss_padding},
      {:rsa_pss_saltlen, -1},  # -1 = use hash output length (32 for SHA256)
      {:rsa_mgf1_md, :sha256}
    ]

    signature = :public_key.sign(string_to_sign, :sha256, private_key, rsa_pss_options)

    # Base64 encode
    Base.encode64(signature)
  end

  defp get_api_key do
    System.get_env("KALSHI_API_KEY") ||
      raise """
      Kalshi API key not configured.
      Set the KALSHI_API_KEY environment variable with your API key ID.
      """
  end

  defp get_private_key do
    key_string = System.get_env("KALSHI_PRIVATE_KEY") ||
      raise """
      Kalshi private key not configured.
      Set the KALSHI_PRIVATE_KEY environment variable with your RSA private key in PEM format.
      """

    # Handle escaped newlines from environment variable
    # Environment variables often have literal \n instead of actual newlines
    normalized_key = key_string
      |> String.replace("\\n", "\n")
      |> String.trim()

    # Parse the PEM-encoded private key
    case :public_key.pem_decode(normalized_key) do
      [pem_entry] ->
        :public_key.pem_entry_decode(pem_entry)

      [] ->
        raise """
        Failed to parse Kalshi private key.
        Make sure the KALSHI_PRIVATE_KEY environment variable contains a valid PEM-encoded RSA private key.
        The key should start with -----BEGIN RSA PRIVATE KEY----- and end with -----END RSA PRIVATE KEY-----
        """

      entries when is_list(entries) ->
        # Take the first valid entry
        :public_key.pem_entry_decode(hd(entries))
    end
  end

  @doc """
  Test the connection to Kalshi API.
  Returns {:ok, exchange_status} on success.
  """
  def test_connection do
    get("/trade-api/v2/exchange/status")
  end

  @doc """
  Check if the API is configured and credentials are available.
  """
  def configured? do
    api_key = System.get_env("KALSHI_API_KEY")
    private_key = System.get_env("KALSHI_PRIVATE_KEY")

    is_binary(api_key) and byte_size(api_key) > 0 and
    is_binary(private_key) and byte_size(private_key) > 0
  end
end
