ExUnit.start()
ExUnit.configure(exclude: [live_provider: true])
Code.require_file("../test_support/router_case.ex", __DIR__)
