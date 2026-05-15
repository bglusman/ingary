defmodule WardwrightWeb.ErrorJSON do
  @moduledoc false

  def render(_template, _assigns), do: %{error: "error"}
end
