defmodule SofiTrader.Tradier.Client do
  @moduledoc """
  Base HTTP client for Tradier API.

  Handles authentication, request building, and response parsing for all Tradier API calls.
  """

  @doc """
  Makes a GET request to the Tradier API.
  """
  def get(path, params \\ [], opts \\ []) do
    request(:get, path, params, opts)
  end

  @doc """
  Makes a POST request to the Tradier API.
  """
  def post(path, body \\ %{}, opts \\ []) do
    request(:post, path, body, opts)
  end

  @doc """
  Makes a PUT request to the Tradier API.
  """
  def put(path, body \\ %{}, opts \\ []) do
    request(:put, path, body, opts)
  end

  @doc """
  Makes a DELETE request to the Tradier API.
  """
  def delete(path, opts \\ []) do
    request(:delete, path, [], opts)
  end

  defp request(method, path, params_or_body, opts) do
    url = build_url(path)
    headers = build_headers(opts)

    result = case method do
      :get ->
        Req.request(
          method: method,
          url: url,
          params: params_or_body,
          headers: headers
        )

      :post ->
        Req.request(
          method: method,
          url: url,
          form: params_or_body,
          headers: headers
        )

      :put ->
        Req.request(
          method: method,
          url: url,
          form: params_or_body,
          headers: headers
        )

      :delete ->
        Req.request(
          method: method,
          url: url,
          headers: headers
        )
    end

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_url(path) do
    base_url = get_base_url()
    "#{base_url}#{path}"
  end

  defp get_base_url do
    config = Application.get_env(:sofi_trader, :tradier)
    sandbox = Keyword.get(config, :sandbox, true)

    if sandbox do
      Keyword.get(config, :sandbox_url)
    else
      Keyword.get(config, :base_url)
    end
  end

  defp build_headers(opts) do
    token = get_access_token(opts)

    [
      {"Accept", "application/json"},
      {"Authorization", "Bearer #{token}"}
    ]
  end

  defp get_access_token(opts) do
    case Keyword.get(opts, :token) do
      nil ->
        # Try to get from environment variable
        System.get_env("TRADIER_ACCESS_TOKEN") ||
          raise "Tradier access token not configured"

      token ->
        token
    end
  end
end
