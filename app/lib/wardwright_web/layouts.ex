defmodule WardwrightWeb.Layouts do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Wardwright Policy Workbench</title>
        <style>
          <%= Phoenix.HTML.raw(WardwrightWeb.PolicyProjectionLive.styles()) %>
        </style>
        <script defer src="/vendor/phoenix/phoenix.min.js">
        </script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script defer src="/assets/wardwright_live.js">
        </script>
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
