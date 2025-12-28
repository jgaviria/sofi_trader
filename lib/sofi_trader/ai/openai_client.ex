defmodule SofiTrader.AI.OpenAIClient do
  @moduledoc """
  Client for OpenAI's ChatGPT API.

  Used for analyzing sports markets and identifying underpriced bets.

  ## Configuration

  Set the `OPENAI_API_KEY` environment variable with your API key.

  ## Usage

      {:ok, response} = OpenAIClient.chat("What is 2+2?")
      {:ok, response} = OpenAIClient.chat(messages, model: "gpt-4o")
      {:ok, response} = OpenAIClient.chat(prompt, model: "o1-preview")  # Best reasoning
  """

  require Logger

  @base_url "https://api.openai.com/v1"
  @default_model "gpt-4o-mini"
  @default_timeout 120_000  # 2 minutes for o1 models which can take longer

  # o-series reasoning models require different API parameters
  @o1_models ["o1-preview", "o1-mini", "o1", "o3", "o3-mini", "o4-mini"]

  @doc """
  Send a chat completion request to OpenAI.

  ## Options
    - `:model` - Model to use (default: "gpt-4o-mini")
      - "gpt-4o" / "gpt-4o-mini" - Standard models
      - "o1-preview" / "o1-mini" - Reasoning models (best for complex analysis)
    - `:temperature` - Sampling temperature 0-2 (default: 0.7, ignored for o1)
    - `:max_tokens` - Max tokens in response (default: 1000)
    - `:system` - System message to set context (merged into user message for o1)

  ## Examples

      # Simple string prompt
      {:ok, response} = OpenAIClient.chat("Analyze this market...")

      # With system message (works for all models)
      {:ok, response} = OpenAIClient.chat("Is this underpriced?",
        system: "You are a sports betting analyst.",
        model: "o1-preview"
      )
  """
  def chat(prompt_or_messages, opts \\ [])

  def chat(prompt, opts) when is_binary(prompt) do
    system = Keyword.get(opts, :system, "You are a helpful assistant.")
    model = Keyword.get(opts, :model, @default_model)

    # o1 models don't support system messages - merge into user message
    messages = if is_o1_model?(model) do
      [%{role: "user", content: "#{system}\n\n---\n\n#{prompt}"}]
    else
      [
        %{role: "system", content: system},
        %{role: "user", content: prompt}
      ]
    end

    chat(messages, Keyword.delete(opts, :system))
  end

  def chat(messages, opts) when is_list(messages) do
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, 1000)

    # Build request body based on model type
    body = if is_o1_model?(model) do
      # o1 models: no temperature, use max_completion_tokens
      %{
        model: model,
        messages: convert_messages_for_o1(messages),
        max_completion_tokens: max_tokens
      }
    else
      # Standard models: include temperature
      temperature = Keyword.get(opts, :temperature, 0.7)
      %{
        model: model,
        messages: messages,
        temperature: temperature,
        max_tokens: max_tokens
      }
    end

    Logger.info("[OpenAI] Calling #{model}...")

    case post("/chat/completions", body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        {:ok, content}

      {:ok, response} ->
        Logger.error("[OpenAI] Unexpected response format: #{inspect(response)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Check if model is an o1 reasoning model
  defp is_o1_model?(model), do: model in @o1_models

  # Convert messages for o1 models (merge system into user)
  defp convert_messages_for_o1(messages) do
    {system_msgs, other_msgs} = Enum.split_with(messages, fn m -> m[:role] == "system" || m["role"] == "system" end)

    system_content = system_msgs
    |> Enum.map(fn m -> m[:content] || m["content"] end)
    |> Enum.join("\n\n")

    if system_content != "" do
      # Prepend system content to first user message
      case other_msgs do
        [first | rest] ->
          user_content = first[:content] || first["content"]
          [%{role: "user", content: "#{system_content}\n\n---\n\n#{user_content}"} | rest]
        [] ->
          [%{role: "user", content: system_content}]
      end
    else
      other_msgs
    end
  end

  @doc """
  Check if the OpenAI API is configured.
  """
  def configured? do
    get_api_key() != nil
  end

  @doc """
  Get the configured API key (or nil if not set).
  """
  def get_api_key do
    System.get_env("OPENAI_API_KEY")
  end

  # Private functions

  defp post(path, body) do
    url = @base_url <> path
    headers = build_headers()
    json_body = Jason.encode!(body)

    Logger.debug("[OpenAI] POST #{path}")

    case Req.post(url, body: json_body, headers: headers, receive_timeout: @default_timeout) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: 401}} ->
        Logger.error("[OpenAI] Invalid API key")
        {:error, :invalid_api_key}

      {:ok, %{status: 429, body: body}} ->
        Logger.warning("[OpenAI] Rate limited: #{inspect(body)}")
        {:error, :rate_limited}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[OpenAI] API error #{status}: #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("[OpenAI] Request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp build_headers do
    api_key = get_api_key()

    if api_key do
      [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"}
      ]
    else
      raise "OpenAI API key not configured. Set the OPENAI_API_KEY environment variable."
    end
  end
end
