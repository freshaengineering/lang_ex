defmodule LangEx.ConfigTest do
  use ExUnit.Case, async: false

  alias LangEx.Config

  setup do
    on_exit(fn ->
      Application.delete_env(:lang_ex, :openai)
      Application.delete_env(:lang_ex, :providers)
      System.delete_env("LANG_EX_TEST_KEY")
    end)

    :ok
  end

  describe "api_key/2" do
    test "explicit opts win over application config" do
      Application.put_env(:lang_ex, :openai, api_key: "from-app-config")

      assert Config.api_key(:openai, api_key: "from-opts") == "from-opts"
    end

    test "application config wins over environment variables" do
      Application.put_env(:lang_ex, :openai, api_key: "from-app-config")

      assert Config.api_key(:openai) == "from-app-config"
    end

    test "api_key!/2 raises when nothing is configured" do
      Application.put_env(:lang_ex, :providers, %{
        unconfigured: %{env_key: "LANG_EX_MISSING_KEY", default_model: "m"}
      })

      assert_raise RuntimeError, ~r/no API key configured for unconfigured/, fn ->
        Config.api_key!(:unconfigured)
      end
    end

    test "custom providers resolve keys from their env variable" do
      Application.put_env(:lang_ex, :providers, %{
        custom: %{env_key: "LANG_EX_TEST_KEY", default_model: "custom-model"}
      })

      System.put_env("LANG_EX_TEST_KEY", "from-env")

      assert Config.api_key(:custom) == "from-env"
    end
  end

  describe "model/2" do
    test "explicit opts win, then app config, then provider default" do
      assert Config.model(:openai, model: "gpt-custom") == "gpt-custom"

      Application.put_env(:lang_ex, :openai, model: "gpt-from-config")
      assert Config.model(:openai) == "gpt-from-config"

      Application.delete_env(:lang_ex, :openai)
      assert Config.model(:openai) == "gpt-4o"
    end
  end

  describe "provider_defaults/1" do
    test "built-in providers are known" do
      assert %{env_key: "ANTHROPIC_API_KEY"} = Config.provider_defaults(:anthropic)
    end

    test "unknown providers raise" do
      assert_raise KeyError, fn -> Config.provider_defaults(:unknown_provider) end
    end
  end
end
