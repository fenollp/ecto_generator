defmodule Mix.Tasks.Ecto.Dump.Schema do
  use Mix.Task

  @shortdoc "Dump schemas/models from repos"
  @recursive true

  @moduledoc """
  Dump models from repos

  ## Example:
   mix ecto.dump.models

  ## Options:
  --app <MyAppWeb>
  """

  @template ~s"""
  defmodule <%= app <> "." <> module_name %> do
    use <%= app %>.Schema

    schema "<%= table %>" do<%= for {name, type, primary?} <- columns do %><%=
     if name != "id" do %>
      field :<%= String.downcase(name) %>, <%= type %><%= if primary? do %>, primary_key: true<% end %><% end %><% end %>
    end
  end
  """

  defstruct repos: [],
            app: nil

  defp defaults do
    %__MODULE__{}
    |> (&%{&1 | app: Mix.Project.config()[:app] |> Atom.to_string() |> String.capitalize()}).()
  end

  defp parse([], acc), do: acc
  defp parse(["--repo" | rest], acc), do: parse(["-r" | rest], acc)

  defp parse([key = "-" <> _, value | rest], acc = %__MODULE__{}) do
    case {key, value} do
      {"-r", repo} ->
        parse(rest, %{acc | repos: [Module.concat([repo]) | acc.repos]})

      {"--app", app} ->
        parse(rest, %{acc | app: :"#{app}"})
    end
  end

  defp ensure_repos(repos, args) do
    cond do
      length(repos) > 0 ->
        repos

      repos = Application.get_env(args.app, :ecto_repos) ->
        repos

      Map.has_key?(Mix.Project.deps_paths(), :ecto) ->
        Mix.shell().error("""
        Warning: could not find repositories for application #{inspect(args.app)}.

        You can avoid this warning by passing the -r flag or by setting the
        repositories managed by this application in your config/config.exs:

            config #{inspect(args.app)}, ecto_repos: [...]

        The configuration may be an empty list if it does not define any repo.
        """)

        []

      true ->
        []
    end
  end

  defp ensure_repo(repo, args) do
    Mix.Task.run("loadpaths", args)
    Mix.Project.compile(args)

    case Code.ensure_compiled(repo) do
      {:module, _} ->
        if function_exported?(repo, :__adapter__, 0) do
          repo
        else
          Mix.raise(
            "Module #{inspect(repo)} is not an Ecto.Repo. " <>
              "Please configure your app accordingly or pass a repo with the -r option."
          )
        end

      {:error, error} ->
        Mix.raise(
          "Could not load #{inspect(repo)}, error: #{inspect(error)}. " <>
            "Please configure your app accordingly or pass a repo with the -r option."
        )
    end
  end

  defp ensure_started(repo, opts) do
    {:ok, _} = Application.ensure_all_started(:ecto)
    {:ok, apps} = repo.__adapter__.ensure_all_started(repo, :temporary)

    case repo.start_link(pool_size: Keyword.get(opts, :pool_size, 1)) do
      {:ok, pid} ->
        {:ok, pid, apps}

      {:error, {:already_started, _pid}} ->
        {:ok, nil, apps}

      {:error, error} ->
        Mix.raise("Could not start repo #{inspect(repo)}, error: #{inspect(error)}")
    end
  end

  @doc false
  def run(args) do
    args = parse(args, defaults())

    args.repos
    |> ensure_repos(args)
    |> Enum.each(fn repo ->
      ensure_repo(repo, [])
      ensure_started(repo, [])

      repo.__adapter__()
      |> Atom.to_string()
      |> String.downcase()
      |> String.split(".")
      |> List.last()
      |> generate_models(repo, args)
    end)
  end

  defp generate_models("mysql", repo, args) do
    config = repo.config
    true = Keyword.keyword?(config)
    {:ok, database} = Keyword.fetch(config, :database)

    {:ok, result} =
      repo.query("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = '#{database}'
      """)

    Enum.each(result.rows, fn [table] ->
      {:ok, description} =
        repo.query("""
        SELECT COLUMN_NAME, DATA_TYPE, CASE WHEN `COLUMN_KEY` = 'PRI' THEN '1' ELSE NULL END AS primary_key
        FROM information_schema.columns
        WHERE table_name= '#{table}'
        AND table_schema='#{database}'
        """)

      columns =
        Enum.map(description.rows, fn [column_name, column_type, is_primary] ->
          {column_name, get_type(column_type), is_primary}
        end)

      content =
        @template
        |> EEx.eval_string(
          app: args.app,
          table: table,
          module_name: to_camelcase(table),
          columns: columns
        )

      write_model(table, content)
    end)
  end

  defp generate_models("postgres", repo, _args) do
    {:ok, result} =
      repo.query("""
      SELECT table_name
       FROM information_schema.tables
       WHERE table_schema = 'public'
      """)

    Enum.each(result.rows, fn [table] ->
      {:ok, primary_keys} =
        repo.query("""
        SELECT c.column_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.constraint_column_usage AS ccu
        USING (constraint_schema, constraint_name)
        JOIN information_schema.columns AS c ON c.table_schema = tc.constraint_schema
        AND tc.table_name = c.table_name
        AND ccu.column_name = c.column_name
        WHERE constraint_type = 'PRIMARY KEY'
        AND tc.table_name = '#{table}'
        """)

      {:ok, description} =
        repo.query("""
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name ='#{table}'
        """)

      columns =
        Enum.map(description.rows, fn [column_name, column_type] ->
          found =
            primary_keys.rows
            |> List.flatten()
            |> Enum.find(nil, &(&1 == column_name))

          if found == nil do
            [column_type | _] = column_type |> String.downcase() |> String.split()
            {column_name, get_type(column_type), nil}
          else
            {column_name, get_type(column_type), true}
          end
        end)

      content =
        @template
        |> EEx.eval_string(
          app: Mix.Project.config()[:app] |> Atom.to_string() |> Macro.camelize(),
          table: table,
          module_name: to_camelcase(table),
          columns: columns
        )

      write_model(table, content)
    end)
  end

  defp write_model(table, content) do
    filename = "lib/#{Mix.Project.config()[:app]}/models/#{table}.ex"
    filename |> Path.dirname() |> File.mkdir_p!()
    filename |> File.write!(content)
    IO.puts("\e[0;35m  #{filename} was generated")
  end

  defp to_camelcase(table_name) do
    Enum.map_join(String.split(table_name, "_"), "", &String.capitalize(&1))
  end

  defp get_type("bigint"), do: ":integer"
  defp get_type("bit varying"), do: ":boolean"
  defp get_type("bit"), do: ":boolean"
  defp get_type("blob"), do: ":binary"
  defp get_type("boolean"), do: ":boolean"
  defp get_type("char"), do: ":string"
  defp get_type("character"), do: ":string"
  defp get_type("date"), do: "Date"
  defp get_type("datetime"), do: "DateTime"
  defp get_type("decimal"), do: ":float"
  defp get_type("double"), do: ":float"
  defp get_type("float"), do: ":float"
  defp get_type("int"), do: ":integer"
  defp get_type("integer"), do: ":integer"
  defp get_type("longtext"), do: ":string"
  defp get_type("mediumint"), do: ":integer"
  defp get_type("mediumtext"), do: ":string"
  defp get_type("numeric"), do: "Decimal"
  defp get_type("real"), do: ":float"
  defp get_type("smallint"), do: ":integer"
  defp get_type("text"), do: ":string"
  defp get_type("time"), do: "DateTime"
  defp get_type("timestamp"), do: "DateTime"
  defp get_type("tinyint"), do: ":integer"
  defp get_type("tinytext"), do: ":string"
  defp get_type("varchar"), do: ":string"
  defp get_type("year"), do: ":string"

  # TODO: allow user-defined behavior here
  defp get_type("character varying"), do: ":string"
  defp get_type("inet"), do: ":string"
  defp get_type("json"), do: ":string"
  defp get_type("jsonb"), do: ":string"
  defp get_type("oid"), do: ":string"
  defp get_type("user-defined"), do: ":string"
  defp get_type("uuid"), do: ":string"

  # defp get_type(type) do
  #   IO.puts("\e[0;31m  #{type} is not supported ... Fallback to :string")
  #   ":string"
  # end
end
