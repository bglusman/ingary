defmodule ElixirIngaryWeb.Layouts do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Ingary Policy Workbench</title>
        <style>
          <%= ElixirIngaryWeb.PolicyProjectionLive.styles() %>
        </style>
      </head>
      <body>
        <main class="shell">
          <%= @inner_content %>
        </main>
      </body>
    </html>
    """
  end
end
