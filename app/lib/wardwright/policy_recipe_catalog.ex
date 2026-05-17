defmodule Wardwright.PolicyRecipeCatalog do
  @moduledoc """
  Policy recipe discovery boundary for the workbench.

  Recipes are descriptive data used for discovery, import, and review. Loading a
  recipe source must not execute policy code or install trusted artifacts.
  """

  @default_community_url "https://wardwright.dev/recipes/index.json"
  @default_remote_timeout_ms 1_500
  @default_remote_max_bytes 256_000
  @allowed_remote_schemes MapSet.new(~w(http https))
  @community_warning "Community examples are untrusted until imported and reviewed."
  @starter_recipe_file "starter-recipes.json"
  @starter_workspace_dir "starter-workspace"
  @starter_seed_marker ".starter-recipes-seeded"

  @type source_id :: String.t()
  @type source :: %__MODULE__.Source{}
  @type recipe :: %__MODULE__.Recipe{}
  @type catalog :: %__MODULE__.Catalog{}

  defmodule Source do
    @moduledoc false
    @enforce_keys [:id, :label, :kind, :trusted, :summary]
    defstruct [:id, :label, :kind, :trusted, :summary, endpoint: nil]
  end

  defmodule Recipe do
    @moduledoc false
    @enforce_keys [:id, :title, :category, :promise, :pattern_id, :recipe_kind, :source_id]
    defstruct [
      :id,
      :title,
      :category,
      :promise,
      :pattern_id,
      :recipe_kind,
      :source_id,
      :collection_id,
      :collection_title,
      :management_area,
      :failure_story,
      :old_behavior,
      :wardwright_behavior,
      :composition,
      primitives: []
    ]
  end

  defmodule Catalog do
    @moduledoc false
    @enforce_keys [:source, :recipes]
    defstruct [:source, recipes: [], warnings: [], error: nil]
  end

  @spec sources(keyword()) :: [source()]
  def sources(opts \\ []) do
    [
      %Source{
        id: "built_in",
        label: "Built-in examples",
        kind: "built_in",
        trusted: true,
        summary: "Projection examples compiled into this Wardwright build."
      },
      %Source{
        id: "workspace",
        label: "Project examples",
        kind: "filesystem",
        trusted: true,
        summary: "Locally reviewed recipe JSON files seeded from this Wardwright build.",
        endpoint: workspace_dir(opts)
      },
      %Source{
        id: "community",
        label: "Community examples",
        kind: "https_json",
        trusted: false,
        summary: "Shared policy recipes from wardwright.dev.",
        endpoint: community_url(opts)
      }
    ]
  end

  @spec source(source_id(), keyword()) :: source()
  def source(source_id, opts \\ []) do
    Enum.find(sources(opts), &(&1.id == source_id)) || hd(sources(opts))
  end

  @spec source_ids(keyword()) :: [source_id()]
  def source_ids(opts \\ []), do: Enum.map(sources(opts), & &1.id)

  @spec list(source_id(), keyword()) :: {:ok, catalog()} | {:error, catalog()}
  def list(source_id, opts \\ []) do
    source = source(source_id, opts)

    case source.id do
      "built_in" -> built_in(source)
      "workspace" -> workspace(source)
      "community" -> community(source, opts)
    end
  end

  @spec to_map(source() | recipe() | catalog()) :: map()
  def to_map(%Source{} = source) do
    [
      # boundary-map-ok
      {"id", source.id},
      # boundary-map-ok
      {"label", source.label},
      # boundary-map-ok
      {"kind", source.kind},
      # boundary-map-ok
      {"trusted", source.trusted},
      # boundary-map-ok
      {"summary", source.summary},
      # boundary-map-ok
      {"endpoint", source.endpoint}
    ]
    |> reject_nil()
  end

  def to_map(%Recipe{} = recipe) do
    [
      # boundary-map-ok
      {"id", recipe.id},
      # boundary-map-ok
      {"title", recipe.title},
      # boundary-map-ok
      {"category", recipe.category},
      # boundary-map-ok
      {"promise", recipe.promise},
      # boundary-map-ok
      {"pattern_id", recipe.pattern_id},
      # boundary-map-ok
      {"recipe_kind", recipe.recipe_kind},
      # boundary-map-ok
      {"source_id", recipe.source_id},
      # boundary-map-ok
      {"collection_id", recipe.collection_id},
      # boundary-map-ok
      {"collection_title", recipe.collection_title},
      # boundary-map-ok
      {"management_area", recipe.management_area},
      # boundary-map-ok
      {"failure_story", recipe.failure_story},
      # boundary-map-ok
      {"old_behavior", recipe.old_behavior},
      # boundary-map-ok
      {"wardwright_behavior", recipe.wardwright_behavior},
      # boundary-map-ok
      {"composition", recipe.composition},
      # boundary-map-ok
      {"primitives", recipe.primitives}
    ]
    |> reject_empty()
  end

  def to_map(%Catalog{} = catalog) do
    [
      # boundary-map-ok
      {"source", to_map(catalog.source)},
      # boundary-map-ok
      {"recipes", Enum.map(catalog.recipes, &to_map/1)},
      # boundary-map-ok
      {"warnings", catalog.warnings},
      # boundary-map-ok
      {"error", catalog.error}
    ]
    |> reject_nil()
  end

  defp built_in(source) do
    recipes =
      Wardwright.PolicyProjection.patterns()
      |> Enum.map(fn pattern ->
        pattern_id = Map.fetch!(pattern, "id")

        %Recipe{
          id: pattern_id,
          title: Map.fetch!(pattern, "title"),
          category: Map.fetch!(pattern, "category"),
          promise: Map.fetch!(pattern, "promise"),
          source_id: source.id,
          pattern_id: pattern_id,
          recipe_kind: "projection_demo",
          collection_id: "built-in",
          collection_title: "Built-in projection demos"
        }
      end)

    {:ok, %Catalog{source: source, recipes: recipes, warnings: []}}
  end

  defp workspace(source) do
    seed_warning = seed_workspace(source)

    case File.ls(source.endpoint) do
      {:ok, _entries} ->
        recipes =
          source.endpoint
          |> workspace_recipe_files()
          |> Enum.flat_map(&read_workspace_file(source.endpoint, &1))

        {:ok,
         %Catalog{
           source: source,
           recipes: recipes,
           warnings: workspace_warnings(source, recipes, seed_warning)
         }}

      {:error, :enoent} ->
        {:ok,
         %Catalog{
           source: source,
           recipes: [],
           warnings: ["No workspace example directory exists at #{source.endpoint}."]
         }}

      {:error, reason} ->
        {:error,
         %Catalog{
           source: source,
           recipes: [],
           error: "Could not read workspace examples: #{format_file_error(reason)}"
         }}
    end
  end

  defp community(source, opts) do
    with :ok <- require_https(source.endpoint, opts),
         {:ok, body} <- fetch_json(source.endpoint, opts),
         {:ok, recipes} <- decode_recipes(body, source.id, default_collection(source.id)) do
      {:ok,
       %Catalog{
         source: source,
         recipes: recipes,
         warnings: [@community_warning]
       }}
    else
      {:error, error} when is_binary(error) ->
        {:error, %Catalog{source: source, recipes: [], error: error}}
    end
  end

  defp workspace_recipe_files(endpoint) do
    endpoint
    |> Path.join("**/*.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.sort()
  end

  defp read_workspace_file(workspace_root, path) do
    collection = workspace_collection(workspace_root, path)

    with {:ok, body} <- File.read(path),
         {:ok, recipes} <- decode_recipes(body, "workspace", collection) do
      recipes
    else
      _ -> []
    end
  end

  defp decode_recipes(body, source_id, collection) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, recipes} <- recipe_list(decoded) do
      recipes =
        recipes
        |> Enum.map(&validate_recipe(&1, source_id, collection))
        |> Enum.reject(&is_nil/1)

      {:ok, recipes}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
      {:error, error} -> {:error, error}
    end
  end

  defp recipe_list(%{} = catalog) do
    case Map.fetch(catalog, "recipes") do
      {:ok, recipes} when is_list(recipes) -> {:ok, recipes}
      :error -> {:ok, [catalog]}
      _invalid -> {:error, "Recipe catalog recipes must be a list."}
    end
  end

  defp recipe_list(recipes) when is_list(recipes), do: {:ok, recipes}
  defp recipe_list(_), do: {:error, "Recipe catalog must be a recipe object or list."}

  defp validate_recipe(recipe, source_id, collection) when is_map(recipe) do
    id = string_field(recipe, "id")
    title = string_field(recipe, "title")

    if id && title do
      %Recipe{
        id: id,
        title: title,
        category: string_field(recipe, "category") || "uncategorized",
        promise: string_field(recipe, "promise") || "No summary provided.",
        pattern_id: string_field(recipe, "pattern_id") || string_field(recipe, "id"),
        recipe_kind: string_field(recipe, "recipe_kind") || "policy_recipe",
        source_id: source_id,
        collection_id: string_field(recipe, "collection_id") || collection.id,
        collection_title: string_field(recipe, "collection_title") || collection.title,
        management_area: string_field(recipe, "management_area"),
        failure_story: string_field(recipe, "failure_story"),
        old_behavior: string_field(recipe, "old_behavior"),
        wardwright_behavior: string_field(recipe, "wardwright_behavior"),
        composition: string_field(recipe, "composition"),
        primitives: string_list_field(recipe, "primitives")
      }
    end
  end

  defp validate_recipe(_recipe, _source_id, _collection), do: nil

  defp string_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp string_list_field(map, key) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.map(fn value -> value |> to_string() |> String.trim() end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp workspace_warnings(source, [], nil),
    do: ["No valid workspace examples were found in #{source.endpoint}."]

  defp workspace_warnings(_source, recipes, nil) when recipes != [], do: []

  defp workspace_warnings(source, recipes, seed_warning) do
    workspace_warnings(source, recipes, nil) ++ [seed_warning]
  end

  defp require_https(url, opts) do
    uri = URI.parse(url)

    cond do
      uri.scheme == "https" ->
        :ok

      Keyword.get(opts, :allow_http?, false) and
          MapSet.member?(@allowed_remote_schemes, uri.scheme) ->
        :ok

      true ->
        {:error, "Community example source must use HTTPS."}
    end
  end

  defp fetch_json(url, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_remote_timeout_ms)
    max_bytes = Keyword.get(opts, :max_bytes, @default_remote_max_bytes)
    headers = [{~c"accept", ~c"application/json"}]
    request = {String.to_charlist(url), headers}
    http_options = [timeout: timeout] ++ tls_options(url)
    options = [body_format: :binary]
    request_fun = Keyword.get(opts, :request_fun, &:httpc.request/4)

    case request_fun.(:get, request, http_options, options) do
      {:ok, {{_, status, _}, _headers, body}}
      when status in 200..299 and byte_size(body) <= max_bytes ->
        {:ok, body}

      {:ok, {{_, status, _}, _headers, _body}} when status in 200..299 ->
        {:error, "Community example source exceeded #{max_bytes} bytes."}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, "Community example source returned HTTP #{status}."}

      {:error, reason} ->
        {:error, "Could not fetch community examples: #{inspect(reason)}"}
    end
  end

  defp tls_options(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        [
          ssl: [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: String.to_charlist(host),
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        ]

      _ ->
        []
    end
  end

  defp workspace_dir(opts) do
    opts[:workspace_dir] ||
      Application.get_env(:wardwright, :policy_recipe_workspace_dir, default_workspace_dir())
  end

  defp default_workspace_dir do
    Path.join(System.user_home!(), ".wardwright/recipes/policies")
  end

  defp seed_workspace(%Source{endpoint: endpoint}) do
    marker_path = Path.join(endpoint, @starter_seed_marker)
    starter_target = Path.join(endpoint, @starter_recipe_file)

    cond do
      File.exists?(marker_path) ->
        nil

      File.exists?(starter_target) ->
        write_seed_marker(marker_path)

      true ->
        with :ok <- File.mkdir_p(endpoint),
             :ok <- copy_starter_workspace(endpoint),
             nil <- write_seed_marker(marker_path) do
          nil
        else
          {:error, reason} ->
            "Could not seed workspace examples: #{format_file_error(reason)}"

          warning when is_binary(warning) ->
            warning
        end
    end
  end

  defp write_seed_marker(marker_path) do
    case File.write(marker_path, "starter recipes copied from this Wardwright build\n") do
      :ok ->
        nil

      {:error, reason} ->
        "Could not record workspace example seed marker: #{format_file_error(reason)}"
    end
  end

  defp copy_starter_workspace(endpoint) do
    case starter_workspace_path() do
      {:ok, starter_dir} ->
        copy_starter_workspace_dir(starter_dir, endpoint)

      {:error, _reason} ->
        with {:ok, starter_path} <- starter_recipe_path() do
          File.cp(starter_path, Path.join(endpoint, @starter_recipe_file))
        end
    end
  end

  defp copy_starter_workspace_dir(starter_dir, endpoint) do
    starter_dir
    |> Path.join("**/*.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.reduce_while(:ok, fn source_path, :ok ->
      relative_path = Path.relative_to(source_path, starter_dir)
      target_path = Path.join(endpoint, relative_path)

      case File.mkdir_p(Path.dirname(target_path)) do
        :ok ->
          case File.cp(source_path, target_path) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp starter_workspace_path do
    case :code.priv_dir(:wardwright) do
      priv_dir when is_list(priv_dir) ->
        path =
          priv_dir
          |> List.to_string()
          |> Path.join("recipes/policies/#{@starter_workspace_dir}")

        if File.dir?(path), do: {:ok, path}, else: {:error, :enoent}

      {:error, _reason} ->
        path = Path.expand("../../priv/recipes/policies/#{@starter_workspace_dir}", __DIR__)
        if File.dir?(path), do: {:ok, path}, else: {:error, :enoent}
    end
  end

  defp starter_recipe_path do
    case :code.priv_dir(:wardwright) do
      priv_dir when is_list(priv_dir) ->
        path =
          priv_dir
          |> List.to_string()
          |> Path.join("recipes/policies/starter-recipes.json")

        {:ok, path}

      {:error, _reason} ->
        {:ok, Path.expand("../../priv/recipes/policies/starter-recipes.json", __DIR__)}
    end
  end

  defp community_url(opts) do
    opts[:community_url] ||
      Application.get_env(:wardwright, :policy_recipe_community_url, @default_community_url)
  end

  defp format_file_error(reason), do: :file.format_error(reason) |> List.to_string()

  defp workspace_collection(workspace_root, path) do
    relative_dir =
      path
      |> Path.dirname()
      |> Path.relative_to(workspace_root)

    case relative_dir do
      "." -> default_collection("workspace")
      "" -> default_collection("workspace")
      dir -> %{id: dir, title: titleize_path(dir)}
    end
  end

  defp default_collection(source_id) do
    case source_id do
      "workspace" -> %{id: "workspace", title: "Workspace examples"}
      "community" -> %{id: "community", title: "Community examples"}
      "built_in" -> %{id: "built-in", title: "Built-in projection demos"}
      _ -> %{id: "examples", title: "Examples"}
    end
  end

  defp titleize_path(path) do
    path
    |> String.split("/")
    |> List.last()
    |> String.replace(~r/[-_]+/, " ")
    |> String.capitalize()
  end

  defp reject_nil(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp reject_empty(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end
end
