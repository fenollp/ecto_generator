defmodule Mix.Tasks.Ecto.Dump.Schema do
  use Mix.Task

  @shortdoc "Dump schemas/models from repos"
  @recursive true

  @moduledoc """
  Dump models from repos

  ## Example:
   mix ecto.dump.schema --app ecto_panda \
      --prefixes pubg,lol,csgo,dota2,ow \
      --not-prefixes league,match,player,serie,team,tournament,winner \
      --inserted_at :created_at \
      --datetime :utc_timestamp_usec \
      --except-tables '^pghero'

  ## Options:
  --app <MyAppWeb>
  --only-tables, --except-tables <REGEXP>
  --prefixes <PREFIXES>      Comma separated table name prefixes to turn into subnamespaces
  --not-prefixes <PREFIXES>  Comma separated table name prefixes to not turn into subnamespaces
  --inserted_at <FIELD>      Name of inserted_at timestamp field
  --datetime <TYPE>          What to replace datetime types with
  """

  @template ~s"""
  defmodule <%= module %> do
    use <%= app %>.Schema

    schema "<%= table %>" do<%=
    for c=%{kind: :belongs, trimmed: name} <- columns do %>
      belongs_to :<%= name %>, <%= c.trimmed_module %><% end %><%=
    for %{kind: :field, name: name, type: type, pkey?: primary?} <- columns do %>
      field :<%= name %>, <%= type %><%= if primary? do %>, primary_key: true<% end %><% end %><%=
    for %{kind: :timestamp, inserted_at: inserted_at} <- columns do %>
      timestamps<%= if inserted_at do %> inserted_at: <%= inserted_at %><% end %><% end %>
    end
  end
  """
  @t_integer [
    "bigint",
    "int",
    "integer",
    "mediumint",
    "smallint",
    "tinyint"
  ]
  @t_boolean [
    "bit varying",
    "bit",
    "boolean"
  ]
  @t_string [
    "char",
    "character",
    "longtext",
    "mediumtext",
    "text",
    "tinytext",
    "varchar",
    "year"
  ]
  @t_float [
    "decimal",
    "double",
    "float",
    "real"
  ]
  @t_datetime [
    "time",
    "timestamp"
  ]

  defstruct repos: [],
            prefixes: [],
            not_prefixes: [],
            inserted_at: ":inserted_at",
            datetime: ":utc_timestamp",
            only: nil,
            except: nil,
            app: nil

  defp defaults do
    %__MODULE__{}
    |> (&%{&1 | app: Mix.Project.config()[:app]}).()
  end

  defp parse([], acc), do: acc
  defp parse(["--repo" | rest], acc), do: parse(["-r" | rest], acc)

  defp parse([key = "-" <> _, value | rest], acc = %__MODULE__{}) do
    case {key, value} do
      {"-r", repo} ->
        parse(rest, %{acc | repos: [Module.concat([repo]) | acc.repos]})

      {"--app", app} ->
        parse(rest, %{acc | app: :"#{app}"})

      {"--prefixes", prefixes} ->
        parse(rest, %{acc | prefixes: prefixes |> String.split(",")})

      {"--not-prefixes", prefixes} ->
        parse(rest, %{acc | not_prefixes: prefixes |> String.split(",")})

      {"--datetime", datetime} ->
        parse(rest, %{acc | datetime: datetime})

      {"--inserted_at", inserted_at} ->
        parse(rest, %{acc | inserted_at: inserted_at})

      {"--only-tables", only} ->
        parse(rest, %{acc | only: Regex.compile!(only)})

      {"--except-tables", except} ->
        parse(rest, %{acc | except: Regex.compile!(except)})
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

  defp generate_models("mysql", repo, args = %__MODULE__{only: only, except: except}) do
    config = repo.config
    true = Keyword.keyword?(config)
    {:ok, database} = Keyword.fetch(config, :database)

    {:ok, result} =
      repo.query("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = '#{database}'
      """)

    result.rows
    |> Enum.map(&Kernel.hd/1)
    |> case do
      rows when is_nil(only) -> rows
      rows -> rows |> Enum.filter(&Regex.match?(only, &1))
    end
    |> case do
      rows when is_nil(except) -> rows
      rows -> rows |> Enum.reject(&Regex.match?(except, &1))
    end
    |> Enum.each(fn table ->
      {:ok, description} =
        repo.query("""
        SELECT COLUMN_NAME, DATA_TYPE, CASE WHEN `COLUMN_KEY` = 'PRI' THEN '1' ELSE NULL END AS primary_key
        FROM information_schema.columns
        WHERE table_name= '#{table}'
        AND table_schema='#{database}'
        """)

      columns =
        Enum.map(description.rows, fn [column_name, column_type, is_primary] ->
          %{
            kind: kind(args, column_name, column_type),
            name: column_name,
            type: get_type(column_type),
            pkey?: is_primary
          }
        end)

      args
      |> model(
        table: table,
        columns: columns
      )
    end)
  end

  defp generate_models("postgres", repo, args = %__MODULE__{only: only, except: except}) do
    {:ok, result} =
      repo.query("""
      SELECT table_name
       FROM information_schema.tables
       WHERE table_schema = 'public'
      """)

    result.rows
    |> Enum.map(&Kernel.hd/1)
    |> case do
      rows when is_nil(only) -> rows
      rows -> rows |> Enum.filter(&Regex.match?(only, &1))
    end
    |> case do
      rows when is_nil(except) -> rows
      rows -> rows |> Enum.reject(&Regex.match?(except, &1))
    end
    |> Enum.each(fn table ->
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

            %{
              kind: kind(args, column_name, column_type),
              name: column_name,
              type: get_type(column_type),
              pkey?: nil
            }
          else
            %{
              kind: kind(args, column_name, column_type),
              name: column_name,
              type: get_type(column_type),
              pkey?: true
            }
          end
        end)

      args
      |> model(
        table: table,
        columns: columns
      )
    end)
  end

  defp model(args, opts) do
    app = modularize("#{args.app}")
    table = opts |> Keyword.fetch!(:table)
    {cols, opts} = opts |> Keyword.pop(:columns)
    prx = args.prefixes |> Enum.filter(&(table |> String.starts_with?("#{&1}_")))

    prefix =
      case prx do
        [prefix] -> "#{prefix}." |> String.capitalize()
        [] -> ""
      end

    module =
      if prefix != "" do
        "#{app}.#{prefix}#{table |> String.replace_prefix("#{hd(prx)}_", "") |> modularize()}"
      else
        "#{app}.#{table |> modularize()}"
      end

    cols =
      cols
      |> Enum.reject(&(&1.name == "id"))
      |> Enum.sort_by(& &1.name)
      |> Enum.flat_map(fn
        c = %{kind: :belongs, name: n} ->
          trimmed = n |> String.replace_suffix("_id", "")
          prefix? = [] == args.not_prefixes |> Enum.filter(&(trimmed |> String.starts_with?(&1)))
          prefix = if prefix != "" && prefix?, do: prefix, else: ""

          c
          |> Map.put(:trimmed, trimmed)
          |> Map.put(:trimmed_module, "#{app}.#{prefix}#{modularize(trimmed)}")
          |> List.wrap()

        %{kind: :field, name: name} when ":" <> name == :erlang.map_get(:inserted_at, args) ->
          []

        %{kind: :field, name: "updated_at"}
        when :erlang.map_get(:inserted_at, args) == :erlang.map_get(:inserted_at, %__MODULE__{}) ->
          [%{kind: :timestamp}]

        %{kind: :field, name: "updated_at"} ->
          [%{kind: :timestamp, inserted_at: args.inserted_at}]

        c = %{kind: :field, type: t}
        when t in @t_datetime and
               :erlang.map_get(:datetime, args) != :erlang.map_get(:datetime, %__MODULE__{}) ->
          [%{c | type: args.datetime}]

        c ->
          [c]
      end)

    @template
    |> EEx.eval_string([app: app, module: module, columns: cols] ++ opts)
    |> write_model(singularize(table), args)
  end

  defp write_model(content, name, args) do
    filename = "lib/#{args.app}/models/#{name}.ex"
    filename |> Path.dirname() |> File.mkdir_p!()
    filename |> File.write!(content)
    IO.puts("#{filename} was generated")
  end

  defp modularize(table_name) do
    String.split(table_name, "_")
    |> Enum.map_join("", &String.capitalize/1)
    |> singularize()
  end

  defp singularize(str) do
    s = str |> String.downcase()

    cond do
      s |> String.ends_with?("series") ->
        str |> String.replace_suffix("ries", "rie")

      true ->
        str |> Inflex.singularize()
    end
  end

  defp kind(_args, field, _type) do
    cond do
      field |> String.ends_with?("_id") -> :belongs
      true -> :field
    end
  end

  defp get_type("blob"), do: ":binary"
  defp get_type(boolean) when boolean in @t_boolean, do: ":boolean"
  defp get_type(datetime) when datetime in @t_datetime, do: %__MODULE__{}.datetime
  defp get_type(float) when float in @t_float, do: ":float"
  defp get_type(integer) when integer in @t_integer, do: ":integer"
  defp get_type(string) when string in @t_string, do: ":string"
  defp get_type("date"), do: "Date"
  defp get_type("numeric"), do: "Decimal"

  # TODO: allow user-defined behavior here
  defp get_type("character varying"), do: ":string"
  defp get_type("inet"), do: ":string"
  defp get_type("json"), do: ":string"
  defp get_type("jsonb"), do: ":string"
  defp get_type("oid"), do: ":string"
  defp get_type("user-defined"), do: ":string"
  defp get_type("uuid"), do: ":string"
end
