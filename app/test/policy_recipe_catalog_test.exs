defmodule Wardwright.PolicyRecipeCatalogTest do
  use ExUnit.Case, async: false

  setup do
    original_workspace = Application.get_env(:wardwright, :policy_recipe_workspace_dir)
    original_community = Application.get_env(:wardwright, :policy_recipe_community_url)

    on_exit(fn ->
      put_or_delete_env(:policy_recipe_workspace_dir, original_workspace)
      put_or_delete_env(:policy_recipe_community_url, original_community)
    end)

    :ok
  end

  test "built-in source exposes projection demos as non-executable recipes" do
    assert {:ok, catalog} = Wardwright.PolicyRecipeCatalog.list("built_in")
    catalog = Wardwright.PolicyRecipeCatalog.to_map(catalog)

    assert catalog["source"]["trusted"] == true
    assert Enum.any?(catalog["recipes"], &(&1["id"] == "tts-retry"))
    assert Enum.all?(catalog["recipes"], &(&1["recipe_kind"] == "projection_demo"))
    assert Enum.all?(catalog["recipes"], &is_binary(&1["pattern_id"]))
  end

  test "workspace source seeds starter recipes into a missing user workspace once" do
    workspace_dir =
      Path.join(System.tmp_dir!(), "wardwright-seeded-recipes-#{System.unique_integer()}")

    Application.put_env(:wardwright, :policy_recipe_workspace_dir, workspace_dir)

    assert {:ok, catalog} = Wardwright.PolicyRecipeCatalog.list("workspace")
    catalog = Wardwright.PolicyRecipeCatalog.to_map(catalog)

    assert catalog["source"]["trusted"] == true
    assert catalog["source"]["endpoint"] == workspace_dir
    assert catalog["source"]["label"] == "Project examples"
    assert catalog["warnings"] == []
    assert Enum.any?(catalog["recipes"], &(&1["id"] == "local-private-route-gate"))
    assert Enum.any?(catalog["recipes"], &(&1["id"] == "local-cascade-with-cloud-fallback"))
    assert Enum.any?(catalog["recipes"], &(&1["id"] == "local-review-model-ladder"))
    assert Enum.any?(catalog["recipes"], &(&1["pattern_id"] == "tool-governance"))
    assert File.exists?(Path.join(workspace_dir, ".starter-recipes-seeded"))

    File.rm!(Path.join(workspace_dir, "starter-recipes.json"))

    assert {:ok, catalog} = Wardwright.PolicyRecipeCatalog.list("workspace")
    catalog = Wardwright.PolicyRecipeCatalog.to_map(catalog)

    assert catalog["recipes"] == []
    assert catalog["warnings"] == ["No valid workspace examples were found in #{workspace_dir}."]
  end

  test "workspace source seeds starter recipes into an existing unmarked directory" do
    workspace_dir =
      Path.join(System.tmp_dir!(), "wardwright-existing-recipes-#{System.unique_integer()}")

    File.mkdir_p!(workspace_dir)
    Application.put_env(:wardwright, :policy_recipe_workspace_dir, workspace_dir)

    assert {:ok, catalog} = Wardwright.PolicyRecipeCatalog.list("workspace")
    catalog = Wardwright.PolicyRecipeCatalog.to_map(catalog)

    assert catalog["warnings"] == []
    assert Enum.any?(catalog["recipes"], &(&1["id"] == "local-private-route-gate"))
    assert File.exists?(Path.join(workspace_dir, "starter-recipes.json"))
    assert File.exists?(Path.join(workspace_dir, ".starter-recipes-seeded"))
  end

  test "workspace source loads valid recipe JSON and ignores invalid files" do
    workspace_dir = Path.join(System.tmp_dir!(), "wardwright-recipes-#{System.unique_integer()}")
    File.mkdir_p!(workspace_dir)

    valid = %{
      "recipes" => [
        %{
          "id" => "local-tool-review",
          "title" => "Local tool review",
          "category" => "tool.using",
          "promise" => "Review shell write tools before execution.",
          "pattern_id" => "tool-governance"
        }
      ]
    }

    File.write!(
      Path.join(workspace_dir, ".starter-recipes-seeded"),
      "test workspace already initialized\n"
    )

    File.write!(Path.join(workspace_dir, "valid.json"), Jason.encode!(valid))
    File.write!(Path.join(workspace_dir, "invalid.json"), "{")
    Application.put_env(:wardwright, :policy_recipe_workspace_dir, workspace_dir)

    assert {:ok, catalog} = Wardwright.PolicyRecipeCatalog.list("workspace")
    catalog = Wardwright.PolicyRecipeCatalog.to_map(catalog)

    assert catalog["source"]["endpoint"] == workspace_dir
    assert catalog["warnings"] == []

    assert [
             %{
               "id" => "local-tool-review",
               "title" => "Local tool review",
               "pattern_id" => "tool-governance",
               "source_id" => "workspace"
             }
           ] = catalog["recipes"]
  end

  test "community source requires HTTPS before fetching remote recipes" do
    Application.put_env(
      :wardwright,
      :policy_recipe_community_url,
      "http://example.invalid/index.json"
    )

    assert {:error, catalog} = Wardwright.PolicyRecipeCatalog.list("community")
    catalog = Wardwright.PolicyRecipeCatalog.to_map(catalog)
    assert catalog["error"] == "Community example source must use HTTPS."
    assert catalog["recipes"] == []
  end

  test "community source caps remote recipe catalog size" do
    Application.put_env(
      :wardwright,
      :policy_recipe_community_url,
      "https://example.invalid/index.json"
    )

    request_fun = fn :get, _request, http_options, _options ->
      assert [ssl: ssl_options] = Keyword.take(http_options, [:ssl])
      assert ssl_options[:verify] == :verify_peer
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], String.duplicate("x", 12)}}
    end

    assert {:error, catalog} =
             Wardwright.PolicyRecipeCatalog.list("community",
               max_bytes: 8,
               request_fun: request_fun
             )

    catalog = Wardwright.PolicyRecipeCatalog.to_map(catalog)
    assert catalog["error"] == "Community example source exceeded 8 bytes."
    assert catalog["recipes"] == []
  end

  test "community source loads reviewed JSON as untrusted recipes" do
    Application.put_env(
      :wardwright,
      :policy_recipe_community_url,
      "https://example.invalid/index.json"
    )

    body =
      Jason.encode!(%{
        "recipes" => [
          %{
            "id" => "shared-tool-limit",
            "title" => "Shared tool limit",
            "category" => "tool.using",
            "pattern_id" => "tool-governance"
          }
        ]
      })

    request_fun = fn :get, _request, _http_options, _options ->
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], body}}
    end

    assert {:ok, catalog} =
             Wardwright.PolicyRecipeCatalog.list("community", request_fun: request_fun)

    catalog = Wardwright.PolicyRecipeCatalog.to_map(catalog)
    assert catalog["source"]["trusted"] == false

    assert catalog["warnings"] == [
             "Community examples are untrusted until imported and reviewed."
           ]

    assert [
             %{
               "id" => "shared-tool-limit",
               "recipe_kind" => "policy_recipe",
               "source_id" => "community"
             }
           ] = catalog["recipes"]
  end

  test "published community catalog fixture is valid recipe JSON" do
    fixture_path = Path.expand("../../docs/recipes/index.json", __DIR__)

    assert {:ok, body} = File.read(fixture_path)
    assert {:ok, decoded} = Jason.decode(body)
    assert is_list(decoded["recipes"])
    assert Enum.any?(decoded["recipes"], &(&1["id"] == "community-basic-stream-retry"))
    assert Enum.any?(decoded["recipes"], &(&1["id"] == "community-review-model-escalation"))
    assert Enum.any?(decoded["recipes"], &(&1["id"] == "community-local-first-cascade"))

    assert Enum.all?(
             decoded["recipes"],
             &(&1["pattern_id"] in Wardwright.PolicyProjection.pattern_ids())
           )
  end

  defp put_or_delete_env(key, nil), do: Application.delete_env(:wardwright, key)
  defp put_or_delete_env(key, value), do: Application.put_env(:wardwright, key, value)
end
