defmodule AdzeDefinitionAppEnvTest do
  # async: false — these tests mutate Application env, which is global.
  use ExUnit.Case, async: false

  alias Adze.Definition

  setup do
    original = Application.get_env(:adze, :include_attrs)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:adze, :include_attrs)
        value -> Application.put_env(:adze, :include_attrs, value)
      end
    end)

    :ok
  end

  test "application-level include_attrs widens the allowlist" do
    source = """
    defmodule X do
      @spec foo() :: :ok
      @job [queue: :default]
      def foo, do: :ok
    end
    """

    assert {:error, {:ambiguous_attribute, _}} = Definition.list(source)

    Application.put_env(:adze, :include_attrs, [:job])

    {:ok, [d]} = Definition.list(source)
    attr_names = d.parts.attributes |> Enum.map(fn {n, _} -> n end)
    assert attr_names == [:spec, :job]
  end

  test "per-call include_attrs is additive over application env" do
    Application.put_env(:adze, :include_attrs, [:job])

    source = """
    defmodule X do
      @spec foo() :: :ok
      @job [queue: :default]
      @decorate trace()
      def foo, do: :ok
    end
    """

    # app env alone is not enough — @decorate still intervenes
    assert {:error, {:ambiguous_attribute, info}} = Definition.list(source)
    assert Enum.map(info.intervening, & &1.name) == [:decorate]

    # per-call adds :decorate on top of app-level :job
    {:ok, [d]} = Definition.list(source, include_attrs: [:decorate])
    attr_names = d.parts.attributes |> Enum.map(fn {n, _} -> n end)
    assert attr_names == [:spec, :job, :decorate]
  end

  test "duplicate names across app env and per-call are deduped" do
    Application.put_env(:adze, :include_attrs, [:job])

    source = """
    defmodule X do
      @spec foo() :: :ok
      @job [queue: :default]
      def foo, do: :ok
    end
    """

    {:ok, [d]} = Definition.list(source, include_attrs: [:job])
    attr_names = d.parts.attributes |> Enum.map(fn {n, _} -> n end)
    # @job appears once in source, so once in attributes — dedup happens in
    # the membership-check allowlist, not in source-order output
    assert attr_names == [:spec, :job]
  end

  test "non-atom entries in application env are silently ignored" do
    Application.put_env(:adze, :include_attrs, ["job", 42, :decorate])

    source = """
    defmodule X do
      @spec foo() :: :ok
      @decorate trace()
      def foo, do: :ok
    end
    """

    {:ok, [d]} = Definition.list(source)
    attr_names = d.parts.attributes |> Enum.map(fn {n, _} -> n end)
    assert attr_names == [:spec, :decorate]
  end
end
